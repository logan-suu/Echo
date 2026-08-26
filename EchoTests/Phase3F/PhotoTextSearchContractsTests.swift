// ==========================================
// 文件: PhotoTextSearchContractsTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RET-003 / US-ING-004
// 任务: 自然语言照片检索交接计划 WP0 - 规格与 ADR 事实统一
// AC 覆盖: WP0 步骤 1a-1j (ADR 必需条款), 步骤 3a-3c (规格 CLIP-space 残留清除 + 能力禁用守卫)
// 架构约束: 遵循交接计划 §7 (SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor 下显式 nonisolated 惯例);
//           本套件为文档契约测试——断言 ADR/规格文本包含必需条款标记, 不触碰生产代码。
// 生成时间: 2026-08-25
// ==========================================

import Foundation
import Testing

@testable import Echo

/// WP0 文档契约测试。
///
/// 每个测试断言一份治理文档包含（或不包含）精确条款标记。
/// 标记字符串即条款的唯一机器可读锚点；修改文档时必须同步保留这些标记。
@Suite("PhotoTextSearchContracts")
struct PhotoTextSearchContractsTests {

    // MARK: - Fixtures

    /// 从测试文件路径推导仓库根目录（EchoTests/Phase3F → repo root 上三级）。
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // EchoTests/Phase3F
        .deletingLastPathComponent()   // EchoTests
        .deletingLastPathComponent()   // repo root

    private static let adrPath = "docs/decisions/ADR-015-photo-text-retrieval.md"
    private static let specPath = "docs/01-spec/用户故事与验收标准规格书.md"

    private static func readDoc(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - WP0 Step 1: ADR-015 必需条款

    @Test("ADR-015 requires native per-channel query representations")
    func testADRRequiresNativePerChannelQueries() throws {
        let adr = try Self.readDoc(Self.adrPath)
        #expect(adr.contains("native-per-channel-queries"))
    }

    @Test("ADR-015 requires canonical-ID fusion before RRF")
    func testADRRequiresCanonicalIDFusion() throws {
        let adr = try Self.readDoc(Self.adrPath)
        #expect(adr.contains("canonical-id-fusion-before-rrf"))
    }

    @Test("ADR-015 requires complete route snapshot rollback")
    func testADRRequiresCompleteRouteRollback() throws {
        let adr = try Self.readDoc(Self.adrPath)
        #expect(adr.contains("complete-route-snapshot-rollback"))
    }

    @Test("ADR-015 forbids reusing current vision vectors and mandates corrected reindex")
    func testADRRequiresCorrectedVisionReindex() throws {
        let adr = try Self.readDoc(Self.adrPath)
        #expect(adr.contains("corrected-vision-graph-mandatory-reindex"))
    }

    @Test("ADR-015 requires offline-only model artifacts")
    func testADRRequiresOfflineOnlyArtifacts() throws {
        let adr = try Self.readDoc(Self.adrPath)
        #expect(adr.contains("offline-only-model-artifacts"))
    }

    // MARK: - WP0 Step 3a/3b: 规格 CLIP-space 残留清除

    /// 活跃规格不得再要求「无配对文本塔的 CLIP-space 查询」。
    /// 两条陈旧 AC 正文（原 L415 / L490）与其自身修订横幅自相矛盾，必须移除。
    @Test("Active spec no longer requires unpaired CLIP-space queries")
    func testSpecRemovesUnpairedCLIPQueryRequirement() throws {
        let spec = try Self.readDoc(Self.specPath)
        #expect(!spec.contains("图片生成 CLIP 向量，与文本向量空间对齐"))
        #expect(!spec.contains("混合查询向量仍位于 CLIP 空间"))
    }

    // MARK: - WP0 Step 3c: 能力禁用守卫 (GREEN regression)

    /// 在 WP7 发布门禁全部通过之前，能力文案与路由必须保持禁用。
    @Test("Capability remains disabled before WP7")
    func testCapabilityRemainsDisabledBeforeWP7() throws {
        let adr = try Self.readDoc(Self.adrPath)
        #expect(adr.contains("capability-disabled-until-release-gates"))
    }
}

// MARK: - WP1 Step 1a/1b: 生产搜索显式 E5 query 上下文

/// 记录每次 embedText 收到的上下文；用于断言生产调用点显式传参。
private actor ContextRecordingEmbedder: EmbedderProtocol {
    private(set) var recordedContexts: [TextEmbeddingContext] = []
    private(set) var legacyCallCount = 0

    func embedImage(assetId: String) async throws -> [Float] {
        throw EmbedderError.preprocessingFailed(reason: "spy: image unsupported")
    }

    func embedImageData(_ data: Data) async throws -> [Float] {
        throw EmbedderError.preprocessingFailed(reason: "spy: image data unsupported")
    }

    func embedText(_ text: String) async throws -> [Float] {
        legacyCallCount += 1
        return [Float](repeating: 1.0 / sqrt(384), count: 384)
    }

    func embedText(_ text: String, context: TextEmbeddingContext) async throws -> [Float] {
        recordedContexts.append(context)
        return [Float](repeating: 1.0 / sqrt(384), count: 384)
    }
}

extension PhotoTextSearchContractsTests {

    /// WP1 步骤 2c/2d：TextEmbeddingContext 必须显式 nonisolated。
    /// 实现于步骤 1（创建即 nonisolated），本测试为回归守卫（GREEN regression）。
    @Test("TextEmbeddingContext declaration is explicitly nonisolated (WP1 step 2c)")
    func testTextEmbeddingContextIsNonisolated() throws {
        let source = try Self.readDoc("Echo/Core/Services/TextEmbedding.swift")
        #expect(source.contains("public nonisolated enum TextEmbeddingContext"))
    }


// MARK: - WP1 Step 2a: ContextualTextEmbedder conformance

/// Actor 测试替身——验证协议可被 actor 无 MainActor 跳跃地 conform。
private actor DummyContextualEmbedder: ContextualTextEmbedder {
    nonisolated let modelManifestID = "test-e5-dummy"
    nonisolated let dimension = 384

    func embed(text: String, context: TextEmbeddingContext, traceID: String) async throws -> [Float] {
        [Float](repeating: 1.0 / sqrt(384), count: 384)
    }
}

@Test("Contextual embedder conformance without MainActor hop (WP1 step 2a)")
func testContextualTextEmbedderConformanceWithoutMainActorHop() async throws {
    let dummy = DummyContextualEmbedder()
    let vector = try await dummy.embed(text: "red flower", context: .query, traceID: "t-2a")
    #expect(vector.count == 384)
    #expect(await dummy.modelManifestID == "test-e5-dummy")
}

@Test("Production search requests E5 query context (WP1 step 1a)")
func testSearchUsesE5QueryContext() async throws {
    let spy = ContextRecordingEmbedder()
    let pipeline = SearchPipeline(
        embedder: spy,
        vectorStore: VectorStoreActor(dimension: 384)
    )
    _ = try await pipeline.search(query: "red flower", k: 1)
    let contexts = await spy.recordedContexts
    let legacyCalls = await spy.legacyCallCount
    #expect(contexts == [.query])
    #expect(legacyCalls == 0)
}
}

// MARK: - WP1 Steps 3/4: canonical 向量正向映射

/// 共享库夹具：清表 + 种子 active generation + 构造仓库。
enum CanonicalMappingFixtures {
    static func prepare() async throws -> CanonicalMemoryRepositoryActor {
        let db = DatabaseManager.shared
        try await db.open()
        try await db.execute(sql: "DELETE FROM Representation")
        try await db.execute(sql: "DELETE FROM Memory")
        try await db.execute(sql: "DELETE FROM IndexGeneration")
        try await db.execute(sql: "DELETE FROM ActiveRouteSet")
        let registry = GenerationRegistryActor(db: db)
        try await registry.registerGeneration(
            IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384)
        )
        try await registry.setGenerationState("text_dense/e5-v1", state: .ready)
        try await registry.setGenerationState("text_dense/e5-v1", state: .active)
        return CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
    }
}

extension PhotoTextSearchContractsTests {

    @Test("Nil-metadata vector hit maps through canonical repository (WP1 step 3a)")
    func testNilVectorMetadataMapsThroughCanonicalRepository() async throws {
        let repo = try await CanonicalMappingFixtures.prepare()
        let generationID = "text_dense/e5-v1"
        let representationID = UUID()
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/wp1-nil", sourceType: "photo")
        _ = try await repo.commit(
            memory: Memory(memoryId: memoryId, sourceLocator: "PHAsset/wp1-nil", canonicalText: nil, sourceType: "photo"),
            representations: [Representation(
                representationId: representationID,
                memoryId: memoryId,
                modality: .visionDense,
                preprocessVersion: "siglip2-v1",
                contentHash: "hash-nil"
            )],
            vectorsByGeneration: ["text_dense/e5-v1": [
                CanonicalVectorEntry(id: representationID, vector: [Float](repeating: 0.25, count: 384))
            ]],
            traceID: "t-wp1-3a"
        )
        let result = try await repo.mapVectorID(representationID, generationID: generationID)
        guard case .mapped(let binding) = result else {
            Issue.record("expected .mapped")
            return
        }
        #expect(binding.memoryID == memoryId)
    }

    @Test("EXIF-metadata vector hit maps without legacy MemoryEntry decode (WP1 step 3c)")
    func testEXIFMetadataMapsThroughCanonicalRepository() async throws {
        let repo = try await CanonicalMappingFixtures.prepare()
        let generationID = "text_dense/e5-v1"
        let representationID = UUID()
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/wp1-exif", sourceType: "photo")
        let exifPayload = Data("{\"EXIF\":{\"Orientation\":6}}".utf8)
        _ = try await repo.commit(
            memory: Memory(memoryId: memoryId, sourceLocator: "PHAsset/wp1-exif", canonicalText: nil, sourceType: "photo"),
            representations: [Representation(
                representationId: representationID,
                memoryId: memoryId,
                modality: .visionDense,
                preprocessVersion: "siglip2-v1",
                contentHash: "hash-exif"
            )],
            vectorsByGeneration: ["text_dense/e5-v1": [
                CanonicalVectorEntry(id: representationID, vector: [Float](repeating: 0.5, count: 384), metadata: exifPayload)
            ]],
            traceID: "t-wp1-3c"
        )
        let result = try await repo.mapVectorID(representationID, generationID: generationID)
        guard case .mapped(let binding) = result else {
            Issue.record("expected .mapped")
            return
        }
        #expect(binding.memoryID == memoryId)
    }

    @Test("Unknown vector ID returns typed missing mapping (WP1 step 3e)")
    func testMissingCanonicalRowReturnsTypedMissingMapping() async throws {
        let repo = try await CanonicalMappingFixtures.prepare()
        let generationID = "text_dense/e5-v1"
        let ghost = UUID()
        let result = try await repo.mapVectorID(ghost, generationID: generationID)
        #expect(result == .missing(vectorID: ghost, generationID: generationID))
    }

    @Test("Batch lookup maps vector IDs keyed by input (WP1 step 4a)")
    func testBatchLookupMapsVectorIDsInOneRepositoryCall() async throws {
        let repo = try await CanonicalMappingFixtures.prepare()
        let generationID = "text_dense/e5-v1"
        let firstID = UUID()
        let secondID = UUID()
        let memoryOne = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/wp1-b1", sourceType: "photo")
        let memoryTwo = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/wp1-b2", sourceType: "photo")
        _ = try await repo.commit(
            memory: Memory(memoryId: memoryOne, sourceLocator: "PHAsset/wp1-b1", canonicalText: nil, sourceType: "photo"),
            representations: [Representation(representationId: firstID, memoryId: memoryOne, modality: .visionDense, preprocessVersion: "siglip2-v1", contentHash: "h1")],
            vectorsByGeneration: ["text_dense/e5-v1": [CanonicalVectorEntry(id: firstID, vector: [Float](repeating: 0.25, count: 384))]],
            traceID: "t-wp1-4a"
        )
        _ = try await repo.commit(
            memory: Memory(memoryId: memoryTwo, sourceLocator: "PHAsset/wp1-b2", canonicalText: nil, sourceType: "photo"),
            representations: [Representation(representationId: secondID, memoryId: memoryTwo, modality: .visionDense, preprocessVersion: "siglip2-v1", contentHash: "h2")],
            vectorsByGeneration: ["text_dense/e5-v1": [CanonicalVectorEntry(id: secondID, vector: [Float](repeating: 0.5, count: 384))]],
            traceID: "t-wp1-4a"
        )
        let ghost = UUID()
        let results = try await repo.mapVectorIDs([firstID, secondID, ghost], generationID: generationID)
        guard case .mapped(let b1) = results[firstID] else {
            Issue.record("expected mapped first")
            return
        }
        guard case .mapped(let b2) = results[secondID] else {
            Issue.record("expected mapped second")
            return
        }
        #expect(b1.memoryID == memoryOne)
        #expect(b2.memoryID == memoryTwo)
        #expect(results[ghost] == .missing(vectorID: ghost, generationID: generationID))
    }
}

extension PhotoTextSearchContractsTests {

    /// WP1 步骤 4c/4d：canonical 路径 hydration 不经 legacy MemoryEntry.decodeMetadata。
    /// 行为学证明——向量 metadata 为「legacy 必然解码失败」的载荷，
    /// 唯有走 canonical 映射才可能命中；旧实现（C6）会静默丢弃该命中。
    @Test("Canonical generation path hydrates without legacy decode (WP1 step 4c)")
    func testCanonicalGenerationDoesNotCallMemoryEntryDecodeMetadata() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        for table in ["Representation", "Memory", "IndexGeneration", "ActiveRouteSet"] {
            try await db.execute(sql: "DELETE FROM \(table)")
        }
        // 环境自含：种子含 photo 授权的 UserPolicy——adapter(privacyActor: .shared)
        // 的逐源授权过滤依赖授权状态，不得依赖跨套件残留（消除执行顺序敏感性）
        try await db.executeWrite(
            sql: "INSERT OR REPLACE INTO UserPolicyStore (id, preferredLanguage, authorizedSourceTypes, policyVersion, updatedAt) VALUES (1, ?, ?, ?, ?)",
            bindings: [
                .text("zh-Hans"),
                .text(#"["search","photo","note","voice","text","video"]"#),
                .int(1),
                .double(Date().timeIntervalSince1970),
            ]
        )
        try await PrivacyActor.shared.loadPolicy()
        let registry = GenerationRegistryActor(db: db)
        // 环境自含：清理同名 store 文件——前序套件可能向该代写入残留向量，
        // 导致重建 generation 时加载污染 store（单独跑绿、全量跑红的根因）
        try? await registry.removeStoreFile(generationId: "vision_dense/siglip2-v1")
        try? await registry.removeStoreFile(generationId: "text_dense/e5-v1")
        try await registry.registerGeneration(IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384))
        try await registry.finishShadowBuild("text_dense/e5-v1", counts: 0, validationDigest: nil)
        try await registry.setGenerationState("text_dense/e5-v1", state: .ready)
        try await registry.registerGeneration(IndexGeneration(generationId: "vision_dense/siglip2-v1", indexType: "vision_dense", dimension: 768))
        try await registry.finishShadowBuild("vision_dense/siglip2-v1", counts: 0, validationDigest: nil)
        try await registry.setGenerationState("vision_dense/siglip2-v1", state: .ready)
        let activated = try await registry.activateGeneration("text_dense/e5-v1")
        try await registry.publishRoute(ActiveRouteSet(
            textGeneration: "text_dense/e5-v1",
            visionGeneration: "vision_dense/siglip2-v1",
            version: activated.version
        ))
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)

        let representationID = UUID()
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/wp1-4c", sourceType: "photo")
        _ = try await repo.commit(
            memory: Memory(memoryId: memoryId, sourceLocator: "PHAsset/wp1-4c", canonicalText: nil, sourceType: "photo"),
            representations: [Representation(
                representationId: representationID,
                memoryId: memoryId,
                modality: .visionDense,
                preprocessVersion: "siglip2-v1",
                contentHash: "hash-4c"
            )],
            vectorsByGeneration: [:],
            traceID: "t-wp1-4c"
        )

        guard let store = await registry.vectorStore(for: "vision_dense/siglip2-v1") else {
            Issue.record("active vision generation must expose a vector store")
            return
        }
        let queryVector = [Float](repeating: 0.5, count: 768)
        try await store.ingest(vector: queryVector, id: representationID, metadata: Data("not-valid-memory-entry{".utf8))

        let adapter = await GenerationRoutedChannelAdapter(
            generationRegistry: registry,
            kind: .visionDense,
            dimension: 768,
            canonicalMapper: repo
        )
        let result = try await adapter.search(queryVector: queryVector, queryText: "", k: 5)

        #expect(result.rankedIds == [representationID])
        #expect(result.metadataByID[representationID]?.sourceType == "photo")
    }
}

extension PhotoTextSearchContractsTests {

    // MARK: - WP1 Step 5: 维度漂移清除（源码契约）

    /// 步骤 5a：生产 initializer 不得再携带 512d 默认值——维度必须显式来自契约。
    @Test("IndexGeneration initializer has no 512 default (WP1 step 5a)")
    func testIndexGenerationInitializerHasNo512Default() throws {
        let source = try Self.readDoc("Echo/Core/Models/IndexGeneration.swift")
        #expect(!source.contains("dimension: Int = 512"))
    }

    /// 步骤 5c/5e/5g：AppDelegate 三处 store 构造不得硬编码 512d。
    @Test("AppDelegate compositions use no hardcoded 512d stores (WP1 steps 5c/5e/5g)")
    func testAppDelegateCompositionsUseNoHardcoded512Stores() throws {
        let source = try Self.readDoc("Echo/App/AppDelegate.swift")
        #expect(!source.contains("VectorStoreActor(dimension: 512)"))
    }

    // MARK: - WP1 Step 6: 维度迁移幂等

    /// 步骤 6a（源码契约部分）：dimension ALTER 必须有 schema-state 守卫，
    /// 禁止 try?-吞错模式（错误迁移会留下不一致 schema）。
    @Test("IndexGeneration dimension ALTER is schema-guarded (WP1 step 6a)")
    func testDimensionAlterIsSchemaGuarded() throws {
        let source = try Self.readDoc("Echo/Core/Actors/DatabaseManager.swift")
        #expect(source.contains("columnNames(in: \"IndexGeneration\")"))
        #expect(!source.contains("try? execute(sql: \"ALTER TABLE IndexGeneration"))
    }

    /// 步骤 6a（行为回归守卫）：同一数据库二次 open 不抛错、dimension 列恰一份。
    @Test("Dimension migration is idempotent across second open (WP1 step 6a)")
    func testDimensionMigrationIsIdempotentAcrossSecondOpen() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        try await db.close()
        try await db.open()
        let columns = try await db.columnNames(in: "IndexGeneration")
        #expect(columns.filter { $0 == "dimension" }.count == 1)
    }
}
