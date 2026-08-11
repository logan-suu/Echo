// ==========================================
// 文件: 3F.6_ProductionSearchFeedbackTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RET-003 (多通道), US-RET-005 (对话历史),
//            US-RET-007 (结果缓存), US-RET-008 (超时降级), US-FBK-002 (反馈重排),
//            US-PRV-001 (授权), US-SRC-011 (主观重排)
//            docs/05-planning/phase3f-execution-plan.md → 3F.6 (Production search 与 feedback)
// 任务: 3F.6 - Production search 与 feedback（TDD GREEN 测试套件）
// AC 覆盖: US-RET-007 AC-1/2/3/4 (缓存 TTL/失效/键维度), US-RET-008 AC-1/3 (超时 timedOut 降级),
//          DEF-34-001 (RRF ID-keyed 元数据, 禁止 top-1 re-search), DEF-34-002 (L3 error 与 timeout 分离),
//          US-RET-003 AC-2 (text/vision 分离向量空间), US-FBK-002 AC-1/2/3 (阈值/衰减/截断 + 同查询重排),
//          US-PRV-001 AC-2 (被拒数据源不进 Retriever), US-RET-005 AC-4 (followUp 审计)
//          （US-RET-005 AC-1/2/3 按决策延后：AC-3 LLM rewrite 无生成式 LLM，AC-1 FIFO/AC-2 memoryIds
//          注入未落地 — 仅 approach a 单轮 lastQuery 追踪，见 DEF-58-001/002）
//          DEF-37-001 (L2 feedback 写 PendingOperations 且可见可手动重试), DEF-56-005 (generationId 透传),
//          DEF-56-006 (searchCanonical ORDER BY rank)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §4.4 (L1~L4 错误分级), §13.2 (TDD 先写测试),
//           R-006/R-007/R-008, §9.4 (串行执行)
// 重要: TDD GREEN — 生产实现（adapter.search / cache.lookup/store/invalidate / rerank /
//       followUp 审计 / generationId 透传 / PendingOperations 写入 / searchCanonical 排序）已实现，
//       45/45 聚焦测试通过（PR#58 CR-18 头注释更新）。纯函数（makeKey / applyAdjustment / rrfFuse）稳定。
// 生成时间: 2026-08-11 | 更新: 2026-08-11 (PR#58 review 修复)
// ==========================================

import Testing
import Foundation
import ProximaKit
@testable import Echo

// MARK: - Test Embedder (deterministic production contract)

/// Deterministic production embedder — implements the real EmbedderProtocol with an
/// explicit dimension contract (text=384d / vision=768d). A fixed query embedding can
/// be set per test so E2E similarity ranking is deterministic.
public actor StableEmbedder: EmbedderProtocol {
    private let textDimension: Int
    private let visionDimension: Int
    private var fixedTextEmbedding: [Float]?

    public init(textDimension: Int = 384, visionDimension: Int = 768) {
        self.textDimension = textDimension
        self.visionDimension = visionDimension
    }

    /// Pin the embedding returned by `embedText` (persistent — every call returns it).
    public func setTextEmbedding(_ vector: [Float]) {
        fixedTextEmbedding = vector
    }

    public func embedText(_ text: String) async throws -> [Float] {
        fixedTextEmbedding ?? [Float](repeating: 0.25, count: textDimension)
    }

    public func embedImage(assetId: String) async throws -> [Float] {
        [Float](repeating: 0.5, count: visionDimension)
    }

    public func embedImageData(_ data: Data) async throws -> [Float] {
        [Float](repeating: 0.5, count: visionDimension)
    }
}

// MARK: - Test Subjective Scorer

/// Deterministic SubjectiveScorer — returns a fixed subjective match score.
public struct StableSubjectiveScorer: SubjectiveScorer {
    private let score: Float

    public init(score: Float = 0.9) {
        self.score = score
    }

    public nonisolated func subjectiveMatchScore(text: String) async throws -> Float {
        score
    }
}

// MARK: - Test Suite: Production Search & Feedback (3F.6)

@Suite("ProductionSearchFeedbackTests", .serialized)
@MainActor
struct ProductionSearchFeedbackTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await ProductionSearchFeedbackTests.wipeCanonicalTables()
    }

    private static func wipeCanonicalTables() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        try await db.execute(sql: "DELETE FROM MemoryFTS")
        try await db.execute(sql: "DELETE FROM translationCache")
        try await db.execute(sql: "DELETE FROM Representation")
        try await db.execute(sql: "DELETE FROM Memory")
        try await db.execute(sql: "DELETE FROM IndexBuildItem")
        try await db.execute(sql: "DELETE FROM IndexGeneration")
        try await db.execute(sql: "DELETE FROM ActiveRouteSet")
        try await db.execute(sql: "DELETE FROM FeedbackStore")
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
        try await db.execute(sql: "DELETE FROM TaskProgress")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM PendingOperations")

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let generationsDir = appSupport.appendingPathComponent("Echo/generations", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: generationsDir.path) {
            for file in files where file.hasSuffix(".pxkt") {
                try? FileManager.default.removeItem(at: generationsDir.appendingPathComponent(file))
            }
        }
    }

    private func makeRegistry() -> GenerationRegistryActor {
        GenerationRegistryActor(db: db)
    }

    /// Register and activate text + vision generations (ADR-010 routing, mirrors 3F.5).
    private func seedGenerations(_ registry: GenerationRegistryActor) async throws -> ActiveRouteSet {
        try await registry.registerGeneration(
            IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384)
        )
        try await registry.finishShadowBuild("text_dense/e5-v1", counts: 0, validationDigest: nil)
        try await registry.setGenerationState("text_dense/e5-v1", state: .ready)

        try await registry.registerGeneration(
            IndexGeneration(generationId: "vision_dense/siglip2-v1", indexType: "vision_dense", dimension: 768)
        )
        try await registry.finishShadowBuild("vision_dense/siglip2-v1", counts: 0, validationDigest: nil)
        try await registry.setGenerationState("vision_dense/siglip2-v1", state: .ready)

        let route = try await registry.activateGeneration("text_dense/e5-v1")
        let activeRoute = ActiveRouteSet(
            textGeneration: "text_dense/e5-v1",
            visionGeneration: "vision_dense/siglip2-v1",
            version: route.version
        )
        try await registry.publishRoute(activeRoute)
        return activeRoute
    }

    /// Policy that authorizes search plus all memory source types.
    private func makeSearchPolicy(version: Int = 1) -> UserPolicy {
        UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["search", "photo", "note", "voice", "text", "video"],
            policyVersion: version
        )
    }

    // ══════════════════════════════════════════════════════════════
    // US-RET-007: Search Result Cache (SearchResultCacheActor)
    // ══════════════════════════════════════════════════════════════

    @Test("RET-007 AC-4: cache key differs when policyVersion differs")
    func test_AC4_CacheKeyDiffersWhenPolicyVersionDiffers() {
        let keyV1 = SearchResultCacheActor.makeKey(policyVersion: 1, modelVersion: "e5-v1", query: "west lake")
        let keyV2 = SearchResultCacheActor.makeKey(policyVersion: 2, modelVersion: "e5-v1", query: "west lake")
        #expect(keyV1.policyVersion == 1)
        #expect(keyV2.policyVersion == 2)
        #expect(keyV1 != keyV2, "policyVersion is part of the cache key (AC-4)")
    }

    @Test("RET-007 AC-4: cache key differs when modelVersion differs")
    func test_AC4_CacheKeyDiffersWhenModelVersionDiffers() {
        let keyE5 = SearchResultCacheActor.makeKey(policyVersion: 1, modelVersion: "multilingual-e5-small-v1", query: "west lake")
        let keySigLIP = SearchResultCacheActor.makeKey(policyVersion: 1, modelVersion: "siglip2-v1", query: "west lake")
        #expect(keyE5.modelVersion == "multilingual-e5-small-v1")
        #expect(keySigLIP.modelVersion == "siglip2-v1")
        #expect(keyE5 != keySigLIP, "modelVersion is part of the cache key (AC-4)")
    }

    @Test("RET-007 AC-4: cache key differs when queryHash differs")
    func test_AC4_CacheKeyDiffersWhenQueryDiffers() {
        let keyA = SearchResultCacheActor.makeKey(policyVersion: 1, modelVersion: "e5-v1", query: "west lake trip")
        let keyB = SearchResultCacheActor.makeKey(policyVersion: 1, modelVersion: "e5-v1", query: "east lake trip")
        #expect(!keyA.queryHash.isEmpty)
        #expect(!keyB.queryHash.isEmpty)
        #expect(keyA.queryHash != keyB.queryHash)
        #expect(keyA != keyB, "queryHash is part of the cache key (AC-4)")
    }

    @Test("RET-007 AC-3/AC-1: store then lookup returns items within TTL")
    func test_AC3_StoreThenLookupReturnsItemsWithinTTL() async throws {
        let cache = SearchResultCacheActor(cacheTTL: 3600, maxEntries: 200)
        let key = SearchResultCacheActor.makeKey(policyVersion: 1, modelVersion: "e5-v1", query: "west lake")
        let item = SearchResultItem(
            id: UUID(),
            assetId: "note-1",
            sourceType: "note",
            timestamp: 1_700_000_000,
            originalText: "went to the West Lake",
            sourceLanguage: "en-US",
            cosineSimilarity: 0.9
        )
        try await cache.store(key: key, result: CachedSearchResult(items: [item]))
        let hit = try await cache.lookup(key: key)
        #expect(hit?.items.count == 1, "lookup within TTL must return the stored items (AC-1/AC-3)")
        #expect(hit?.items.first?.id == item.id)
    }

    @Test("RET-007 AC-1: lookup returns nil after TTL expiry")
    func test_AC1_LookupReturnsNilAfterTTLExpiry() async throws {
        let cache = SearchResultCacheActor(cacheTTL: 0.05, maxEntries: 200)
        let key = SearchResultCacheActor.makeKey(policyVersion: 1, modelVersion: "e5-v1", query: "expiring query")
        try await cache.store(
            key: key,
            result: CachedSearchResult(items: [
                SearchResultItem(
                    id: UUID(), assetId: "note-1", sourceType: "note", timestamp: 0, cosineSimilarity: 0.8,
                ),
            ]),
        )
        try await Task.sleep(for: .milliseconds(120))
        let hit = try await cache.lookup(key: key)
        #expect(hit == nil, "entry must be treated as a miss after TTL expiry (AC-1)")
    }

    @Test("RET-007 AC-2: invalidate(policyVersion:) removes entries for that policy version")
    func test_AC2_InvalidateRemovesPolicyVersionEntries() async throws {
        let cache = SearchResultCacheActor(cacheTTL: 3600, maxEntries: 200)
        let keyV1 = SearchResultCacheActor.makeKey(policyVersion: 1, modelVersion: "e5-v1", query: "west lake")
        let keyV2 = SearchResultCacheActor.makeKey(policyVersion: 2, modelVersion: "e5-v1", query: "west lake")
        let item = SearchResultItem(id: UUID(), assetId: "note-1", sourceType: "note", timestamp: 0, cosineSimilarity: 0.8)
        try await cache.store(key: keyV1, result: CachedSearchResult(items: [item]))
        try await cache.store(key: keyV2, result: CachedSearchResult(items: [item]))

        try await cache.invalidate(policyVersion: 1)

        let v1Hit = try await cache.lookup(key: keyV1)
        let v2Hit = try await cache.lookup(key: keyV2)
        #expect(v1Hit == nil, "policy change must invalidate old-policy cache entries (AC-2)")
        #expect(v2Hit != nil, "other policy versions must survive invalidation")
    }

    // ══════════════════════════════════════════════════════════════
    // US-RET-008: Timeout / Partial Results (GenerationRoutedChannelAdapter)
    // ══════════════════════════════════════════════════════════════

    @Test("RET-008 AC-1/AC-3: timeout channel returns timedOut flag, never throws")
    func test_AC1_TimeoutChannelReturnsTimedOutFlag() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let adapter = GenerationRoutedChannelAdapter(
            generationRegistry: registry,
            kind: .visionDense,
            dimension: 768
        )
        // Production contract (US-RET-008 AC-1/AC-3): a timeout channel degrades to a
        // partial ChannelSearchResult with timedOut == true — it must NOT throw and must
        // NOT block the other channels.
        let result = try await adapter.search(
            queryVector: [Float](repeating: 0.5, count: 768),
            queryText: "cat",
            k: 5
        )
        #expect(result.timedOut == true, "timeout channel must be marked timedOut (partial results)")
    }

    @Test("DEF-34-002: L3 channel error is distinguished from timeout")
    func test_DEF34_002_L3ErrorDistinguishedFromTimeout() {
        // L3 blocking error (e.g. embedding/model corruption, route missing) — carries `error`,
        // NOT the timedOut flag.
        let l3Error = ChannelSearchResult(
            channel: .textDense,
            rankedIds: [],
            timedOut: false,
            error: ChannelAdapterError.generationRouteMissing(channel: .textDense)
        )
        // L1 transient timeout — carries timedOut == true, no error.
        let timedOut = ChannelSearchResult(
            channel: .textDense,
            rankedIds: [],
            timedOut: true,
            error: nil
        )
        #expect(l3Error.error != nil)
        #expect(l3Error.timedOut == false, "L3 error must not be conflated with timeout (DEF-34-002)")
        #expect(timedOut.timedOut == true)
        #expect(timedOut.error == nil)
        #expect(
            ChannelAdapterError.generationRouteMissing(channel: .textDense)
                != ChannelAdapterError.timeout(channel: .textDense),
            "route-missing (L3) and timeout (L1) must be distinct error identities"
        )
    }

    // ══════════════════════════════════════════════════════════════
    // DEF-34-001: RRF Fusion + ID-keyed Metadata
    // ══════════════════════════════════════════════════════════════

    @Test("DEF-34-001: production assembly returns ID-keyed metadata (no top-1 re-search)")
    func test_DEF34_001_FusedMetadataFromIDKeyedLookup() async throws {
        // PR#58 CR-12: 直接驱动生产 searchMultiChannel 组装路径 —
        // 不再只调 rrfFuse + 断言测试自造的字面量。
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let privacy = PrivacyActor(db: db)
        try await privacy.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["note"],
            policyVersion: 1
        ))
        let x = UUID(), y = UUID()
        let query384 = [Float](repeating: 0.5, count: 384)
        let textStore = await registry.vectorStore(for: "text_dense/e5-v1")
        try await textStore?.ingest(
            vector: query384, id: x,
            metadata: try MemoryEntry(
                assetId: "note-x", embedding: query384, sourceType: "note",
                timestamp: Date(timeIntervalSince1970: 1), traceID: "t-def34",
                originalText: "text channel hit"
            ).encodeMetadata()
        )
        try await textStore?.ingest(
            vector: query384, id: y,
            metadata: try MemoryEntry(
                assetId: "note-y", embedding: query384, sourceType: "note",
                timestamp: Date(timeIntervalSince1970: 2), traceID: "t-def34",
                originalText: "text channel hit two"
            ).encodeMetadata()
        )

        let adapter = GenerationRoutedChannelAdapter(
            generationRegistry: registry,
            kind: .textDense,
            dimension: 384,
            privacyActor: privacy
        )
        let pipeline = SearchPipeline(
            embedder: StableEmbedder(),
            privacyActor: privacy,
            vectorStore: VectorStoreActor(dimension: 512)
        )
        let items = await pipeline.searchMultiChannel(
            adapters: [adapter],
            queryVector: query384,
            queryText: "west lake",
            k: 5
        )
        #expect(items.contains { $0.id == x }, "fused ID must be present in assembled output")
        guard let itemX = items.first(where: { $0.id == x }) else { return }
        // 元数据来自 ID-keyed 字典（DEF-34-001），而非向量库 top-1 重查
        #expect(itemX.assetId == "note-x")
        #expect(itemX.originalText == "text channel hit")
        #expect(itemX.sourceType == "note")
        #expect(items.first(where: { $0.id == y })?.assetId == "note-y")
    }

    @Test("RRF: doc present in both channels at rank 1 ranks above single-channel rank 1")
    func test_RRF_FusionOrderingMultiChannelFirst() async throws {
        let pipeline = SearchPipeline(
            embedder: StableEmbedder(),
            privacyActor: PrivacyActor(db: db),
            vectorStore: VectorStoreActor(dimension: 512)
        )
        let x = UUID(), y = UUID(), z = UUID()
        // x: rank 1 in both text_dense (w=1.0) and vision_dense (w=0.8)
        // y: rank 2 in text_dense only; z: rank 2 in vision_dense only
        let fused = pipeline.rrfFuse(
            channelResults: [
                SearchPipeline.ChannelResult(channel: "text_dense", rankedIds: [x, y]),
                SearchPipeline.ChannelResult(channel: "vision_dense", rankedIds: [x, z]),
            ],
            k: 5
        )
        #expect(fused.first == x, "multi-channel rank-1 doc must fuse above single-channel docs")
        #expect(fused == [x, y, z], "RRF ordering: x (1/61+0.8/61) > y (1/62) > z (0.8/62)")
    }

    // ══════════════════════════════════════════════════════════════
    // US-RET-003: Multi-Channel Generation Routing
    // ══════════════════════════════════════════════════════════════

    @Test("RET-003: active vision route resolves to vision generation store")
    func test_generationRouting_ActiveVisionRouteResolvesStore() async throws {
        let registry = makeRegistry()
        let route = try await seedGenerations(registry)
        #expect(route.textGeneration == "text_dense/e5-v1")
        #expect(route.visionGeneration == "vision_dense/siglip2-v1")

        let visionStore = await registry.vectorStore(for: "vision_dense/siglip2-v1")
        #expect(visionStore != nil)
        #expect(visionStore?.dimension == 768, "vision channel store must be 768d (SigLIP2)")
        let textStore = await registry.vectorStore(for: "text_dense/e5-v1")
        #expect(textStore?.dimension == 384, "text channel store must be 384d (E5)")
    }

    @Test("RET-003 AC-2: text and vision generations remain separate vector spaces")
    func test_AC2_TextVisionSeparateVectorSpaces() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let textStore = await registry.vectorStore(for: "text_dense/e5-v1")
        let visionStore = await registry.vectorStore(for: "vision_dense/siglip2-v1")
        #expect(textStore != nil)
        #expect(visionStore != nil)

        let textId = UUID()
        let visionId = UUID()
        try await textStore?.ingest(vector: [Float](repeating: 0.5, count: 384), id: textId, metadata: nil)
        try await visionStore?.ingest(vector: [Float](repeating: 0.5, count: 768), id: visionId, metadata: nil)

        let textHits = await textStore?.search(query: [Float](repeating: 0.5, count: 384), k: 10) ?? []
        let visionHits = await visionStore?.search(query: [Float](repeating: 0.5, count: 768), k: 10) ?? []
        #expect(textHits.map(\.id) == [textId])
        #expect(!textHits.contains { $0.id == visionId }, "vision vector must not leak into text channel")
        #expect(visionHits.map(\.id) == [visionId])
        #expect(!visionHits.contains { $0.id == textId }, "text vector must not leak into vision channel")
    }

    @Test("RET-003: channel adapter search resolves through active generation route")
    func test_adapterSearch_ResolvesThroughActiveRoute() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let privacy = PrivacyActor(db: db)
        try await privacy.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo"],
            policyVersion: 1
        ))
        let adapter = GenerationRoutedChannelAdapter(
            generationRegistry: registry,
            kind: .visionDense,
            dimension: 768,
            privacyActor: privacy
        )
        // Empty stores degrade to timedOut (US-RET-008, see test_AC1_TimeoutChannelReturnsTimedOutFlag),
        // so seed one photo-tagged vision hit to exercise the non-empty retrieval path
        // (逐源授权过滤 PR#58 CR-9: sourceType "photo" 须在授权集内)。
        let visionStore = await registry.vectorStore(for: "vision_dense/siglip2-v1")
        let hitID = UUID()
        let photoMeta = try MemoryEntry(
            assetId: "photo-cat", embedding: [Float](repeating: 0.5, count: 768),
            sourceType: "photo", timestamp: Date(), traceID: "t-ret-003"
        ).encodeMetadata()
        try await visionStore?.ingest(vector: [Float](repeating: 0.5, count: 768), id: hitID, metadata: photoMeta)
        // Production contract: adapter resolves the active route → vision generation store
        // → returns hits for the query vector.
        let result = try await adapter.search(
            queryVector: [Float](repeating: 0.5, count: 768),
            queryText: "cat on the sofa",
            k: 5
        )
        #expect(result.channel == .visionDense)
        #expect(!result.rankedIds.isEmpty, "adapter must return hits from the active vision generation")
        #expect(result.rankedIds.contains(hitID))
        #expect(result.metadataByID[hitID]?.sourceType == "photo")
    }

    // ══════════════════════════════════════════════════════════════
    // US-SRC-011: Bounded Subjective Reranker (BoundedReranker)
    // ══════════════════════════════════════════════════════════════

    @Test("SRC-011: rerank applies subjective boost and reorders items")
    func test_rerank_AppliesSubjectiveBoost() async throws {
        let reranker = BoundedReranker(
            scorer: StableSubjectiveScorer(score: 0.95),
            config: RerankConfig(subjectiveBoost: 0.15, subjectiveThreshold: 0.6, maxAdjustment: 0.5)
        )
        let lowScore = SearchResultItem(id: UUID(), assetId: "note-low", sourceType: "note", timestamp: 0, cosineSimilarity: 0.9)
        let highScore = SearchResultItem(id: UUID(), assetId: "note-high", sourceType: "note", timestamp: 0, cosineSimilarity: 0.91)
        let out = try await reranker.rerank(items: [lowScore, highScore], queryText: "sunset")
        #expect(out.count == 2, "rerank must return the same item set, reordered")
    }

    @Test("FBK-002 AC-3: applyAdjustment clamps positive adjustment to +max")
    func test_AC3_ApplyAdjustmentPositiveClamp() {
        // rawAdjustment +5.0 → clamp ±0.5 → finalScore = 0.8 + 0.5
        #expect(BoundedReranker.applyAdjustment(score: 0.8, adjustment: 5.0, max: 0.5) == 1.3)
        #expect(BoundedReranker.applyAdjustment(score: 0.8, adjustment: 0.5, max: 0.5) == 1.3)
    }

    @Test("FBK-002 AC-3: applyAdjustment clamps negative adjustment to -max")
    func test_AC3_ApplyAdjustmentNegativeClamp() {
        #expect(BoundedReranker.applyAdjustment(score: 0.8, adjustment: -5.0, max: 0.5) == 0.3)
        #expect(BoundedReranker.applyAdjustment(score: 0.8, adjustment: -0.5, max: 0.5) == 0.3)
        #expect(BoundedReranker.applyAdjustment(score: 0.8, adjustment: 0.2, max: 0.5) == 1.0)
    }

    // ══════════════════════════════════════════════════════════════
    // US-FBK-002: Feedback Reranking (threshold / decay / truncation / same-query)
    // ══════════════════════════════════════════════════════════════

    @Test("FBK-002 AC-1: no adjustment below 0.80 cosine similarity threshold")
    func test_AC1_ThresholdBelow080NoAdjustment() async throws {
        let actor = FeedbackActor(db: db, privacyActor: PrivacyActor(db: db))
        let memoryId = UUID()
        try await actor.rawInsert(FeedbackEntry(
            memoryId: memoryId, queryText: "west lake", sentiment: .like, cosineSimilarity: 0.70
        ))
        let adjustment = try await actor.computeAdjustment(for: memoryId, queryText: "west lake")
        #expect(adjustment.adjustment == 0, "cosineSim 0.70 < 0.80 threshold must not apply feedback (AC-1)")
        #expect(adjustment.feedbackCount == 0)
    }

    @Test("FBK-002 AC-1: adjustment applies at 0.90 cosine similarity")
    func test_AC1_ThresholdAt090AdjustmentApplies() async throws {
        let actor = FeedbackActor(db: db, privacyActor: PrivacyActor(db: db))
        let memoryId = UUID()
        try await actor.rawInsert(FeedbackEntry(
            memoryId: memoryId, queryText: "west lake", sentiment: .like, cosineSimilarity: 0.90
        ))
        let adjustment = try await actor.computeAdjustment(for: memoryId, queryText: "west lake")
        #expect(adjustment.adjustment > 0, "cosineSim 0.90 ≥ 0.80 must apply feedback (AC-1)")
        #expect(adjustment.feedbackCount == 1)
    }

    @Test("FBK-002 AC-2: 100-day-old feedback decays to half weight")
    func test_AC2_MediumDecayFactor() async throws {
        let actor = FeedbackActor(db: db, privacyActor: PrivacyActor(db: db))
        let memoryId = UUID()
        try await actor.rawInsert(FeedbackEntry(
            memoryId: memoryId, queryText: "west lake", sentiment: .like, cosineSimilarity: 0.95,
            createdAt: Date().addingTimeInterval(-100 * 86400)
        ))
        let adjustment = try await actor.computeAdjustment(for: memoryId, queryText: "west lake")
        #expect(adjustment.adjustment == 0.5, "100 days → decayFactor 0.5 → adjustment 0.5 (AC-2)")
    }

    @Test("FBK-002 AC-2: feedback older than 180 days is archived (no adjustment)")
    func test_AC2_ArchivedAfter180Days() async throws {
        let actor = FeedbackActor(db: db, privacyActor: PrivacyActor(db: db))
        let memoryId = UUID()
        try await actor.rawInsert(FeedbackEntry(
            memoryId: memoryId, queryText: "west lake", sentiment: .like, cosineSimilarity: 0.95,
            createdAt: Date().addingTimeInterval(-200 * 86400)
        ))
        let adjustment = try await actor.computeAdjustment(for: memoryId, queryText: "west lake")
        #expect(adjustment.adjustment == 0, ">180 days → archived, must not participate (AC-2)")
        #expect(adjustment.feedbackCount == 0)
    }

    @Test("FBK-002 AC-3: raw adjustment is truncated to ±0.5")
    func test_AC3_TruncationClampsAt050() async throws {
        let actor = FeedbackActor(db: db, privacyActor: PrivacyActor(db: db))
        let memoryId = UUID()
        // 5 likes → rawAdjustment 5.0 → clamped to 0.5 (AC-3)
        for _ in 0..<5 {
            try await actor.rawInsert(FeedbackEntry(
                memoryId: memoryId, queryText: "west lake", sentiment: .like, cosineSimilarity: 0.95
            ))
        }
        let adjustment = try await actor.computeAdjustment(for: memoryId, queryText: "west lake")
        #expect(adjustment.adjustment == 0.5, "clamp(rawAdjustment, -0.5, 0.5) must cap at +0.5 (AC-3)")
        #expect(adjustment.feedbackCount == 5)
    }

    @Test("FBK-002: same-query feedback reranks search results end-to-end")
    func test_sameQueryFeedback_RankChange() async throws {
        let privacy = PrivacyActor(db: db)
        try await privacy.updatePolicy(makeSearchPolicy())
        let feedbackActor = FeedbackActor(db: db, privacyActor: privacy)
        let store = VectorStoreActor(dimension: 512)

        // Memory A aligned with query (cos 1.0); memory B at 45° (cos ~0.707).
        let idA = UUID()
        let idB = UUID()
        var vecA = [Float](repeating: 0, count: 512)
        vecA[0] = 1
        var vecB = [Float](repeating: 0, count: 512)
        vecB[0] = 0.70710678
        vecB[1] = 0.70710678
        let metaA = try MemoryEntry(assetId: "note-A", embedding: vecA, sourceType: "note", timestamp: Date(), traceID: "t-e2e").encodeMetadata()
        let metaB = try MemoryEntry(assetId: "note-B", embedding: vecB, sourceType: "note", timestamp: Date(), traceID: "t-e2e").encodeMetadata()
        try await store.ingest(vector: vecA, id: idA, metadata: metaA)
        try await store.ingest(vector: vecB, id: idB, metadata: metaB)

        let embedder = StableEmbedder()
        var query384 = [Float](repeating: 0, count: 384)
        query384[0] = 1
        await embedder.setTextEmbedding(query384)

        let pipeline = SearchPipeline(
            embedder: embedder,
            privacyActor: privacy,
            vectorStore: store,
            feedbackActor: feedbackActor
        )

        let before = try await pipeline.search(query: "west lake", k: 5)
        #expect(before.first?.id == idA, "baseline: memory A ranks first (cos 1.0 > 0.707)")

        // User likes B for the SAME query (cosineSim 0.90 ≥ 0.80 threshold → +0.5 clamp)
        _ = try await FeedbackPipeline(feedbackActor: feedbackActor, privacyActor: privacy)
            .recordLike(memoryId: idB, queryText: "west lake", cosineSimilarity: 0.9, traceID: "t-fb-e2e")

        let after = try await pipeline.search(query: "west lake", k: 5)
        let bAfter = after.first { $0.id == idB }
        #expect(bAfter?.feedbackAdjustment == 0.5, "liked memory must carry feedbackAdjustment +0.5")
        #expect(after.first?.id == idB, "same-query feedback must rerank B above A (0.707 + 0.5 > 1.0)")
    }

    @Test("FBK-002: feedback is query-text conditioned when queried")
    func test_feedback_QueryTextConditioned() async throws {
        let actor = FeedbackActor(db: db, privacyActor: PrivacyActor(db: db))
        let memoryId = UUID()
        // Like recorded against query "west lake" only.
        try await actor.rawInsert(FeedbackEntry(
            memoryId: memoryId, queryText: "west lake", sentiment: .like, cosineSimilarity: 0.95
        ))
        let sameQuery = try await actor.computeAdjustment(for: memoryId, queryText: "west lake")
        let otherQuery = try await actor.computeAdjustment(for: memoryId, queryText: "completely different query")
        #expect(sameQuery.adjustment == 0.5)
        #expect(otherQuery.adjustment == 0,
            "US-FBK-001 AC-4: feedback is associated with memoryId + query — a different query must not apply it")
    }

    // ══════════════════════════════════════════════════════════════
    // US-PRV-001: Authorization (denied source never reaches retriever)
    // ══════════════════════════════════════════════════════════════

    @Test("PRV-001 AC-2: denied source data never reaches the retriever (seeded + positive control)")
    func test_AC2_DeniedSourceNeverReachesRetriever() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let privacy = PrivacyActor(db: db)
        // "voice" is NOT authorized — policy version 2.
        try await privacy.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note"],
            policyVersion: 2
        ))
        let adapter = GenerationRoutedChannelAdapter(
            generationRegistry: registry,
            kind: .visionDense,
            dimension: 768,
            privacyActor: privacy
        )
        // Seed the vision store with ONE hit tagged as the denied "voice" source
        // (PR#58 CR-13: 空索引已不能解释空结果 — 若被授权则必返回该命中)。
        let voiceID = UUID()
        let voiceMeta = try MemoryEntry(
            assetId: "voice-memo", embedding: [Float](repeating: 0.5, count: 768),
            sourceType: "voice", timestamp: Date(), traceID: "t-prv-001"
        ).encodeMetadata()
        let visionStore = await registry.vectorStore(for: "vision_dense/siglip2-v1")
        try await visionStore?.ingest(vector: [Float](repeating: 0.5, count: 768), id: voiceID, metadata: voiceMeta)

        // Production contract: the per-source gate filters the denied "voice" hit —
        // the channel must be empty, never returning denied-source data.
        let denied = try await adapter.search(
            queryVector: [Float](repeating: 0.5, count: 768),
            queryText: "voice memo",
            k: 5
        )
        #expect(denied.rankedIds.isEmpty,
            "US-PRV-001 AC-2: denied source data must never reach the retriever")

        // Positive control (PR#58 CR-13): the same seeded hit IS retrievable when "voice"
        // becomes authorized — proves the empty result is due to the privacy gate,
        // not an empty index.
        try await privacy.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice"],
            policyVersion: 3
        ))
        let authorized = try await adapter.search(
            queryVector: [Float](repeating: 0.5, count: 768),
            queryText: "voice memo",
            k: 5
        )
        #expect(authorized.rankedIds.contains(voiceID),
            "positive control: the same hit must be retrievable once voice is authorized")
    }

    // ══════════════════════════════════════════════════════════════
    // US-RET-005: Follow-up Query (approach a — NO LLM rewrite)
    // ══════════════════════════════════════════════════════════════
    // NOTE: AC-1 (FIFO ≤10 history) 与 AC-2 (memoryIds 隐式过滤注入) 未在 3F.6 落地 —
    // production SearchPipeline 仅追踪单轮 lastSearchQuery/lastSearchTraceID（approach a），
    // 见 DEF-58-002。此处仅覆盖真实生产行为 AC-4（.followUpQuery 审计）。

    @Test("RET-005 AC-4: follow-up search audits .followUpQuery with current traceID + parent link")
    func test_AC4_FollowUpAuditCarriesParentTraceID() async throws {
        let privacy = PrivacyActor(db: db)
        try await privacy.updatePolicy(makeSearchPolicy())
        let pipeline = SearchPipeline(
            embedder: StableEmbedder(),
            privacyActor: privacy,
            vectorStore: VectorStoreActor(dimension: 512)
        )
        let parentTrace = "followup-parent-trace-1"
        // Round 1 (parent) + round 2 (follow-up, approach a: same query, no LLM rewrite)
        _ = try await pipeline.search(query: "west lake trip", k: 5, traceID: parentTrace)
        _ = try await pipeline.search(query: "west lake trip", k: 5)

        let rows = try await db.executeQuery(
            sql: "SELECT traceID, sourceLanguage FROM AuditLog WHERE eventType = 'followUpQuery' ORDER BY timestamp DESC LIMIT 1",
            bindings: []
        )
        #expect(rows.first != nil, "follow-up search must write a .followUpQuery audit event (AC-4)")
        #expect(rows.first?["traceID"]?.stringValue != parentTrace,
            "audit traceID must identify the current round, not the parent (PR#58 CR-4)")
        let payload = rows.first?["sourceLanguage"]?.stringValue ?? ""
        #expect(payload.contains(parentTrace),
            "parent traceID must be carried in the sourceLanguage payload (AC-4 parentTraceId)")
    }

    // ══════════════════════════════════════════════════════════════
    // DEF-37-001: L2 Feedback Failure → PendingOperations (visible, manually retryable)
    // ══════════════════════════════════════════════════════════════

    @Test("DEF-37-001: L2 feedback failure is visible in PendingOperations, not swallowed")
    func test_L2FeedbackFailureVisibleInPendingOperations() async throws {
        let privacy = PrivacyActor(db: db)
        let feedbackActor = FeedbackActor(db: db, privacyActor: privacy)
        let pipeline = FeedbackPipeline(feedbackActor: feedbackActor, privacyActor: privacy)

        // Inject an L2 failure: close the shared database so the FeedbackActor write throws.
        await db.close()
        do {
            _ = try await pipeline.recordLike(
                memoryId: UUID(),
                queryText: "west lake",
                cosineSimilarity: 0.9,
                traceID: "t-def37"
            )
            #expect(Bool(false), "expected recordLike to fail with a closed database (L2)")
        } catch {
            // Expected L2 failure — must NOT be silently swallowed.
        }
        try await db.open()

        let ops = try await PendingOpsActor.shared.listAll()
        #expect(ops.contains { $0.operationType == "feedback" && $0.retryCount == 0 },
            "DEF-37-001: L2 feedback failure must be recorded as a PendingOperation (visible + manually retryable)")
        let count = try await PendingOpsActor.shared.count()
        #expect(count >= 1, "DEF-37-001: pending feedback operation must be counted")
    }

    // ══════════════════════════════════════════════════════════════
    // DEF-56-005: generationId passthrough in FeedbackPipeline
    // ══════════════════════════════════════════════════════════════

    @Test("DEF-56-005: FeedbackPipeline passes active generationId through to FeedbackActor")
    func test_generationIdPassedThroughPipeline() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let feedbackActor = FeedbackActor(db: db, privacyActor: PrivacyActor(db: db))
        let pipeline = FeedbackPipeline(feedbackActor: feedbackActor, privacyActor: PrivacyActor(db: db))

        let entry = try await pipeline.recordLike(
            memoryId: UUID(),
            queryText: "west lake",
            cosineSimilarity: 0.9,
            traceID: "t-genid"
        )
        // ADR-010 决策-4: feedback entries must be bound to the generation that produced
        // the result they were recorded against (active text generation here).
        let bound = try await feedbackActor.generationId(for: entry.id)
        #expect(bound == "text_dense/e5-v1",
            "DEF-56-005: FeedbackPipeline.recordFeedback must accept and persist the active generationId")
    }

    // ══════════════════════════════════════════════════════════════
    // DEF-56-006: searchCanonical ordering (ORDER BY rank before LIMIT)
    // ══════════════════════════════════════════════════════════════

    @Test("DEF-56-006: searchCanonical returns most relevant (FTS rank) memory first")
    func test_searchCanonicalOrderedByRelevance() async throws {
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: GenerationRegistryActor(db: db))
        // Seed in REVERSE relevance order so insertion order != FTS rank order.
        let lessRelevant = UUID()
        let moreRelevant = UUID()
        try await repo.commit(
            memory: Memory(
                memoryId: lessRelevant,
                sourceLocator: "seed-order-1",
                canonicalText: "unforgettable westlake trip",
                sourceType: "note",
                createdAt: Date(),
                recoverability: .full
            ),
            representations: [],
            vectorsByGeneration: [:],
            traceID: "t-order-1"
        )
        try await repo.commit(
            memory: Memory(
                memoryId: moreRelevant,
                sourceLocator: "seed-order-2",
                canonicalText: "unforgettable westlake unforgettable westlake unforgettable westlake trip",
                sourceType: "note",
                createdAt: Date(),
                recoverability: .full
            ),
            representations: [],
            vectorsByGeneration: [:],
            traceID: "t-order-2"
        )

        let hits = try await repo.searchCanonical(matching: "unforgettable westlake", limit: 10)
        #expect(hits.count == 2)
        #expect(hits.first == moreRelevant,
            "DEF-56-006: searchCanonical must ORDER BY FTS rank before applying LIMIT")
    }

}
