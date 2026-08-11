// ==========================================
// 文件: SearchChannelAdapters.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RET-003 (双语结果), US-RET-008 (检索延迟),
//            US-PRV-001 AC-2 (被拒数据源不进 Retriever),
//            docs/05-planning/phase3f-execution-plan.md → 3F.6 (Production search 与 feedback)
// 任务: 3F.6 - Production search 与 feedback（多通道搜索适配器实现）
// AC 覆盖: US-RET-003 AC-3 ✅ (双语结果通道融合), US-RET-008 AC-1 ✅ (通道超时降级 timedOut 标记),
//          US-RET-008 AC-3 ✅ (部分结果返回不阻断其他通道), DEF-34-002 ✅ (L3 error 与 timeout 分离),
//          US-PRV-001 AC-2 ✅ (PrivacyCheckpoint 拒绝后通道返回空，不进 Retriever),
//          SearchPipeline R-3.7 (text_dense/vision_dense/ocr_text/lexical 四通道 RRF 融合输入)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007 (禁止 unchecked Sendable),
//           R-008 (跨 Actor 调用必须 await), R-006 (PrivacyCheckpoint 强制注入),
//           AGENTS.md §4.4 (L1~L4 统一错误分级 — 超时 L1 以 timedOut 返回，路由缺失 L3 以 error 字段携带)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 状态: ✅ 已实现 (2026-08-11 GREEN) — GenerationRoutedChannelAdapter.search 生产实现
// 生成时间: 2026-08-11 | 更新: 2026-08-11 (3F.6 实现)
// ==========================================

import Foundation
import NaturalLanguage
import ProximaKit

// MARK: - Search Channel Kind

/// 多通道搜索的通道类型（R-3.7，对应 SearchPipeline.channelWeights 键）。
///
/// - textDense: E5 文本稠密向量通道（ActiveRouteSet.textGeneration）
/// - visionDense: SigLIP2 视觉稠密向量通道（ActiveRouteSet.visionGeneration）
/// - ocrText: Vision OCR 文本通道（ActiveRouteSet.ocrGeneration）
/// - lexical: 词法全文通道（ActiveRouteSet.lexicalGeneration）
public enum SearchChannelKind: String, Sendable, CaseIterable {
    case textDense = "text_dense"
    case visionDense = "vision_dense"
    case ocrText = "ocr_text"
    case lexical = "lexical"
}

// MARK: - Channel Search Metadata

/// 单条通道命中项的元数据（RRF 融合后组装 SearchResultItem 时使用）。
public struct SearchChannelMetadata: Sendable {
    /// PHAsset.localIdentifier 或其他数据源引用
    public nonisolated let assetId: String
    /// 数据源类型（"photo", "video_frame", "video_audio", "text", "voice"）
    public nonisolated let sourceType: String
    /// 记忆关联的时间戳
    public nonisolated let timestamp: TimeInterval
    /// 原始文本内容（文本/语音记忆），nil = 图片/视频帧
    public nonisolated let originalText: String?
    /// 记忆的源语言（从 originalText 检测），nil = 无法检测
    public nonisolated let sourceLanguage: String?
    /// 余弦相似度（1.0 - distance，范围 0~1）
    public nonisolated let cosineSimilarity: Float

    public nonisolated init(
        assetId: String,
        sourceType: String,
        timestamp: TimeInterval,
        originalText: String? = nil,
        sourceLanguage: String? = nil,
        cosineSimilarity: Float
    ) {
        self.assetId = assetId
        self.sourceType = sourceType
        self.timestamp = timestamp
        self.originalText = originalText
        self.sourceLanguage = sourceLanguage
        self.cosineSimilarity = cosineSimilarity
    }
}

// MARK: - Channel Search Result

/// 单通道搜索结果（RRF 融合输入，US-RET-008 AC-1 超时降级）。
///
/// - `timedOut`: 通道超时标记 — 超时通道返回部分结果或空列表，不阻断其他通道
/// - `error`: 通道级错误（非阻断，RRF 融合时跳过该通道）
/// - `metadataByID`: 命中项 ID → 元数据映射（融合后组装 SearchResultItem）
public struct ChannelSearchResult: Sendable {
    /// 来源通道
    public nonisolated let channel: SearchChannelKind
    /// 按通道内相关度排序的命中 ID 列表
    public nonisolated let rankedIds: [UUID]
    /// 通道是否超时（US-RET-008 AC-1）
    public nonisolated let timedOut: Bool
    /// 通道级错误（nil = 成功）；`any Error` 存在性类型隐式 Sendable
    public nonisolated let error: Error?
    /// 命中项元数据映射
    public nonisolated let metadataByID: [UUID: SearchChannelMetadata]

    public nonisolated init(
        channel: SearchChannelKind,
        rankedIds: [UUID],
        timedOut: Bool = false,
        error: Error? = nil,
        metadataByID: [UUID: SearchChannelMetadata] = [:]
    ) {
        self.channel = channel
        self.rankedIds = rankedIds
        self.timedOut = timedOut
        self.error = error
        self.metadataByID = metadataByID
    }
}

// MARK: - Search Channel Adapter Protocol

/// 多通道搜索适配器协议 — 抽象单通道检索，支持依赖注入与测试 Mock。
///
/// 生产实现 `GenerationRoutedChannelAdapter` 按 `ActiveRouteSet` 路由到对应分代；
/// 测试 Mock 可注入固定结果（TDD RED 阶段的测试替身）。
public protocol SearchChannelAdapter: Sendable {
    /// 适配器服务的通道类型
    nonisolated var channel: SearchChannelKind { get }

    /// 对单通道执行检索。
    ///
    /// - Parameters:
    ///   - queryVector: 查询向量（textDense/visionDense 通道必传；ocrText/lexical 词法通道传 nil）
    ///   - queryText: 查询原文（ocrText/lexical 通道使用；稠密通道可忽略）
    ///   - k: 返回结果数量上限
    /// - Returns: 通道搜索结果（含排序 ID 与元数据）
    /// - Throws: `ChannelAdapterError` 按 L1~L4 分级（超时以 timedOut 标记返回，不 throw）
    nonisolated func search(
        queryVector: [Float]?,
        queryText: String,
        k: Int
    ) async throws -> ChannelSearchResult
}

// MARK: - Generation Routed Channel Adapter

/// 基于活跃路由（ActiveRouteSet）的分代路由通道适配器（R-A.4 / ADR-010）。
///
/// 每个适配器实例绑定一个通道类型，搜索时经 `GenerationRegistryActor` 解析活跃路由
/// 对应分代的 VectorStoreActor。词法通道（lexical）不查向量存储，走 LexicalEngine
/// （查询向量传 nil；当前分代路由未接入时返回 generationRouteMissing 错误结果）。
///
/// ## Actor 隔离（AGENTS.md §4.2）
/// - 持有 GenerationRegistryActor / PrivacyActor 不可变引用，跨 Actor 调用必须 await（R-008）
/// - 无本地可变状态
///
/// ## 隐私校验（R-006）
/// 入口注入 PrivacyCheckpoint：`await privacyActor.validate(operation: .search, traceID:)`，
/// `.denied` 时返回空通道结果（US-PRV-001 AC-2 — 被拒数据源数据绝不进入 Retriever），不抛错。
///
/// ## 错误语义（DEF-34-002，L1~L4 分级）
/// - L3 阻断（活跃路由缺失该通道分代 / 分代 store 未加载）→ `error: .generationRouteMissing`，timedOut=false
/// - L1 瞬态（store 检索超时 / 索引为空未就绪）→ `timedOut: true` 部分结果，error=nil
public actor GenerationRoutedChannelAdapter: SearchChannelAdapter {

    // MARK: - Properties

    /// 适配器服务的通道类型
    public nonisolated let channel: SearchChannelKind
    /// 分代注册 Actor（解析活跃路由与向量存储实例）
    private let generationRegistry: GenerationRegistryActor
    /// 通道向量维度（校验路由 manifest 维度匹配）
    private let dimension: Int
    /// 隐私校验 Actor（R-006，默认应用级 .shared）
    private let privacyActor: PrivacyActor
    /// 单通道检索超时阈值（秒，US-RET-008）
    private nonisolated let searchTimeoutSeconds: Double = 1.5

    // MARK: - Initialization

    /// 通道 → 路由 key 的映射由 `generationID(for:in:)` 静态函数按 `channel` 类型完成，
    /// 等价 `route[keyPath: generationKey]`（PR#58 CR-28：移除未使用的 KeyPath 参数 —
    /// KeyPath 非 Sendable，仅作映射键无存储价值）。
    public init(
        generationRegistry: GenerationRegistryActor,
        kind: SearchChannelKind,
        dimension: Int,
        privacyActor: PrivacyActor = .shared
    ) {
        self.generationRegistry = generationRegistry
        self.channel = kind
        self.dimension = dimension
        self.privacyActor = privacyActor
    }

    // MARK: - SearchChannelAdapter

    /// 对单通道执行检索（US-RET-008 / DEF-34-002 / US-PRV-001 AC-2）。
    ///
    /// **生产实现流程**：
    /// 1. PrivacyCheckpoint（R-006）：`privacyActor.validate(operation: .search, traceID:)`，
    ///    `.denied` → 返回空通道结果（不进 Retriever，不抛错）
    /// 2. `await generationRegistry.loadActiveRoute()` 解析路由；按通道类型读取该通道分代 ID
    ///    （缺失 → `error: .generationRouteMissing`，timedOut=false）
    /// 3. `await generationRegistry.vectorStore(for:)` 获取分代 store（缺失 → 同上 L3 错误）
    /// 4. 空索引（未就绪）→ `timedOut: true` 空部分结果（US-RET-008 AC-1 降级语义）
    /// 5. `store.search(query:k:)` 以 1.5s 超时执行；超时 → `timedOut: true` 部分结果（不 throw）
    /// 6. 解码 `MemoryEntry.decodeMetadata` → `SearchChannelMetadata`（ID-keyed，DEF-34-001）
    public nonisolated func search(
        queryVector: [Float]?,
        queryText: String,
        k: Int
    ) async throws -> ChannelSearchResult {
        // 1. R-006: PrivacyCheckpoint（AGENTS.md §7.1 标准形态）
        let traceID = UUID().uuidString
        let checkpoint = await privacyActor.validate(operation: .search, traceID: traceID)
        guard checkpoint.isAllowed else {
            // US-PRV-001 AC-2: 被拒数据源数据绝不进入 Retriever — 空通道结果
            return ChannelSearchResult(channel: channel, rankedIds: [], timedOut: false)
        }

        // PR#58 CR-22: lexical 通道尚未接入 LexicalEngine — fail-closed（L3 error），
        // 禁止零向量检索产生垃圾排序参与 RRF 融合（README「lexical 就绪」仅指路由存在）。
        if channel == .lexical {
            return ChannelSearchResult(
                channel: channel,
                rankedIds: [],
                timedOut: false,
                error: ChannelAdapterError.lexicalNotConnected(channel: channel)
            )
        }

        // 2. 解析活跃路由 → 该通道分代 ID（DEF-34-002: L3 路由缺失 ≠ 超时）
        guard let route = try? await generationRegistry.loadActiveRoute(),
              let generationId = Self.generationID(for: channel, in: route) else {
            return ChannelSearchResult(
                channel: channel,
                rankedIds: [],
                timedOut: false,
                error: ChannelAdapterError.generationRouteMissing(channel: channel)
            )
        }

        // 3. 分代向量 store（未加载 → L3 错误结果，不 throw）
        guard let store = await generationRegistry.vectorStore(for: generationId) else {
            return ChannelSearchResult(
                channel: channel,
                rankedIds: [],
                timedOut: false,
                error: ChannelAdapterError.generationRouteMissing(channel: channel)
            )
        }

        // 4. 空索引 = 通道未就绪：降级为 timedOut 部分结果（US-RET-008 AC-1/AC-3）
        if await store.isEmpty {
            return ChannelSearchResult(channel: channel, rankedIds: [], timedOut: true)
        }

        // 5. 检索（超时降级为部分结果，绝不 throw — 不阻断其他通道）
        let query = queryVector ?? [Float](repeating: 0, count: dimension)
        let searchK = max(1, k)
        let results: [SearchResult]
        do {
            results = try await Self.withTimeout(seconds: searchTimeoutSeconds) {
                await store.search(query: query, k: searchK)
            }
        } catch {
            return ChannelSearchResult(channel: channel, rankedIds: [], timedOut: true)
        }

        // PR#58 CR-9: 逐源授权过滤（US-PRV-001 AC-2，与经典 search() 的 policy 过滤一致）—
        // 撤销数据源的历史命中不得经多通道返回；decode 失败的命中（sourceType 未知）同样剔除。
        let policy = await privacyActor.getPolicy()

        // 6. 解码元数据（ID-keyed，DEF-34-001：融合后经 ID 映射组装，禁止 top-1 re-search）
        var metadataByID: [UUID: SearchChannelMetadata] = [:]
        var rankedIds: [UUID] = []
        for result in results {
            guard let metadata = try? MemoryEntry.decodeMetadata(from: result.metadata ?? Data()) else { continue }
            guard policy.isAuthorized(sourceType: SearchPipeline.normalizeSourceType(metadata.sourceType)) else {
                continue
            }
            metadataByID[result.id] = SearchChannelMetadata(
                assetId: metadata.assetId,
                sourceType: metadata.sourceType,
                timestamp: metadata.timestamp,
                originalText: metadata.originalText,
                sourceLanguage: Self.detectLanguage(from: metadata.originalText),
                cosineSimilarity: 1.0 - Float(result.distance)
            )
            rankedIds.append(result.id)
        }
        return ChannelSearchResult(
            channel: channel,
            rankedIds: rankedIds,
            timedOut: false,
            metadataByID: metadataByID
        )
    }

    // MARK: - Private Helpers

    /// 通道类型 → 活跃路由中的分代 ID（等效 `route[keyPath: generationKey]`）。
    private nonisolated static func generationID(
        for kind: SearchChannelKind,
        in route: ActiveRouteSet
    ) -> String? {
        switch kind {
        case .textDense: return route.textGeneration
        case .visionDense: return route.visionGeneration
        case .ocrText: return route.ocrGeneration
        case .lexical: return route.lexicalGeneration
        }
    }

    /// 检测文本语言（NLTagger，置信度 < 0.9 标记 mixed；繁体映射 zh-Hans，AGENTS.md §6.1）。
    /// 与 SearchPipeline.detectLanguage 共享（PR#58 CR-30 单一实现，防漂移）。
    nonisolated static func detectLanguage(from text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let tagger = NLTagger(tagSchemes: [.language])
        tagger.string = text
        let (hypotheses, _) = tagger.tagHypotheses(
            at: text.startIndex,
            unit: .document,
            scheme: .language,
            maximumCount: 1
        )
        guard let (rawLanguage, confidence) = hypotheses.first,
              confidence >= 0.9 else {
            return "mixed"
        }
        switch rawLanguage {
        case "en": return "en-US"
        case "zh", "zh-Hans", "zh-Hant", "zh-HK", "zh-TW", "yue": return "zh-Hans"
        default: return "mixed"
        }
    }

    /// 带超时的异步操作封装（US-RET-008 AC-1，与 SearchPipeline.withTimeout 同型）。
    ///
    /// 竞速模式：操作先完成 → 返回结果；超时先触发 → 抛错（调用方降级为部分结果）。
    /// 显式消费被取消任务的错误，避免 withThrowingTaskGroup 隐式重抛 CancellationError。
    private nonisolated static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            do { _ = try await group.next() } catch { /* cancelled, expected */ }
            return result
        }
    }
}

// MARK: - Channel Adapter Error

/// 通道适配器统一错误类型（L1~L4 分级，AGENTS.md §4.4）。
public enum ChannelAdapterError: Error, LocalizedError, Sendable, Equatable {
    /// 活跃路由缺少该通道的分代（L3 阻断：路由降级，通道被跳过）
    case generationRouteMissing(channel: SearchChannelKind)
    /// 通道检索超时（L1 瞬态：调用方按 timedOut 语义降级）
    case timeout(channel: SearchChannelKind)
    /// 词法通道尚未接入 LexicalEngine（L3 阻断：fail-closed，禁止零向量检索，PR#58 CR-22）
    case lexicalNotConnected(channel: SearchChannelKind)

    public var errorDescription: String? {
        switch self {
        case .generationRouteMissing(let channel):
            return "Active route missing generation for channel \(channel.rawValue)"
        case .timeout(let channel):
            return "Search channel \(channel.rawValue) timed out"
        case .lexicalNotConnected(let channel):
            return "Search channel \(channel.rawValue) not connected (LexicalEngine pending)"
        }
    }

    // MARK: Equatable（SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，显式 nonisolated）
    public nonisolated static func == (lhs: ChannelAdapterError, rhs: ChannelAdapterError) -> Bool {
        switch (lhs, rhs) {
        case (.generationRouteMissing(let a), .generationRouteMissing(let b)): return a == b
        case (.timeout(let a), .timeout(let b)): return a == b
        case (.lexicalNotConnected(let a), .lexicalNotConnected(let b)): return a == b
        default: return false
        }
    }
}
