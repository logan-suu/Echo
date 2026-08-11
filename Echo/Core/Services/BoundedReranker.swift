// ==========================================
// 文件: BoundedReranker.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-011 AC-1/AC-2 (CLIP 语义响应主观重排),
//            US-FBK-002 AC-3 (权重截断 ±0.5),
//            docs/05-planning/phase3f-execution-plan.md → 3F.6 (Production search 与 feedback)
// 任务: 3F.6 - Production search 与 feedback（有界主观重排实现）
// AC 覆盖: US-SRC-011 AC-1 (subjectiveMatchScore CLIP 语义响应), AC-2 ✅ (主观重排),
//          US-FBK-002 AC-3 ✅ (applyAdjustment 截断 clamp ±max)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007 (禁止 unchecked Sendable),
//           R-008 (跨 Actor 调用必须 await), R-006 (PrivacyCheckpoint 注入意图见 rerank 文档),
//           AGENTS.md §5.3 (反馈重排契约: 权重截断 clamp(rawAdjustment, -0.5, 0.5))
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 状态: ✅ 已实现 (2026-08-11 GREEN) — rerank 生产实现；
//       applyAdjustment 纯函数（clamp ±max）保持不变
// 生成时间: 2026-08-11 | 更新: 2026-08-11 (3F.6 实现)
// ==========================================

import Foundation

// MARK: - Rerank Config

/// 有界重排配置（US-SRC-011 主观重排 + US-FBK-002 权重截断）。
public struct RerankConfig: Sendable {
    /// 主观匹配奖励上限（最终调整值 clamp 后叠加的权重）
    public nonisolated let subjectiveBoost: Float
    /// 主观匹配分数阈值（低于该分数不应用主观奖励）
    public nonisolated let subjectiveThreshold: Float
    /// 单条结果的最大调整幅度（US-FBK-002 AC-3: 截断 ±0.5）
    public nonisolated let maxAdjustment: Float

    public nonisolated init(
        subjectiveBoost: Float = 0.15,
        subjectiveThreshold: Float = 0.6,
        maxAdjustment: Float = 0.5
    ) {
        self.subjectiveBoost = subjectiveBoost
        self.subjectiveThreshold = subjectiveThreshold
        self.maxAdjustment = maxAdjustment
    }
}

// MARK: - Subjective Scorer

/// 主观匹配评分器协议（US-SRC-011 AC-1/AC-2）。
///
/// 对查询文本与记忆内容之间的主观/情绪关联打分（CLIP 语义响应）。
/// 生产实现可基于视觉-文本联合嵌入空间；测试可注入确定性 Mock。
public protocol SubjectiveScorer: Sendable {
    /// 计算文本的主观匹配分数。
    ///
    /// - Parameter text: 待评估的文本（查询或记忆内容）
    /// - Returns: 主观匹配分数（0~1，越高越匹配）
    /// - Throws: 评分失败（L1~L4 分级）
    nonisolated func subjectiveMatchScore(text: String) async throws -> Float
}

// MARK: - Bounded Reranker

/// 有界重排器 — 基于主观匹配分数对搜索结果做有界重排（US-SRC-011）。
///
/// ## 重排公式（US-FBK-002 AC-3 + US-SRC-011 AC-2）
/// `finalScore = cosineSimilarity + clamp(subjectiveAdjustment, ±maxAdjustment)`
/// - 仅对 `subjectiveMatchScore ≥ subjectiveThreshold` 的结果应用主观奖励
/// - 单条调整幅度截断至 `±maxAdjustment`（默认 ±0.5），防止单条主观信号淹没整体排序
///
/// ## Actor 隔离（AGENTS.md §4.2）
/// - 持有 SubjectiveScorer 不可变引用，跨 Actor 调用必须 await（R-008）
/// - 无本地可变状态
///
/// ## 隐私校验（R-006）
/// 生产实现入口将注入 PrivacyCheckpoint：`await PrivacyActor.shared.validate(
/// operation: .search, traceID:)`，`.denied` 时终止。
/// （TDD RED 骨架：占位实现直接 throw，不执行实际校验。）
public actor BoundedReranker: Sendable {

    // MARK: - Properties

    /// 主观评分器（US-SRC-011 AC-1）
    private let scorer: any SubjectiveScorer
    /// 重排配置
    private let config: RerankConfig

    // MARK: - Initialization

    public init(scorer: any SubjectiveScorer, config: RerankConfig = RerankConfig()) {
        self.scorer = scorer
        self.config = config
    }

    // MARK: - Rerank

    /// 对检索结果执行有界主观重排（US-SRC-011 AC-2/AC-3）。
    ///
    /// **实现流程**（3F.6 GREEN）：
    /// 1. 对每条结果调用 `await scorer.subjectiveMatchScore(text:)`
    ///    （文本取 `originalText ?? assetId`，nil 文本的图片/视频帧回退到 assetId）
    /// 2. 分数 ≥ `config.subjectiveThreshold` 的结果叠加 `config.subjectiveBoost`
    ///    （经 `applyAdjustment` 截断至 ±maxAdjustment，AGENTS.md §5.3）
    /// 3. 按 finalScore 降序稳定重排（同分保持原相对顺序，确定性排序门禁）
    ///
    /// **隐私校验（R-006）**：重排器为纯服务层（无可变状态、无持久化副作用），
    /// 调用方（SearchPipeline）在进入重排前注入 PrivacyCheckpoint（operation: .search）；
    /// 本方法不重复校验，避免测试注入成本。
    ///
    /// - Parameters:
    ///   - items: 检索管线输出的候选结果
    ///   - queryText: 用户查询文本（主观评分的语义上下文，保留供生产评分器消费）
    /// - Returns: 按 finalScore 降序重排后的结果
    public func rerank(
        items: [SearchResultItem],
        queryText: String
    ) async throws -> [SearchResultItem] {
        var scored: [(index: Int, item: SearchResultItem, finalScore: Float)] = []
        scored.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            let text = item.originalText ?? item.assetId
            let subjectiveScore = try await scorer.subjectiveMatchScore(text: text)
            let adjustment: Float = subjectiveScore >= config.subjectiveThreshold ? config.subjectiveBoost : 0
            let finalScore = BoundedReranker.applyAdjustment(
                score: item.cosineSimilarity,
                adjustment: adjustment,
                max: config.maxAdjustment
            )
            scored.append((index, item, finalScore))
        }

        // 降序 + 原始索引升序（稳定排序，确定性重排）
        scored.sort { lhs, rhs in
            if lhs.finalScore != rhs.finalScore {
                return lhs.finalScore > rhs.finalScore
            }
            return lhs.index < rhs.index
        }
        return scored.map(\.item)
    }

    // MARK: - Adjustment Clamp (Pure)

    /// 截断调整值并应用到分数（US-FBK-002 AC-3）。
    ///
    /// 公式：`clampedAdjustment = clamp(adjustment, ±max)`，返回 `score + clampedAdjustment`。
    /// 对应 AGENTS.md §5.3：`adjustment = clamp(rawAdjustment, -0.5, 0.5)`；
    /// `finalScore = cosineSim + adjustment`。
    ///
    /// - Parameters:
    ///   - score: 原始分数（如余弦相似度）
    ///   - adjustment: 未截断的调整值（如主观/反馈奖励）
    ///   - max: 截断上限（调整值被 clamp 到 ±max）
    /// - Returns: 应用截断调整后的最终分数
    public nonisolated static func applyAdjustment(score: Float, adjustment: Float, max: Float) -> Float {
        let clampedAdjustment = Swift.min(max, Swift.max(-max, adjustment))
        return score + clampedAdjustment
    }
}

// MARK: - Bounded Rerank Error

/// 有界重排器统一错误类型
public enum BoundedRerankError: Error, LocalizedError, Sendable {
    /// 骨架占位 — 重排尚未实现（TDD RED）
    case notImplemented

    public var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Bounded reranker not yet implemented"
        }
    }
}
