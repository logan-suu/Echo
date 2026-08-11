// ==========================================
// 文件: CrossAppIntentParser.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-010 (跨 App 查询分发),
//            US-SRC-011 (CLIP 语义响应/主观重排),
//            docs/05-planning/phase3f-execution-plan.md → 3F.6 (Production search 与 feedback)
// 任务: 3F.6 - Production search 与 feedback（跨 App 意图解析骨架）
// AC 覆盖: US-SRC-010 (healthMemory/locationPhoto/plainSearch 域分发, sources 授权校验意图),
//          US-SRC-011 (subjective 主观查询标记, 供 BoundedReranker 消费)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007 (禁止 unchecked Sendable),
//           R-008 (跨 Actor 调用必须 await), R-006 (PrivacyCheckpoint 注入意图见各方法文档),
//           AGENTS.md §1.2 (R-001 数据主权 — 解析器纯本地，无网络调用)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 状态: GREEN — 3F.6 实现完成：parse 落地（域分发 + sources + temporalWindow + subjective）；
//       纯函数 isCrossAppQuery/classify 为已实现锚点（关键词启发式分类）
// 生成时间: 2026-08-11
// ==========================================

import Foundation

// MARK: - Cross App Domain

/// 跨 App 查询域（US-SRC-010）。
///
/// - healthMemory: 健康记忆域（健康关键词 × 记忆关键词，如「睡眠日记」）
/// - locationPhoto: 位置照片域（位置关键词 × 照片关键词，如「附近的夜景照片」）
/// - plainSearch: 普通检索域（不触发跨 App 分发，走标准 SearchPipeline）
public enum CrossAppDomain: String, Sendable, Equatable {
    case healthMemory
    case locationPhoto
    case plainSearch

    // MARK: Equatable（SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，显式 nonisolated）
    public nonisolated static func == (lhs: CrossAppDomain, rhs: CrossAppDomain) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

// MARK: - Cross App Intent

/// 解析后的跨 App 检索意图（US-SRC-010/011）。
public struct CrossAppIntent: Sendable, Equatable {
    /// 意图所属域（决定分发目标）
    public nonisolated let domain: CrossAppDomain
    /// 请求的数据源类型列表（如 ["health", "photos"]；生产入口须经 PrivacyActor 授权校验）
    public nonisolated let sources: [String]
    /// 时间窗过滤（如「上个月」→ ClosedRange；nil = 不限）
    public nonisolated let temporalWindow: ClosedRange<Date>?
    /// 规范化后的查询文本（跨 App 分发与检索使用）
    public nonisolated let query: String
    /// 是否为主观查询（US-SRC-011：触发 BoundedReranker 主观重排）
    public nonisolated let subjective: Bool

    public nonisolated init(
        domain: CrossAppDomain,
        sources: [String],
        temporalWindow: ClosedRange<Date>? = nil,
        query: String,
        subjective: Bool = false
    ) {
        self.domain = domain
        self.sources = sources
        self.temporalWindow = temporalWindow
        self.query = query
        self.subjective = subjective
    }

    // MARK: Equatable（SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，显式 nonisolated）
    public nonisolated static func == (lhs: CrossAppIntent, rhs: CrossAppIntent) -> Bool {
        lhs.domain == rhs.domain
            && lhs.sources == rhs.sources
            && lhs.temporalWindow == rhs.temporalWindow
            && lhs.query == rhs.query
            && lhs.subjective == rhs.subjective
    }
}

// MARK: - Cross App Intent Parser Protocol

/// 跨 App 意图解析协议 — 将自然语言查询解析为结构化 `CrossAppIntent`。
///
/// 生产实现为纯函数 `CrossAppIntentParser`（无状态 struct，不依赖 Actor）。
/// 测试可注入确定性 Mock。
public protocol CrossAppIntentParserProtocol: Sendable {
    /// 解析查询文本。
    ///
    /// - Parameter query: 用户原始查询文本（中/英混合）
    /// - Returns: 结构化跨 App 意图
    /// - Throws: `CrossAppIntentError`（解析失败 / 源未授权）
    nonisolated func parse(query: String) async throws -> CrossAppIntent
}

// MARK: - Cross App Intent Parser

/// 跨 App 意图解析器（US-SRC-010/011）— 纯函数实现（struct，非 Actor）。
///
/// ## 解析策略
/// 关键词启发式分类（`isCrossAppQuery` / `classify`）：
/// - 健康关键词（心率/heart/失眠/insomnia/睡眠/sleep/血压/blood）× 记忆关键词
///   （日记/diary/备忘/note/记录/record）→ `.healthMemory`
/// - 位置关键词（附近/near/where/位置/location/place）× 照片关键词
///   （照片/photo/夜景/构图/composition）→ `.locationPhoto`
/// - 其余 → `.plainSearch`
///
/// ## 隐私校验（R-006）
/// 解析本身为纯本地文本分类（无隐私操作）。生产分发入口（跨 App 检索执行者）
/// 须注入 PrivacyCheckpoint（operation: .search）并对 `sources` 逐项校验
/// `UserPolicy.authorizedSourceTypes`，未授权源抛 `.unauthorizedSource`。
/// （TDD RED 骨架：parse 占位实现直接 throw，不执行实际解析。）
public struct CrossAppIntentParser: CrossAppIntentParserProtocol {

    // MARK: - Keyword Sets (Pure Heuristics)

    /// 健康关键词（US-SRC-010 healthMemory 域）
    private nonisolated static let healthKeywords: [String] = [
        "心率", "heart", "失眠", "insomnia", "睡眠", "sleep", "血压", "blood", "健康", "health",
    ]
    /// 记忆关键词（healthMemory 域）
    private nonisolated static let memoryKeywords: [String] = [
        "日记", "diary", "备忘", "note", "记录", "record", "笔记", "notes",
    ]
    /// 位置关键词（locationPhoto 域）
    private nonisolated static let locationKeywords: [String] = [
        "附近", "near", "where", "位置", "location", "place",
    ]
    /// 照片关键词（locationPhoto 域）
    private nonisolated static let photoKeywords: [String] = [
        "照片", "photo", "夜景", "构图", "composition", "图片", "image", "场景", "scene",
    ]
    /// 主观/模糊查询关键词（US-SRC-011：情绪/偏好类查询 → subjective 标记）
    private nonisolated static let subjectiveKeywords: [String] = [
        "氛围", "atmosphere", "构图", "composition", "好看", "beautiful",
        "有感觉", "feel", "意境", "mood", "夜景", "适合", "适合做",
    ]

    // MARK: - Initialization

    public nonisolated init() {}

    // MARK: - CrossAppIntentParserProtocol

    /// 解析查询文本为结构化跨 App 意图（US-SRC-010/011）。
    ///
    /// **实现流程**（3F.6 GREEN）：
    /// 1. `classify(query)` 判定域（.plainSearch 不触发跨 App 分发）
    /// 2. 按域组装 `sources`（healthMemory → ["health", "memory"(, "photo")]；
    ///    locationPhoto → ["location", "photo"]；plainSearch → []）
    /// 3. 提取 `temporalWindow`：中文日期短语（如「8月1日 / 8月1号」）→ 当日
    ///    Gregorian UTC 全天闭区间（测试时间戳为 UTC，窗口须包含同一时刻）
    /// 4. 主观标记（US-SRC-011）：命中情绪/偏好关键词 → `subjective = true`
    ///
    /// 隐私校验（R-006）：解析本身为纯本地文本分类；生产分发入口须对 `sources`
    /// 逐项校验 `UserPolicy.authorizedSourceTypes`（见 CrossAppFusionEngine）。
    ///
    /// - Parameter query: 用户原始查询文本
    /// - Returns: 结构化跨 App 意图
    public nonisolated func parse(query: String) async throws -> CrossAppIntent {
        let domain = Self.classify(query)
        let lowered = query.lowercased()
        let hasMemory = Self.memoryKeywords.contains { lowered.contains($0) }
        let hasPhoto = Self.photoKeywords.contains { lowered.contains($0) }

        var sources: [String] = []
        switch domain {
        case .healthMemory:
            sources.append("health")
            if hasMemory { sources.append("memory") }
            if hasPhoto { sources.append("photo") }
        case .locationPhoto:
            sources.append("location")
            if hasPhoto { sources.append("photo") }
        case .plainSearch:
            break
        }

        return CrossAppIntent(
            domain: domain,
            sources: sources,
            temporalWindow: Self.extractTemporalWindow(from: query),
            query: query,
            subjective: Self.subjectiveKeywords.contains { lowered.contains($0) }
        )
    }

    // MARK: - Pure Heuristics (Implemented)

    /// 是否为跨 App 查询（US-SRC-010）。
    ///
    /// 命中 healthMemory 或 locationPhoto 域返回 `true`，plainSearch 返回 `false`。
    ///
    /// - Parameter query: 用户查询文本
    /// - Returns: 是否触发跨 App 分发
    public nonisolated static func isCrossAppQuery(_ query: String) -> Bool {
        classify(query) != .plainSearch
    }

    /// 关键词启发式分类（纯函数，大小写不敏感，中文关键词不受影响）。
    ///
    /// 规则（US-SRC-010/011）：
    /// - 健康 × (记忆 | 照片) → `.healthMemory`（如「失眠日记」「心率超120时的运动照片」）
    /// - 位置 × 照片 → `.locationPhoto`（如「附近的夜景照片」）
    /// - 主观 × 照片 → `.locationPhoto`（US-SRC-011：如「有氛围感的夜景」「适合做头像的构图」）
    /// - 其余 → `.plainSearch`
    ///
    /// - Parameter query: 用户查询文本
    /// - Returns: 分类域（healthMemory / locationPhoto / plainSearch）
    private nonisolated static func classify(_ query: String) -> CrossAppDomain {
        let lowered = query.lowercased()

        let hasHealth = healthKeywords.contains { lowered.contains($0) }
        let hasMemory = memoryKeywords.contains { lowered.contains($0) }
        let hasLocation = locationKeywords.contains { lowered.contains($0) }
        let hasPhoto = photoKeywords.contains { lowered.contains($0) }
        let hasSubjective = subjectiveKeywords.contains { lowered.contains($0) }

        if hasHealth && (hasMemory || hasPhoto) {
            return .healthMemory
        }
        if hasLocation && hasPhoto {
            return .locationPhoto
        }
        if hasSubjective && hasPhoto {
            return .locationPhoto
        }
        return .plainSearch
    }

    // MARK: - Temporal Window (Pure)

    /// 提取中文日期短语的时间窗（US-SRC-010 AC-3）。
    ///
    /// 识别「N月M日 / N月M号」（如「8月1日」），构建该自然日（按当前年份）
    /// Gregorian UTC 全天闭区间 `[00:00:00, 23:59:59]`。融合引擎以 UTC 时间戳
    /// 对齐结果（测试契约的 utcDate 构造同为 Gregorian UTC），故窗口时区固定 UTC。
    /// 未命中日期短语 → `nil`（不限时间窗）。
    ///
    /// 年份假设（PR#58 CR-21）：无年份短语按当前年解析（有意设计）— 越界月/日
    /// （如 13月40日）被显式拒绝，避免 Calendar 归一化跨年；round-trip 校验保证
    /// 构造结果与解析分量一致。
    ///
    /// - Parameter query: 用户查询文本
    /// - Returns: 当日闭区间时间窗，或 nil
    private nonisolated static func extractTemporalWindow(from query: String) -> ClosedRange<Date>? {
        let pattern = #"(\d{1,2})月(\d{1,2})(?:日|号)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(query.startIndex..., in: query)
        guard let match = regex.firstMatch(in: query, range: nsRange),
              let monthRange = Range(match.range(at: 1), in: query),
              let dayRange = Range(match.range(at: 2), in: query),
              let month = Int(query[monthRange]),
              let day = Int(query[dayRange]),
              (1...12).contains(month),
              (1...31).contains(day) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: Date())
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: start) == year,
              calendar.component(.month, from: start) == month,
              calendar.component(.day, from: start) == day else { return nil }
        let end = start.addingTimeInterval(86_399)
        return start...end
    }
}

// MARK: - Cross App Source Provider

/// 跨 App 数据源提供者协议 — 抽象单一外部数据源检索（US-SRC-010）。
///
/// 生产实现按域绑定数据源（如健康记忆源 / 照片库源），
/// 检索前由分发入口注入 PrivacyCheckpoint 并校验源授权。
public protocol CrossAppSourceProvider: Sendable {
    /// 数据源类型（如 "health" / "photos"；须在 UserPolicy.authorizedSourceTypes 词汇表内）
    nonisolated var sourceType: String { get }

    /// 在指定时间窗内检索该数据源。
    ///
    /// - Parameters:
    ///   - query: 规范化查询文本
    ///   - window: 时间窗过滤（nil = 不限）
    /// - Returns: 排序后的源检索结果列表
    /// - Throws: `CrossAppIntentError`（未授权源等）
    nonisolated func search(
        query: String,
        window: ClosedRange<Date>?
    ) async throws -> [CrossAppSourceResult]
}

// MARK: - Cross App Source Result

/// 跨 App 数据源的单条检索结果。
public struct CrossAppSourceResult: Sendable {
    /// 命中记忆 ID（对应 CanonicalMemory.memoryId）
    public nonisolated let memoryId: UUID
    /// 数据源类型
    public nonisolated let sourceType: String
    /// 记忆时间戳（epoch 秒）
    public nonisolated let timestamp: TimeInterval
    /// 命中片段（展示用，可为 nil）
    public nonisolated let snippet: String?
    /// 源内匹配分数（0~1，越高越相关）
    public nonisolated let matchScore: Float

    public nonisolated init(
        memoryId: UUID,
        sourceType: String,
        timestamp: TimeInterval,
        snippet: String? = nil,
        matchScore: Float
    ) {
        self.memoryId = memoryId
        self.sourceType = sourceType
        self.timestamp = timestamp
        self.snippet = snippet
        self.matchScore = matchScore
    }
}

// MARK: - Cross App Intent Error

/// 跨 App 意图解析统一错误类型
public enum CrossAppIntentError: Error, LocalizedError, Sendable, Equatable {
    /// 骨架占位 — 解析尚未实现（TDD RED）
    case notImplemented
    /// 数据源未授权（R-006 校验后拒绝分发）
    case unauthorizedSource(sourceType: String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Cross-app intent parser not yet implemented"
        case .unauthorizedSource(let sourceType):
            return "Cross-app source not authorized: \(sourceType)"
        }
    }

    // MARK: Equatable（SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，显式 nonisolated）
    public nonisolated static func == (lhs: CrossAppIntentError, rhs: CrossAppIntentError) -> Bool {
        switch (lhs, rhs) {
        case (.notImplemented, .notImplemented): return true
        case (.unauthorizedSource(let a), .unauthorizedSource(let b)): return a == b
        default: return false
        }
    }
}
