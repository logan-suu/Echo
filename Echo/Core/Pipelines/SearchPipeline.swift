// ==========================================
// 文件: SearchPipeline.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RET-001~004 (跨语言检索 + 元数据过滤),
//            US-FBK-002 (本地反馈驱动重排),
//            US-RET-006 (跨语言低置信度降级)
//            docs/02-architecture/数据流全链路技术说明文档.md §2 (用户发起检索数据流),
//            docs/02-architecture/架构设计文档.md §2.1 (SearchPipeline)
//            docs/03-implementation/双语言实现说明文档.md §4 (跨语言检索管线)
// 任务: 2.6 - SearchPipeline：向量检索 + FTS5 过滤
//        2.8 - 集成反馈到 SearchPipeline
//        2.9 - 跨语言低置信度降级（US-RET-006）
//        3F.6 - 跟进查询审计（US-RET-005 AC-4）+ 生产多通道检索（R-3.7/DEF-34-001）
// AC 覆盖: US-RET-001 AC-1 ✅ (余弦相似度), AC-3 ✅ (crossLanguageMatch标记), AC-4 ✅ (审计),
//          AC-2 🔮 (Cross-Encoder, Phase 3), AC-5 🔮 (Recall@10, Golden Dataset Phase 3)
//          US-RET-002 ✅ (中文→英文, 同 RET-001)
//          US-RET-003 AC-1 ✅ (mixed语言检测), AC-3 ✅ (双语结果), AC-4 ✅ (审计),
//          AC-2 🔮 (CLIP空间验证, Phase 3)
//          US-RET-004 AC-1 🔴 (FTS5预过滤, deferred: 当前为ANN post-filter过渡; 需SQLite FTS5+IngestPipeline同步),
//          AC-2 🔴 (人物过滤, deferred: 需元数据扩展), AC-3 🔴 (geohash过滤, deferred: 需坐标存储),
//          AC-4 🔮 (P95延迟基准, Phase 3 Benchmark), AC-5 ✅ (审计filterApplied)
//          US-FBK-002 AC-1 ✅ (阈值≥0.80), AC-2 ✅ (时间衰减), AC-3 ✅ (重排公式, via FeedbackActor)
//          US-RET-006 AC-1 ✅ (alignmentScore<0.6→lowConfidence), AC-3 ✅ (结果不被过滤),
//          AC-5 ✅ (审计 alignmentScore/fallbackReason/lowConfidenceCount/fallbackReasons)
//          AC-2 🔮 (UI提示文案, Phase 3 SearchView), AC-4 🔮 (不准确反馈按钮, Phase 3 SearchView)
//          US-RET-005 AC-4 ✅ (followUpQuery 审计携带父 traceID, 2026-08-11 3F.6)
//          DEF-34-001 ✅ (RRF 融合 + ID-keyed 元数据组装, 禁止 top-1 re-search, 2026-08-11 3F.6)
// 架构约束: AGENTS.md §4.1 (Pipeline 契约 — 纯函数、无状态、审计强制、错误分级),
//           AGENTS.md §5.3 (反馈存储契约),
//           R-006 (PrivacyCheckpoint 强制注入), R-008 (跨 Actor await),
//           AGENTS.md §4.4 (L1~L4 统一错误分级),
//           PIPE-002 (翻译仅限展示层, Retriever 返回源语言原文)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 注: 3F.6 起 Pipeline 持有两条会话级可变状态（lastSearchTraceID/lastSearchQuery）用于
//     US-RET-005 AC-4 跟进查询审计（approach a: 同查询复用，无 LLM rewrite）—
//     actor 串行执行保证无竞争；此为该 AC 的唯一可落地实现（§12.4 决策记录于 3F.6 PR）
// 生成时间: 2026-07-12 | 更新: 2026-08-11 (3F.6)
// ==========================================

import Foundation
import ProximaKit

// MARK: - Search Pipeline Error

/// SearchPipeline 统一错误类型（L1~L4 分级，AGENTS.md §4.4）
public enum SearchError: Error, LocalizedError, Sendable, Equatable {
    /// 隐私校验拒绝 — 用户未授权搜索功能
    case privacyDenied(sourceTypes: [String])
    /// 查询文本为空
    case emptyQuery
    /// 嵌入生成失败 — 模型未加载或推理失败（L3 阻断）
    case embeddingFailed(underlying: Error)
    /// 向量检索超时（2s），返回部分结果（US-RET-008）
    case searchTimeout(partialResults: [SearchResultItem])
    /// 审计日志写入失败（L1 瞬态，非阻断）
    case auditLogFailed(underlying: Error)

    /// L1~L4 错误分级
    public nonisolated var errorLevel: Int {
        switch self {
        case .privacyDenied:              return 2  // L2 可恢复
        case .emptyQuery:                 return 2  // L2 可恢复
        case .embeddingFailed:            return 3  // L3 阻断
        case .searchTimeout:              return 1  // L1 瞬态（部分结果已返回）
        case .auditLogFailed:             return 1  // L1 瞬态
        }
    }

    public var errorDescription: String? {
        switch self {
        case .privacyDenied(let types):
            return "Search privacy denied for source types: \(types.joined(separator: ","))"
        case .emptyQuery:
            return "Search query is empty or whitespace-only"
        case .embeddingFailed(let error):
            return "Query embedding failed: \(error.localizedDescription)"
        case .searchTimeout(let partial):
            return "Search timed out after 2s, returning \(partial.count) partial results"
        case .auditLogFailed(let error):
            return "Audit log write failed (non-blocking): \(error.localizedDescription)"
        }
    }

    // MARK: Equatable
    public static func == (lhs: SearchError, rhs: SearchError) -> Bool {
        switch (lhs, rhs) {
        case (.privacyDenied(let a), .privacyDenied(let b)): return a == b
        case (.emptyQuery, .emptyQuery): return true
        case (.embeddingFailed, .embeddingFailed): return true
        case (.searchTimeout(let a), .searchTimeout(let b)):
            return a.map(\.id) == b.map(\.id)
        case (.auditLogFailed, .auditLogFailed): return true
        default: return false
        }
    }
}

// MARK: - Search Filter

/// 多维元数据过滤器（US-RET-004 AC-1）。
///
/// 支持时间范围、标签、地理半径过滤。
/// 所有字段可选 — nil 表示不过滤该维度。
/// 人物 ID 过滤已移除（R-5.3：US-SRC-006 v1.0 延后，PHAsset 无 People 身份标签）。
public struct SearchFilter: Sendable, Equatable {
    /// 时间范围过滤（闭区间）
    public nonisolated let timeRange: ClosedRange<Date>?
    /// 标签关键词匹配
    public nonisolated let tags: [String]?
    /// 地理半径过滤
    public nonisolated let geoRadius: GeoFilter?

    public nonisolated init(
        timeRange: ClosedRange<Date>? = nil,
        tags: [String]? = nil,
        geoRadius: GeoFilter? = nil
    ) {
        self.timeRange = timeRange
        self.tags = tags
        self.geoRadius = geoRadius
    }

    /// 是否有任何活跃的过滤维度
    public nonisolated var isEmpty: Bool {
        timeRange == nil && tags == nil && geoRadius == nil
    }

    /// 活跃的过滤维度名称列表（用于审计）
    public nonisolated var activeDimensions: [String] {
        var dims: [String] = []
        if timeRange != nil { dims.append("time") }
        if tags != nil { dims.append("tags") }
        if geoRadius != nil { dims.append("geo") }
        return dims
    }
}

/// 地理半径过滤器（US-RET-004 AC-3）
public struct GeoFilter: Sendable, Equatable {
    public nonisolated let latitude: Double
    public nonisolated let longitude: Double
    public nonisolated let radiusKm: Double

    public nonisolated init(latitude: Double, longitude: Double, radiusKm: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.radiusKm = radiusKm
    }

    // Explicit nonisolated Equatable (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor)
    public nonisolated static func == (lhs: GeoFilter, rhs: GeoFilter) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude && lhs.radiusKm == rhs.radiusKm
    }
}

// MARK: - Search Result Item

/// 单条检索结果（US-RET-001 AC-3, US-RET-004 AC-5）。
///
/// 包含元数据、语言标记、跨语言匹配信息。
/// 翻译仅在展示层触发（PIPE-002）。
public struct SearchResultItem: Sendable, Identifiable, Equatable {
    /// 记忆唯一标识符（对应 VectorStoreActor 的向量 ID）
    public nonisolated let id: UUID
    /// PHAsset.localIdentifier 或其他数据源引用
    public nonisolated let assetId: String
    /// 数据源类型（"photo", "video_frame", "video_audio", "text", "voice"）
    public nonisolated let sourceType: String
    /// 记忆关联的时间戳
    public nonisolated let timestamp: TimeInterval
    /// 原始文本内容（文本/语音记忆），nil = 图片/视频帧
    public nonisolated let originalText: String?
    /// 记忆的源语言（从 originalText 检测），nil = 无法检测（图片等）
    public nonisolated let sourceLanguage: String?
    /// 是否为跨语言匹配（query 语言 ≠ 记忆源语言）
    public nonisolated let crossLanguageMatch: Bool
    /// 余弦相似度（1.0 - distance，范围 0~1；ProximaKit 返回余弦距离 [0,2]）
    public nonisolated let cosineSimilarity: Float
    /// 跨语言对齐置信度（保留字段，Cross-Encoder 精排后填充，Phase 3）
    public nonisolated let alignmentScore: Float?
    /// 反馈调整值（保留字段，FeedbackActor 集成后填充，Task 2.8）
    public nonisolated let feedbackAdjustment: Float?
    /// 跨语言低置信度标记（US-RET-006 AC-1: alignmentScore < 0.6 → true）
    public nonisolated let lowConfidence: Bool
    /// 低置信度原因（US-RET-006 AC-1/AC-5: fallbackReason）
    public nonisolated let fallbackReason: String?
    /// 未生效的过滤器（R-1.7）— 调用方传入但当前实现为 no-op 的过滤维度（如 tags/geoRadius）
    public nonisolated let unappliedFilters: [String]

    public nonisolated init(
        id: UUID,
        assetId: String,
        sourceType: String,
        timestamp: TimeInterval,
        originalText: String? = nil,
        sourceLanguage: String? = nil,
        crossLanguageMatch: Bool = false,
        cosineSimilarity: Float,
        alignmentScore: Float? = nil,
        feedbackAdjustment: Float? = nil,
        lowConfidence: Bool = false,
        fallbackReason: String? = nil,
        unappliedFilters: [String] = []
    ) {
        self.id = id
        self.assetId = assetId
        self.sourceType = sourceType
        self.timestamp = timestamp
        self.originalText = originalText
        self.sourceLanguage = sourceLanguage
        self.crossLanguageMatch = crossLanguageMatch
        self.cosineSimilarity = cosineSimilarity
        self.alignmentScore = alignmentScore
        self.feedbackAdjustment = feedbackAdjustment
        self.lowConfidence = lowConfidence
        self.fallbackReason = fallbackReason
        self.unappliedFilters = unappliedFilters
    }
}

// MARK: - Search Pipeline

/// 检索管线 — 协调向量检索 + 元数据过滤 + 跨语言匹配标记。
///
/// ## Pipeline 契约（AGENTS.md §4.1）
/// - 纯函数性: 相同输入产生相同输出（通过依赖注入的 embedder + actor）
/// - 无状态: Pipeline 本身不持有可变状态（仅持有对其他 Actor 的不可变引用）
/// - 副作用隔离: 所有副作用通过 Actor 调用实现
/// - 审计强制: 每个 search() 方法入口调用 PrivacyActor.validate()（R-006）
/// - 错误分级: 所有 throws 映射到 L1~L4 统一错误矩阵（AGENTS.md §4.4）
///
/// ## 依赖注入
/// - `embedder`: 嵌入服务（multilingual-e5-small 文本编码），生产/测试均可注入
/// - `privacyActor`: 隐私校验 Actor（默认 .shared）
/// - `vectorStore`: 向量存储 Actor
///
/// ## 数据流（架构文档 §2.1）
/// ```
/// search(query) → PrivacyActor.validate() → Embedder.embedText(query)
///     → VectorStoreActor.search(queryVector, k=100)
///     → post-filter metadata (time/tags/geo)
///     → detect languages (query, source)
///     → mark crossLanguageMatch
///     → FeedbackActor.computeBatchAdjustments() [US-FBK-002]
///     → re-sort by finalScore = cosineSimilarity + adjustment
///     → PrivacyActor.writeAuditLog(.retrieval)
///     → return top-K SearchResultItem[]
/// ```
///
/// ## 翻译隔离（PIPE-002）
/// Retriever 不翻译 — 仅返回源语言原文 + 语言标记。
/// 展示层翻译通过 SearchViewModel 调用 TranslationService 触发。
public actor SearchPipeline {

    // MARK: - Dependencies

    private let embedder: any EmbedderProtocol
    private let privacyActor: PrivacyActor
    private let vectorStore: VectorStoreActor
    private let feedbackActor: FeedbackActor
    /// 3F.11 fix: canonical 仓库 — legacy MemoryEntry 元数据解码失败时按 ID 回填
    /// （canonical 分代 store 不写 legacy 元数据，sourceType 变 "unknown" 会被授权过滤剔除）
    private let canonicalRepository: CanonicalMemoryRepositoryActor?
    /// WP4 steps 5 基础设施：多通道查询表示工厂（可选，nil 时保持既有仅文本搜索行为不变）
    private let queryFactory: (any QueryRepresentationFactory)?
    /// WP4 尾刀：分代注册表引用——searchTyped 内部按活跃路由解析快照与适配器（可选）
    private let generationRegistry: GenerationRegistryActor?

    /// typed 多通道路径是否可用（queryFactory 注入且路由 ENABLED 后由 UI 采用）
    public nonisolated var supportsTypedSearch: Bool { queryFactory != nil }

    // MARK: - Session State (US-RET-005 AC-4)

    /// 上一次检索的 traceID（跟进查询审计的父 traceID；nil = 尚无前序轮次）
    private var lastSearchTraceID: String?
    /// 上一次检索的规范化查询文本（approach a: 仅同查询复用视为跟进，无 LLM rewrite）
    private var lastSearchQuery: String?

    // MARK: - Configuration

    /// ANN 检索候选集大小（供后续精排/过滤使用）
    private nonisolated let annCandidateCount: Int = 100

    /// 搜索超时阈值（秒，US-RET-008）
    private nonisolated let searchTimeoutSeconds: Double = 2.0

    // MARK: - R-3.7: RRF Configuration

    /// RRF 常数 k（默认 60，标准 RRF 参数）
    private nonisolated static let rrfK: Double = 60.0

    /// 各通道 RRF 权重（初始值，基于离线评测调整）
    private nonisolated static let channelWeights: [String: Double] = [
        "text_dense": 1.0,
        "vision_dense": 0.8,
        "ocr_text": 0.6,
        "lexical": 0.5,
    ]

    /// 单通道搜索超时（秒）— 超时通道被跳过，不影响其他通道
    private nonisolated static let channelTimeoutSeconds: Double = 1.5

    // MARK: - Initialization

    public init(
        embedder: any EmbedderProtocol,
        privacyActor: PrivacyActor = .shared,
        vectorStore: VectorStoreActor,
        feedbackActor: FeedbackActor = .shared,
        canonicalRepository: CanonicalMemoryRepositoryActor? = nil,
        queryFactory: (any QueryRepresentationFactory)? = nil,
        generationRegistry: GenerationRegistryActor? = nil
    ) {
        self.embedder = embedder
        self.privacyActor = privacyActor
        self.vectorStore = vectorStore
        self.feedbackActor = feedbackActor
        self.canonicalRepository = canonicalRepository
        self.queryFactory = queryFactory
        self.generationRegistry = generationRegistry
    }

    // MARK: - Search

    /// 执行语义检索（US-RET-001~004）。
    ///
    /// **流程**（对应架构文档 §2.1 检索时序 + US-FBK-002 反馈重排）：
    /// 1. Guard: 查询非空
    /// 2. PrivacyCheckpoint: 校验搜索授权（R-006）
    /// 3. Embedding: embedder.embedText(query) → 向量
    /// 4. ANN 检索: VectorStoreActor.search(queryVector, k=100)
    /// 5. Post-filter: 应用 SearchFilter 条件（时间/标签/地点/人物）
    /// 6. 语言检测: 查询语言 + 各结果源语言 → 标记 crossLanguageMatch
    /// 7. `top-K` 截断
    /// 8. Feedback: FeedbackActor.computeBatchAdjustments() → 应用重排
    /// 9. Sort by finalScore = cosineSimilarity + adjustment
    /// 10. Audit: 记录 .retrieval（AC-4, AC-5）
    ///
    /// - Parameters:
    ///   - query: 用户查询文本（中/英/混合语言）
    ///   - k: 返回结果数量（默认 10）
    ///   - filter: 可选多维元数据过滤器（US-RET-004 AC-1）
    ///   - traceID: 审计追溯 ID（默认自动生成）
    /// - Returns: 按余弦相似度降序排列的检索结果
    /// - Throws: `SearchError` 按 L1~L4 分级
    public func search(
        query: String,
        k: Int = 10,
        filter: SearchFilter? = nil,
        traceID: String = UUID().uuidString
    ) async throws -> [SearchResultItem] {
        let startTime = Date()

        // Step 1: Guard against empty query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SearchError.emptyQuery
        }

        // Step 1.5: Follow-up tracking (US-RET-005 AC-4, approach a: same query reuse)
        // 上一轮存在且查询文本一致 → 本轮为跟进查询；审计携带父轮次 traceID。
        // 会话状态仅在 checkpoint 通过后写入（PR#58 CR-3）：被拒查询不得成为下一轮的父轮次。
        let isFollowUp = lastSearchTraceID != nil && lastSearchQuery == trimmed
        let parentTrace = lastSearchTraceID

        // Step 2: PrivacyCheckpoint (R-006)
        let checkpoint = await privacyActor.validate(
            operation: .search,
            traceID: traceID,
            sourceTypes: ["search"]
        )
        guard checkpoint.isAllowed else {
            throw SearchError.privacyDenied(sourceTypes: checkpoint.sourceTypes)
        }

        // Step 2.5: checkpoint 通过后更新会话状态（R-006 顺序 — 拒绝不污染 follow-up 追踪）
        lastSearchQuery = trimmed
        lastSearchTraceID = traceID

        // Step 3: Generate query embedding (multilingual-e5-small → 384d)
        let rawEmbedding: [Float]
        do {
            rawEmbedding = try await embedder.embedText(query, context: .query)
        } catch {
            throw SearchError.embeddingFailed(underlying: error)
        }

        // 3F.11 fix: 查询向量对齐到目标 store 的原生维度（不再固定零填充到 512）。
        // 生产分代 store 为原生维度（text_dense=E5 384d，ADR-006「不补零」）——
        // 固定填充 512 导致 384d store 维度不匹配、搜索永远返回空。
        let storeDimension = await vectorStore.dimension
        let queryVector = Self.alignVector(rawEmbedding, to: storeDimension)

        // Step 4: ANN search with timeout (US-RET-008)
        let searchK = max(k, min(annCandidateCount, 100))
        let annResults = try await withTimeout(seconds: searchTimeoutSeconds) {
            await self.vectorStore.search(query: queryVector, k: searchK)
        }

        // Step 5: Convert ProximaKit SearchResult → SearchResultItem
        var items: [SearchResultItem] = []
        for result in annResults {
            let metadata = try? MemoryEntry.decodeMetadata(from: result.metadata ?? Data())
            let sourceLang = detectLanguage(from: metadata?.originalText)
            if case nil = metadata, let canonicalRepository {
                // 3F.11 fix: canonical 回填 — 分代 store 不写 legacy MemoryEntry 元数据，
                // 按记忆 ID 从 canonical Memory 表读取（assetId/sourceType/文本/时间戳）
                if let memory = try? await canonicalRepository.loadMemory(memoryId: result.id) {
                    items.append(SearchResultItem(
                        id: result.id,
                        assetId: memory.sourceLocator,
                        sourceType: memory.sourceType,
                        timestamp: memory.createdAt.timeIntervalSince1970,
                        originalText: memory.canonicalText,
                        sourceLanguage: detectLanguage(from: memory.canonicalText),
                        crossLanguageMatch: false, // set in step 6
                        cosineSimilarity: 1.0 - Float(result.distance)
                    ))
                    continue
                }
            }
            items.append(SearchResultItem(
                id: result.id,
                assetId: metadata?.assetId ?? "",
                sourceType: metadata?.sourceType ?? "unknown",
                timestamp: metadata?.timestamp ?? Date().timeIntervalSince1970,
                originalText: metadata?.originalText,
                sourceLanguage: sourceLang,
                crossLanguageMatch: false, // set in step 6
                cosineSimilarity: 1.0 - Float(result.distance)
            ))
        }

        // Step 6: Apply metadata post-filter (US-RET-004 AC-1) + R-1.6/R-1.7
        // NOTE: Current implementation is ANN post-filtering.
        // True FTS5 pre-filtering (ANN search within pre-filtered candidate set)
        // requires a SQLite FTS5 metadata table — deferred to Phase 3 optimization.
        var unappliedFilters: [String] = []
        if let f = filter, !f.isEmpty {
            let result = applyFilter(items, filter: f)
            items = result.filtered
            unappliedFilters = result.unapplied
        }

        // R-1.6: 按当前授权集过滤结果 — 撤销某数据源后其历史数据不得再返回。
        // 注意：记忆 sourceType 是细粒度（video_frame/video_audio/text），授权词汇表是
        // 粗粒度数据源（photo/note/voice/video）。过滤前必须归一化，否则视频/文本记忆
        // 即使在授权集内也会被误过滤（P1 修复）。
        let policy = await privacyActor.getPolicy()
        items = items.filter { policy.isAuthorized(sourceType: Self.normalizeSourceType($0.sourceType)) }

        // R-1.7: 将未生效过滤器标记到每条结果
        if !unappliedFilters.isEmpty {
            for i in items.indices {
                items[i] = SearchResultItem(
                    id: items[i].id,
                    assetId: items[i].assetId,
                    sourceType: items[i].sourceType,
                    timestamp: items[i].timestamp,
                    originalText: items[i].originalText,
                    sourceLanguage: items[i].sourceLanguage,
                    crossLanguageMatch: items[i].crossLanguageMatch,
                    cosineSimilarity: items[i].cosineSimilarity,
                    alignmentScore: items[i].alignmentScore,
                    feedbackAdjustment: items[i].feedbackAdjustment,
                    lowConfidence: items[i].lowConfidence,
                    fallbackReason: items[i].fallbackReason,
                    unappliedFilters: unappliedFilters
                )
            }
        }

        // Step 7: Detect query language + mark crossLanguageMatch
        let queryLanguage = detectLanguage(from: query)
        for i in items.indices {
            items[i] = SearchResultItem(
                id: items[i].id,
                assetId: items[i].assetId,
                sourceType: items[i].sourceType,
                timestamp: items[i].timestamp,
                originalText: items[i].originalText,
                sourceLanguage: items[i].sourceLanguage,
                crossLanguageMatch: isCrossLanguage(
                    queryLang: queryLanguage,
                    sourceLang: items[i].sourceLanguage
                ),
                cosineSimilarity: items[i].cosineSimilarity,
                alignmentScore: items[i].alignmentScore,
                feedbackAdjustment: items[i].feedbackAdjustment,
                lowConfidence: items[i].lowConfidence,
                fallbackReason: items[i].fallbackReason,
                unappliedFilters: items[i].unappliedFilters
            )
        }

        // Step 8: Compute feedback adjustments (US-FBK-002 AC-1~3)
        // FeedbackActor.computeAdjustment() already clamps to [-0.5, 0.5].
        // Only memory IDs that exist in FeedbackStore with cosineSim ≥ 0.80 will have adjustments.
        if !items.isEmpty {
            let memoryIds = items.map(\.id)
            let adjustments: [UUID: FeedbackAdjustment]?
            do {
                adjustments = try await feedbackActor.computeBatchAdjustments(
                    for: memoryIds,
                    queryText: trimmed
                )
            } catch {
                // Feedback computation failed (L1 transient: db lock, etc.).
                // Graceful degradation: continue without feedback reranking.
                adjustments = nil
            }
            for i in items.indices {
                let adj = adjustments?[items[i].id]?.adjustment ?? 0.0
                items[i] = SearchResultItem(
                    id: items[i].id,
                    assetId: items[i].assetId,
                    sourceType: items[i].sourceType,
                    timestamp: items[i].timestamp,
                    originalText: items[i].originalText,
                    sourceLanguage: items[i].sourceLanguage,
                    crossLanguageMatch: items[i].crossLanguageMatch,
                    cosineSimilarity: items[i].cosineSimilarity,
                    alignmentScore: items[i].alignmentScore,
                    feedbackAdjustment: Float(adj),
                    lowConfidence: items[i].lowConfidence,
                    fallbackReason: items[i].fallbackReason,
                    unappliedFilters: items[i].unappliedFilters
                )
            }
        }

        // Step 9: Sort by finalScore (cosineSimilarity + feedbackAdjustment) descending, then take top-K
        items.sort { (lhs, rhs) in
            let lhsScore = Double(lhs.cosineSimilarity) + Double(lhs.feedbackAdjustment ?? 0)
            let rhsScore = Double(rhs.cosineSimilarity) + Double(rhs.feedbackAdjustment ?? 0)
            return lhsScore > rhsScore
        }
        let topKUnsorted = Array(items.prefix(k))

        // Step 10: Mark low confidence (US-RET-006 AC-1)
        // alignmentScore < 0.6 → lowConfidence=true + fallbackReason
        // When alignmentScore is nil (Phase 2: Cross-Encoder not yet integrated), no marking occurs.
        let topK = markLowConfidence(topKUnsorted)

        // Step 11: Collect result languages for audit (US-RET-001 AC-4)
        let resultLanguages = Array(Set(topK.compactMap(\.sourceLanguage)))

        // Step 12: Audit log (US-RET-001 AC-4, US-RET-004 AC-5, US-RET-006 AC-5)
        // Best-effort only — audit failure is L1 transient and MUST NOT block
        // Encode queryLanguage + resultLanguages + low confidence metadata as JSON
        let auditLanguageInfo = encodeAuditMetadata(
            query: queryLanguage,
            results: resultLanguages,
            topK: topK
        )
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let filterApplied = filter?.isEmpty == false
        try? await privacyActor.writeAuditLog(
            eventType: .retrieval,
            traceID: traceID,
            policyVersion: checkpoint.policyVersion,
            success: true,
            sourceType: "search",
            affectedCount: topK.count,
            excludedWritten: filterApplied,
            sourceLanguage: auditLanguageInfo,
            elapsedMs: elapsedMs
        )

        // Step 13: Follow-up audit (US-RET-005 AC-4) — best-effort
        // PR#58 CR-4: 审计 traceID 为本轮 traceID（§7.2 同一 Trace ID），父轮次经 sourceLanguage payload 携带。
        if isFollowUp, let parentTrace {
            let followUpInfo = encodeFollowUpMetadata(parentTraceID: parentTrace, query: trimmed)
            try? await privacyActor.writeAuditLog(
                eventType: .followUpQuery,
                traceID: traceID,
                policyVersion: checkpoint.policyVersion,
                success: true,
                sourceType: "search",
                affectedCount: topK.count,
                sourceLanguage: followUpInfo
            )
        }

        return topK
    }

    // MARK: - Private Helpers

    /// 将查询向量对齐到目标 store 维度（不足补零、超出截断）。
    ///
    /// 3F.11 fix: 生产分代 store 为原生维度（text_dense=384d / vision_dense=768d），
    /// 查询向量必须与 store 维度一致，否则 HNSW 维度不匹配、搜索返回空。
    /// Phase 2 legacy 512d store 经补零保持兼容。
    nonisolated static func alignVector(_ vector: [Float], to dimension: Int) -> [Float] {
        guard vector.count != dimension else { return vector }
        if vector.count < dimension {
            return vector + Array(repeating: 0.0, count: dimension - vector.count)
        }
        return Array(vector.prefix(dimension))
    }

    /// 检测文本语言（US-RET-003 AC-1）。
    ///
    /// 委托共享实现 `GenerationRoutedChannelAdapter.detectLanguage`（PR#58 CR-30 单一来源防漂移）。
    ///
    /// - Parameter text: 待检测文本
    /// - Returns: "zh-Hans"、"en-US" 或 "mixed"
    private nonisolated func detectLanguage(from text: String?) -> String? {
        GenerationRoutedChannelAdapter.detectLanguage(from: text)
    }

    /// 判断是否为跨语言匹配（US-RET-001 AC-3, US-RET-002）。
    ///
    /// 当查询语言与记忆源语言不同且两者均可识别时，标记为跨语言匹配。
    private nonisolated func isCrossLanguage(queryLang: String?, sourceLang: String?) -> Bool {
        guard let ql = queryLang, let sl = sourceLang else { return false }
        // "mixed" query matches anything → not strictly cross-language
        guard ql != "mixed", sl != "mixed" else { return false }
        return ql != sl
    }

    /// 编码查询语言 + 结果语言 + 低置信度元数据为 JSON（用于审计日志 sourceLanguage 字段）。
    ///
    /// 格式:
    /// ```json
    /// {
    ///   "queryLanguage": "en-US",
    ///   "resultLanguages": ["zh-Hans"],
    ///   "lowConfidenceCount": 3,
    ///   "alignmentScores": [0.82, null, 0.45]
    /// }
    /// ```
    ///
    /// US-RET-006 AC-5: 审计记录 alignmentScore、fallbackReason。
    private nonisolated func encodeAuditMetadata(
        query: String?,
        results: [String],
        topK: [SearchResultItem]
    ) -> String {
        var dict: [String: Any] = [:]
        if let q = query { dict["queryLanguage"] = q }
        dict["resultLanguages"] = results
        dict["lowConfidenceCount"] = topK.filter(\.lowConfidence).count
        dict["alignmentScores"] = topK.map { $0.alignmentScore as Any? ?? NSNull() }
        dict["fallbackReasons"] = topK.compactMap { $0.fallbackReason }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            return query ?? results.joined(separator: ",")
        }
        return json
    }

    /// 编码跟进查询审计元数据（US-RET-005 AC-4，写入 sourceLanguage 字段）。
    ///
    /// 格式:
    /// ```json
    /// { "parentTraceId": "<父轮次 traceID>", "rewrittenQuery": "<query SHA-256>" }
    /// ```
    /// approach a 无 LLM rewrite — rewrittenQuery 存查询 SHA-256 摘要（AGENTS.md §5.4
    /// 仅记录哈希摘要禁止原文，PR#58 CR-5），审计行不含用户查询原文。
    private nonisolated func encodeFollowUpMetadata(parentTraceID: String, query: String) -> String {
        let queryDigest = AuditContentHasher.sha256Hex(query)
        let dict: [String: Any] = ["parentTraceId": parentTraceID, "rewrittenQuery": queryDigest]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"parentTraceId\":\"\(parentTraceID)\"}"
        }
        return json
    }

    /// 标记低置信度结果（US-RET-006 AC-1）。
    ///
    /// 规则: `alignmentScore < 0.6` → `lowConfidence=true` + `fallbackReason`
    /// 当 `alignmentScore` 为 nil（Phase 2: Cross-Encoder 未集成）→ 不标记。
    /// 结果不被过滤（AC-3: 仍返回全部 top-K）。
    ///
    /// AC-2: UI 显示统一提示文案 "以下结果相关性较低，建议优化关键词或尝试不同表述。"（本地化 zh-Hans/en-US）
    /// AC-4: UI 提供"不准确"反馈按钮（仅本地学习）
    /// 以上两条为展示层实现（Phase 3 SearchViewModel/SearchView），
    /// Pipeline 通过 `lowConfidence=true` + `fallbackReason` 提供标记数据。
    private nonisolated func markLowConfidence(_ items: [SearchResultItem]) -> [SearchResultItem] {
        return items.map { item in
            if let score = item.alignmentScore, score < 0.6 {
                return SearchResultItem(
                    id: item.id,
                    assetId: item.assetId,
                    sourceType: item.sourceType,
                    timestamp: item.timestamp,
                    originalText: item.originalText,
                    sourceLanguage: item.sourceLanguage,
                    crossLanguageMatch: item.crossLanguageMatch,
                    cosineSimilarity: item.cosineSimilarity,
                    alignmentScore: item.alignmentScore,
                    feedbackAdjustment: item.feedbackAdjustment,
                    lowConfidence: true,
                    fallbackReason: "cross-encoder alignment score \(String(format: "%.3f", score)) below threshold 0.6",
                    unappliedFilters: item.unappliedFilters
                )
            }
            return item
        }
    }

    /// 应用元数据过滤器（US-RET-004 AC-1），返回过滤结果与未生效过滤器列表（R-1.7）。
    ///
    /// **重要**: 当前实现为 ANN 后过滤（post-filter），非规格书中的 FTS5 预过滤。
    /// 流程: ANN 检索 → 解码元数据 → 应用过滤条件 → 取 top-K。
    ///
    /// - Returns: `(filtered, unapplied)` — `unapplied` 列出调用方传入但当前实现
    ///   为 no-op 的过滤维度（如 tags/geoRadius），让调用方得知过滤未生效。
    private nonisolated func applyFilter(
        _ items: [SearchResultItem],
        filter: SearchFilter
    ) -> (filtered: [SearchResultItem], unapplied: [String]) {
        var filtered = items
        var unapplied: [String] = []

        // Time range filter (US-RET-004 AC-1)
        if let timeRange = filter.timeRange {
            filtered = filtered.filter { item in
                timeRange.contains(Date(timeIntervalSince1970: item.timestamp))
            }
        }

        // Tags filter — NOT YET IMPLEMENTED (R-1.7: 显式标记未生效)
        if filter.tags != nil {
            unapplied.append("tags")
        }

        // Geo filter — NOT YET IMPLEMENTED (R-1.7)
        if filter.geoRadius != nil {
            unapplied.append("geoRadius")
        }

        return (filtered, unapplied)
    }

    /// 带超时的异步操作封装（US-RET-008 AC-1）。
    ///
    /// 使用 withThrowingTaskGroup 实现竞速模式：
    /// - 操作先完成 → 返回结果，取消超时任务，消费取消错误
    /// - 超时先触发 → 抛出 SearchError.searchTimeout
    ///
    /// ⚠️ Swift 6 注意: Task.sleep 被 cancel 后抛出 CancellationError，
    /// withThrowingTaskGroup 会隐式等待所有子任务并重新抛出。因此必须
    /// 显式消费被取消任务的错误，避免覆盖正常结果。
    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SearchError.searchTimeout(partialResults: [])
            }
            // Wait for whichever task completes first
            guard let result = try await group.next() else {
                throw SearchError.searchTimeout(partialResults: [])
            }
            // Cancel the remaining task
            group.cancelAll()
            // Explicitly consume the cancelled task's error — do NOT let
            // group's implicit wait re-throw the CancellationError.
            do { _ = try await group.next() } catch { /* cancelled, expected */ }
            return result
        }
    }

    // MARK: - R-3.7: RRF Multi-Channel Fusion

    /// 单通道搜索结果（RRF 融合输入）。
    struct ChannelResult: Sendable {
        let channel: String
        let rankedIds: [UUID]
    }

    /// 加权 RRF 融合（R-3.7）。
    ///
    /// 公式：`score(d) = Σ w_i / (k_rrf + rank_i(d))`
    /// - 每通道输出独立 rank（不把原始余弦/BM25/规则分直接相加）
    /// - 权重可配置（channelWeights）
    /// - 超时通道被跳过（降级不影响其他通道）
    ///
    /// - Parameters:
    ///   - channelResults: 各通道的排序结果
    ///   - k: 返回 top-K 结果数
    /// - Returns: 融合后的文档 ID 列表（按 RRF 分数降序）
    nonisolated func rrfFuse(
        channelResults: [ChannelResult],
        k: Int
    ) -> [UUID] {
        var scores: [UUID: Double] = [:]

        for result in channelResults {
            let weight = Self.channelWeights[result.channel] ?? 1.0
            for (rank, docId) in result.rankedIds.enumerated() {
                let rrfScore = weight / (Self.rrfK + Double(rank + 1))
                scores[docId, default: 0] += rrfScore
            }
        }

        return scores
            .sorted {
                // 确定性 tie-break（§4.1 纯函数契约，PR#58 CR-15）：同分按 ID 升序，避免 Dictionary 迭代序抖动
                $0.value == $1.value ? $0.key.uuidString < $1.key.uuidString : $0.value > $1.value
            }
            .prefix(k)
            .map(\.key)
    }

    /// 生产多通道检索（R-3.7 / DEF-34-001，3F.6）— 顺序执行各通道适配器，RRF 融合。
    ///
    /// ## 通道契约（US-RET-008 / DEF-34-002）
    /// - 每个适配器内部完成 PrivacyCheckpoint（R-006）、路由解析、超时降级 —
    ///   适配器绝不 throw 阻断融合（错误经 timedOut / error 字段携带）
    /// - timedOut / error 通道被跳过（部分结果与 L3 错误均不参与融合，不影响其他通道）
    ///
    /// ## 元数据组装（DEF-34-001）
    /// 融合结果经通道 ID-keyed 元数据映射组装 SearchResultItem — 禁止 top-1 re-search。
    ///
    /// - Parameters:
    ///   - adapters: 参与融合的通道适配器（text_dense/vision_dense/ocr_text/lexical）
    ///   - queryVector: 查询向量（稠密通道使用；nil 时适配器按通道维度零向量处理）
    ///   - queryText: 查询原文（词法通道使用）
    ///   - k: 融合后返回 top-K 结果数
    /// - Returns: 按 RRF 分数降序的 SearchResultItem 列表（ID-keyed 元数据组装）
    func searchMultiChannel(
        adapters: [any SearchChannelAdapter],
        queryVector: [Float]?,
        queryText: String,
        k: Int
    ) async -> [SearchResultItem] {
        var channelResults: [ChannelResult] = []
        var metadataByID: [UUID: SearchChannelMetadata] = [:]

        // 各通道顺序执行（每个适配器内部自带超时降级，绝不 throw 阻断融合；PR#58 CR-34 移除 throws）。
        // 未来可迁移到 withThrowingTaskGroup 并行；当前逐通道执行保证串行确定性。
        for adapter in adapters {
            guard let result = try? await adapter.search(
                queryVector: queryVector,
                queryText: queryText,
                k: k
            ) else { continue }
            // 降级通道（timedOut / L3 error）被跳过 — 不影响其他通道结果（US-RET-008 AC-3）
            if result.timedOut || result.error != nil { continue }
            channelResults.append(ChannelResult(channel: result.channel.rawValue, rankedIds: result.rankedIds))
            for (id, meta) in result.metadataByID {
                // PR#58 CR-35: 同一 ID 多通道命中保留 cosineSimilarity 更高者，避免依赖适配器数组顺序
                if let existing = metadataByID[id] {
                    if meta.cosineSimilarity > existing.cosineSimilarity { metadataByID[id] = meta }
                } else {
                    metadataByID[id] = meta
                }
            }
        }

        // RRF 融合（加权，超时/错误通道已剔除）
        let fusedIds = rrfFuse(channelResults: channelResults, k: k)

        // DEF-34-001: 元数据来自融合 ID 的 ID-keyed 映射 — 禁止 top-1 re-search
        var items: [SearchResultItem] = []
        for id in fusedIds {
            guard let meta = metadataByID[id] else { continue }
            items.append(SearchResultItem(
                id: id,
                assetId: meta.assetId,
                sourceType: meta.sourceType,
                timestamp: meta.timestamp,
                originalText: meta.originalText,
                sourceLanguage: meta.sourceLanguage,
                cosineSimilarity: meta.cosineSimilarity
            ))
        }
        return items
    }

    // MARK: - WP4: Factory 驱动的类型化多通道编排

    /// WP4 产出接口——每通道原生载荷（禁共享向量）、canonical 映射先于 RRF、
    /// 歧义 fail-closed 排除、timedOut 部分结果保留、全通道 provenance 聚合与 hydration。
    /// 全依赖注入的静态纯编排：composition 层决定何时以生产工厂激活。
    nonisolated static func searchMultiChannelTyped(
        factory: any QueryRepresentationFactory,
        route: SearchRouteSnapshot,
        adapters: [any NativeSearchChannel],
        repo: CanonicalMemoryRepositoryActor,
        query: String,
        locale: String,
        k: Int,
        traceID: String,
        weights: [SearchChannel: Double] = [:],
        rrfK: Double = 60
    ) async -> [FusedSearchResult] {
        // Step 1: 每通道原生载荷生成（部分失败隔离由 factory 内部保证）
        let outcome = await factory.makeQuery(text: query, locale: locale, route: route, traceID: traceID)

        // Step 2: 逐通道执行类型化检索；无原生载荷的通道直接跳过（绝不降级到共享向量）
        var rawHits: [RawChannelHit] = []
        for adapter in adapters {
            guard let payload = outcome.query.payloads[adapter.channel] else { continue }
            let limit = max(k * 3, 30)
            let channelOutcome = await adapter.search(
                payload: payload, route: route, limit: limit, traceID: traceID
            )
            switch channelOutcome {
            case .success(_, let hits, _):
                rawHits.append(contentsOf: hits)
            case .timedOut(_, let partialHits, _):
                rawHits.append(contentsOf: partialHits)
            case .empty, .skipped, .failed:
                continue
            }
        }
        guard !rawHits.isEmpty else { return [] }

        // Step 3: canonical 映射先于 RRF——dense 命中按 generation 分组批量映射；
        // 词法命中 vectorID 即 memoryID，经 loadRepresentations 构造合法绑定（无表示则 fail-closed 跳过）。
        var bindingsByID: [UUID: CanonicalVectorBinding] = [:]
        var byGeneration: [String: [UUID]] = [:]
        var lexicalMemIDs: [UUID] = []
        for hit in rawHits {
            if hit.generationID.hasPrefix("lexical/") {
                if !lexicalMemIDs.contains(hit.vectorID) { lexicalMemIDs.append(hit.vectorID) }
            } else {
                byGeneration[hit.generationID, default: []].append(hit.vectorID)
            }
        }
        for (gen, ids) in byGeneration {
            let map = (try? await repo.mapVectorIDs(ids, generationID: gen)) ?? [:]
            for (id, res) in map {
                if case .mapped(let binding) = res { bindingsByID[id] = binding }
            }
        }
        for memID in lexicalMemIDs {
            let reps = (try? await repo.loadRepresentations(memoryId: memID)) ?? []
            guard let rep = reps.first else { continue }
            bindingsByID[memID] = CanonicalVectorBinding(
                vectorID: memID,
                representationID: rep.representationId,
                memoryID: memID,
                modality: rep.modality,
                generationID: rawHits.first { $0.vectorID == memID && $0.generationID.hasPrefix("lexical/") }?.generationID ?? ""
            )
        }

        let mappedHits: [CanonicalMappedHit] = rawHits.compactMap { hit in
            guard let binding = bindingsByID[hit.vectorID] else { return nil }
            return CanonicalMappedHit(binding: binding, hit: hit)
        }
        guard !mappedHits.isEmpty else { return [] }

        // Step 4: canonical RRF 融合（歧义排除 + 确定性 tie-break + provenance 聚合）
        let fused = DefaultCanonicalRRFFuser().fuse(
            mappedHits: mappedHits, weights: weights, rrfK: rrfK,
            limit: k, routeSnapshotID: route.snapshotID
        )

        // Step 5: hydration——按融合结果取回 Memory 组装
        var results: [FusedSearchResult] = []
        for entry in fused {
            guard let memory = try? await repo.loadMemory(memoryId: entry.memoryID) else { continue }
            results.append(FusedSearchResult(
                memory: memory,
                rrfScore: entry.score,
                provenance: entry.provenance,
                routeSnapshotID: route.snapshotID
            ))
        }
        return results
    }

    // MARK: - WP4 尾刀：生产多通道入口（queryFactory 消费点）

    /// 工厂驱动的生产检索错误（独立于 SearchError，避免扰动其穷尽 switch）。
    enum TypedSearchError: Error, LocalizedError {
        case featureDisabled
        case dependenciesMissing
        case routeUnavailable

        public var errorDescription: String? {
            switch self {
            case .featureDisabled: return "Typed multi-channel search is feature-disabled (queryFactory not injected)"
            case .dependenciesMissing: return "Typed multi-channel search requires generationRegistry and canonicalRepository"
            case .routeUnavailable: return "No active route published in GenerationRegistry"
            }
        }
    }

    /// 生产多通道检索入口——消费注入的 queryFactory，按活跃路由切换到类型化编排。
    ///
    /// - route/adapters 缺省时内部从 GenerationRegistry 活跃路由桥接构造；
    ///   测试与特殊调用方可显式注入以绕过真实向量存储。
    /// - 权重沿用 legacy channelWeights 数值（text 1.0 / vision 0.8 / ocr 0.6 / lexical 0.5）。
    public func searchTyped(
        query: String,
        locale: String? = nil,
        k: Int = 10,
        traceID: String = UUID().uuidString,
        route: SearchRouteSnapshot? = nil,
        adapters: [any NativeSearchChannel]? = nil,
        weights: [SearchChannel: Double] = [
            .textDense: 1.0, .visionDense: 0.8, .ocrText: 0.6, .lexical: 0.5,
        ]
    ) async throws -> [FusedSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SearchError.emptyQuery }

        // 功能开关为最外层闸门：未注入工厂时不产生隐私检查开销
        guard queryFactory != nil else { throw TypedSearchError.featureDisabled }
        let resolvedLocale = locale ?? (detectLanguage(from: trimmed) ?? "en-US")

        // R-006 与 legacy 路径同规
        let checkpoint = await privacyActor.validate(
            operation: .search,
            traceID: traceID,
            sourceTypes: ["search"]
        )
        guard checkpoint.isAllowed else {
            throw SearchError.privacyDenied(sourceTypes: checkpoint.sourceTypes)
        }
        guard let factory = queryFactory, let registry = generationRegistry, let repo = canonicalRepository else {
            throw TypedSearchError.dependenciesMissing
        }

        let resolvedRoute: SearchRouteSnapshot
        if let route {
            resolvedRoute = route
        } else {
            guard let activeSet = try await registry.loadActiveRoute() else {
                throw TypedSearchError.routeUnavailable
            }
            resolvedRoute = try await Self.bridgeRouteSnapshot(from: activeSet, registry: registry)
        }

        let resolvedAdapters: [any NativeSearchChannel]
        if let adapters {
            resolvedAdapters = adapters
        } else {
            resolvedAdapters = try Self.makeDefaultAdapters(route: resolvedRoute, registry: registry, repo: repo)
        }

        return await Self.searchMultiChannelTyped(
            factory: factory,
            route: resolvedRoute,
            adapters: resolvedAdapters,
            repo: repo,
            query: trimmed,
            locale: resolvedLocale,
            k: k,
            traceID: traceID,
            weights: weights
        )
    }

    /// ActiveRouteSet → SearchRouteSnapshot 桥接：逐通道经 loadGeneration 解析原生维度。
    nonisolated private static func bridgeRouteSnapshot(
        from activeSet: ActiveRouteSet,
        registry: GenerationRegistryActor
    ) async throws -> SearchRouteSnapshot {
        struct Pending {
            let channel: SearchChannel
            let generationID: String
        }
        var pending: [Pending] = [Pending(channel: .textDense, generationID: activeSet.textGeneration)]
        if let v = activeSet.visionGeneration { pending.append(Pending(channel: .visionDense, generationID: v)) }
        if let o = activeSet.ocrGeneration { pending.append(Pending(channel: .ocrText, generationID: o)) }
        if let l = activeSet.lexicalGeneration { pending.append(Pending(channel: .lexical, generationID: l)) }

        var routes: [ChannelRoute] = []
        for item in pending {
            let dim = try await registry.loadGeneration(item.generationID)?.dimension
            routes.append(ChannelRoute(
                channel: item.channel,
                generationID: item.generationID,
                indexManifestID: nil,
                queryModelManifestID: nil,
                dimension: dim,
                alignmentSpaceID: nil,
                required: true
            ))
        }

        let weightMap: [String: Double] = [
            "text_dense": 1.0, "vision_dense": 0.8, "ocr_text": 0.6, "lexical": 0.5,
        ]
        let fusion = try FusionPolicySnapshot(
            policyID: "active-route-bridge",
            weights: routes.compactMap { cr in
                weightMap[cr.channel.rawValue].map { ChannelWeight(channel: cr.channel, weight: $0) }
            },
            rrfK: Self.rrfK
        )
        return try SearchRouteSnapshot(
            snapshotID: "active-v\(activeSet.version)-\(activeSet.textGeneration)",
            schemaVersion: 1,
            routeVersion: activeSet.version,
            channels: routes,
            fusion: fusion,
            previousSnapshotID: nil,
            publishedAtEpochMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
            validationDigest: "legacy-bridge-unvalidated"
        )
    }

    /// 按路由快照构造默认类型化适配器集合；词法通道绑定 canonical FTS 回调。
    nonisolated private static func makeDefaultAdapters(
        route: SearchRouteSnapshot,
        registry: GenerationRegistryActor,
        repo: CanonicalMemoryRepositoryActor
    ) throws -> [any NativeSearchChannel] {
        try route.channels.map { cr in
            try PayloadTypedChannelAdapter(
                generationRegistry: registry,
                channel: cr.channel,
                dimension: cr.dimension ?? 0,
                alignmentSpaceID: cr.alignmentSpaceID,
                lexicalSearch: { text, limit in
                    (try? await repo.searchCanonical(matching: text, limit: limit)) ?? []
                }
            )
        }
    }

    // MARK: - Source Type Normalization

    /// 将记忆细粒度 sourceType 归一化为授权词汇表的数据源类型（P1）。
    ///
    /// 记忆 sourceType 是细粒度：`video_frame`/`video_audio`/`text`；
    /// 授权词汇表是粗粒度数据源：`photo`/`note`/`voice`/`video`/`calendar`。
    /// 直接比较会导致已授权数据源的记忆被误过滤。
    static nonisolated func normalizeSourceType(_ sourceType: String) -> String {
        switch sourceType {
        case "video_frame", "video_audio": return "video"
        case "text": return "note"
        default: return sourceType
        }
    }
}
