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
// 架构约束: AGENTS.md §4.1 (Pipeline 契约 — 纯函数、无状态、审计强制、错误分级),
//           AGENTS.md §5.3 (反馈存储契约),
//           R-006 (PrivacyCheckpoint 强制注入), R-008 (跨 Actor await),
//           AGENTS.md §4.4 (L1~L4 统一错误分级),
//           PIPE-002 (翻译仅限展示层, Retriever 返回源语言原文)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-12
// ==========================================

import Foundation
import NaturalLanguage
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
/// 支持时间范围、标签、地理半径、人物 ID 过滤。
/// 所有字段可选 — nil 表示不过滤该维度。
public struct SearchFilter: Sendable, Equatable {
    /// 时间范围过滤（闭区间）
    public nonisolated let timeRange: ClosedRange<Date>?
    /// 标签关键词匹配
    public nonisolated let tags: [String]?
    /// 地理半径过滤
    public nonisolated let geoRadius: GeoFilter?
    /// 人物 ID 列表（US-SRC-006）
    public nonisolated let personIds: [String]?

    public nonisolated init(
        timeRange: ClosedRange<Date>? = nil,
        tags: [String]? = nil,
        geoRadius: GeoFilter? = nil,
        personIds: [String]? = nil
    ) {
        self.timeRange = timeRange
        self.tags = tags
        self.geoRadius = geoRadius
        self.personIds = personIds
    }

    /// 是否有任何活跃的过滤维度
    public nonisolated var isEmpty: Bool {
        timeRange == nil && tags == nil && geoRadius == nil && personIds == nil
    }

    /// 活跃的过滤维度名称列表（用于审计）
    public nonisolated var activeDimensions: [String] {
        var dims: [String] = []
        if timeRange != nil { dims.append("time") }
        if tags != nil { dims.append("tags") }
        if geoRadius != nil { dims.append("geo") }
        if personIds != nil { dims.append("person") }
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
    /// 未生效的过滤器（R-1.7）— 调用方传入但当前实现为 no-op 的过滤维度（如 tags/geoRadius/personIds）
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
///     → post-filter metadata (time/tags/geo/person)
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

    // MARK: - Configuration

    /// ANN 检索候选集大小（供后续精排/过滤使用）
    private nonisolated let annCandidateCount: Int = 100

    /// 搜索超时阈值（秒，US-RET-008）
    private nonisolated let searchTimeoutSeconds: Double = 2.0

    /// 语言检测置信度阈值（低于此值标记为 mixed）
    private nonisolated let languageConfidenceThreshold: Float = 0.9

    // MARK: - Initialization

    public init(
        embedder: any EmbedderProtocol,
        privacyActor: PrivacyActor = .shared,
        vectorStore: VectorStoreActor,
        feedbackActor: FeedbackActor = .shared
    ) {
        self.embedder = embedder
        self.privacyActor = privacyActor
        self.vectorStore = vectorStore
        self.feedbackActor = feedbackActor
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

        // Step 2: PrivacyCheckpoint (R-006)
        let checkpoint = await privacyActor.validate(
            operation: .search,
            traceID: traceID,
            sourceTypes: ["search"]
        )
        guard checkpoint.isAllowed else {
            throw SearchError.privacyDenied(sourceTypes: checkpoint.sourceTypes)
        }

        // Step 3: Generate query embedding (multilingual-e5-small → 384d)
        let rawEmbedding: [Float]
        do {
            rawEmbedding = try await embedder.embedText(query)
        } catch {
            throw SearchError.embeddingFailed(underlying: error)
        }

        // Zero-pad 384d → 512d for unified VectorStore (Strategy A)
        let queryVector: [Float]
        if rawEmbedding.count < 512 {
            queryVector = rawEmbedding + Array(repeating: 0.0, count: 512 - rawEmbedding.count)
        } else {
            queryVector = rawEmbedding
        }

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
        let policy = await privacyActor.getPolicy()
        items = items.filter { policy.isAuthorized(sourceType: $0.sourceType) }

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

        return topK
    }

    // MARK: - Private Helpers

    /// 检测文本语言（US-RET-003 AC-1）。
    ///
    /// 使用 NLTagger（iOS 18+），置信度 < 0.9 标记为 "mixed"。
    /// 繁体/方言映射为 "zh-Hans"（AGENTS.md §6.1）。
    ///
    /// - Parameter text: 待检测文本
    /// - Returns: "zh-Hans"、"en-US" 或 "mixed"
    private nonisolated func detectLanguage(from text: String?) -> String? {
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

        // Get the highest-confidence language hypothesis
        guard let (rawLanguage, confidence) = hypotheses.first,
              confidence >= Double(languageConfidenceThreshold) else {
            return "mixed"
        }

        // Map to supported languages (AGENTS.md §6.1)
        switch rawLanguage {
        case "en":
            return "en-US"
        case "zh-Hant", "zh-HK", "zh-TW", "yue", "zh":
            return "zh-Hans"
        case "zh-Hans":
            return "zh-Hans"
        default:
            return "mixed"
        }
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
    ///   为 no-op 的过滤维度（如 tags/geoRadius/personIds），让调用方得知过滤未生效。
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

        // Person filter — NOT YET IMPLEMENTED (R-1.7)
        if filter.personIds != nil {
            unapplied.append("personIds")
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
}
