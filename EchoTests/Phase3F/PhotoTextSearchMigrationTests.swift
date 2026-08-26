// ==========================================
// 文件: PhotoTextSearchMigrationTests.swift
// 对应规格: 交接计划 §WP6 步骤 1a-1b2（shadow build 不改变活跃路由）
// 任务: WP6 - 迁移、重建索引、原子发布与回滚
// 生成时间: 2026-08-25
// ==========================================

import Foundation
import Testing

@testable import Echo

@Suite(.serialized)
struct PhotoTextSearchMigrationTests {

    @MainActor
    private static func seedActiveRoute(db: DatabaseManager, registry: GenerationRegistryActor) async throws -> String {
        let genId = "text_dense/e5-v1-\(UUID().uuidString.prefix(6))"
        try await registry.registerGeneration(IndexGeneration(generationId: genId, indexType: "text_dense", dimension: 384))
        try await registry.setGenerationState(genId, state: .ready)
        try await registry.setGenerationState(genId, state: .active)
        // 维持既有测试依赖的 vision 代环境（WP1 step 4c 期望活跃路由含 vision）：
        // 不存在才注册激活；已存在（含 active 态）直接引用，避免非法状态迁移
        if try await registry.loadGeneration("vision_dense/siglip2-v1") == nil {
            try await registry.registerGeneration(IndexGeneration(generationId: "vision_dense/siglip2-v1", indexType: "vision_dense", dimension: 768))
            try await registry.setGenerationState("vision_dense/siglip2-v1", state: .ready)
            try await registry.setGenerationState("vision_dense/siglip2-v1", state: .active)
        }
        let published = try await registry.activateGeneration(genId)
        try await registry.publishRoute(ActiveRouteSet(
            textGeneration: published.textGeneration,
            visionGeneration: "vision_dense/siglip2-v1",
            version: published.version
        ))
        return "active-v\(published.version)-\(published.textGeneration)"
    }

    @Test("Photo shadow build starts without changing active route (WP6 step 1a/1b)")
    func testPhotoShadowBuildStartsWithoutChangingActiveRoute() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let registry = GenerationRegistryActor(db: db)
        let migration = PhotoSearchMigrationActor(generationRegistry: registry)

        let beforeSnapshot = try await Self.seedActiveRoute(db: db, registry: registry)

        _ = try await migration.startPhotoShadowBuild(traceID: "t-wp6-1a")

        let after = try await registry.loadActiveRoute()
        let afterSnapshot = after.flatMap { "active-v\($0.version)-\($0.textGeneration)" }
        #expect(afterSnapshot == beforeSnapshot,
                "active route snapshot must remain unchanged after shadow build start")
    }

    @Test("Photo shadow generation is created in building state (WP6 step 1b1/1b2)")
    func testPhotoShadowGenerationIsCreated() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let registry = GenerationRegistryActor(db: db)
        let migration = PhotoSearchMigrationActor(generationRegistry: registry)

        _ = try await Self.seedActiveRoute(db: db, registry: registry)

        let st = try await migration.startPhotoShadowBuild(traceID: "t-wp6-1b1")
        guard let shadowID = st.shadowGenerationID else {
            Issue.record("shadow generation ID missing")
            return
        }
        let gen = try await registry.loadGeneration(shadowID)
        #expect(gen != nil, "shadow generation row must exist")
        #expect(st.phase == .shadowBuilding)
    }
}

// MARK: - WP6 步骤 1c-1d2：逐照片迁移 + IndexBuildItem + progress checkpoint

private struct WP6MigrationEmbedder: EmbedderProtocol {
    func embedImage(assetId: String) async throws -> [Float] { Array(repeating: 0, count: 768) }
    func embedText(_ text: String) async throws -> [Float] { Array(repeating: 0, count: 384) }
    func embedText(_ text: String, context: TextEmbeddingContext) async throws -> [Float] {
        Array(repeating: 0, count: 384)
    }
    func embedImageData(_ data: Data) async throws -> [Float] { Array(repeating: 0.5, count: 768) }
}

private struct WP6StubPhotoExtractor: PhotoAssetExtracting {
    let imageData: Data?
    func extractMetadata(assetId: String) async throws -> PhotoAssetContent {
        PhotoAssetContent(assetId: assetId, creationDate: Date(), exifMetadata: nil)
    }
    func isLocallyAvailable(assetId: String) async -> Bool { imageData != nil }
    func extractImageData(assetId: String) async throws -> Data? { imageData }
}

extension PhotoTextSearchMigrationTests {

    @Test("Photo migration persists one IndexBuildItem and progress checkpoint (WP6 steps 1c-1d2)")
    func testPhotoMigrationPersistsBuildItemAndProgress() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let registry = GenerationRegistryActor(db: db)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let progress = ProgressActor.shared
        let migration = PhotoSearchMigrationActor(
            generationRegistry: registry,
            canonicalRepository: repo,
            visionEmbedder: WP6MigrationEmbedder(),
            photoExtractor: WP6StubPhotoExtractor(imageData: Data([0x89, 0x50, 0x4E, 0x47])),
            progressActor: progress
        )

        // 种子：活跃路由 + shadow generation + 一张 canonical photo memory
        _ = try await Self.seedActiveRoute(db: db, registry: registry)
        let st = try await migration.startPhotoShadowBuild(traceID: "t-wp6-1c")
        guard let shadowID = st.shadowGenerationID else {
            Issue.record("shadow ID missing")
            return
        }

        let locator = "PHAsset/wp6-mig-\(UUID().uuidString)"
        let memID = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: locator, sourceType: "photo")
        try await registry.registerGeneration(IndexGeneration(generationId: "vision_dense/siglip2-v1", indexType: "vision_dense", dimension: 768))
        let memory = Memory(memoryId: memID, sourceLocator: locator, canonicalText: nil, sourceType: "photo")
        try await repo.commit(
            memory: memory,
            representations: [Representation(representationId: memID, memoryId: memID, modality: .visionDense, preprocessVersion: "siglip2-v1", contentHash: "h")],
            vectorsByGeneration: ["vision_dense/siglip2-v1": [CanonicalVectorEntry(id: memID, vector: Array(repeating: 0.25, count: 768))]],
            traceID: "t-wp6-seed"
        )

        let item = try await migration.migratePhoto(
            memoryId: memID,
            shadowGenerationID: shadowID,
            taskID: "t-wp6-1c",
            traceID: "t-wp6-1c"
        )

        // 步骤 1c/1d: IndexBuildItem 持久化
        #expect(item.state == "done")
        let items = try await registry.loadBuildItems(generationId: shadowID)
        #expect(items.count == 1, "one build item per migrated photo")
        #expect(items.first?.state == "done")
        #expect(items.first?.representationId == CanonicalMemoryRepositoryActor.photoRepresentationID(memoryID: memID).uuidString,
                "representationId must be the deterministic photo representation ID")

        // 步骤 1d1/1d2: progress checkpoint 更新
        let saved = try await progress.load(taskId: "t-wp6-1c")
        #expect(saved?.lastProcessedId == locator)
        #expect(saved?.lastProcessedIndex == 1)
    }

    @Test("Source-missing photo marks build item failed without fabricating vector (WP6 step 2a/2b)")
    func testMissingSourceMarksOnlyBuildItemFailed() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let registry = GenerationRegistryActor(db: db)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let migration = PhotoSearchMigrationActor(
            generationRegistry: registry,
            canonicalRepository: repo,
            visionEmbedder: WP6MigrationEmbedder(),
            photoExtractor: WP6StubPhotoExtractor(imageData: nil),
            progressActor: ProgressActor.shared
        )

        _ = try await Self.seedActiveRoute(db: db, registry: registry)
        let st = try await migration.startPhotoShadowBuild(traceID: "t-wp6-2a")
        guard let shadowID = st.shadowGenerationID else { return }

        let locator = "PHAsset/wp6-missing-\(UUID().uuidString)"
        let memID = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: locator, sourceType: "photo")
        try await registry.registerGeneration(IndexGeneration(generationId: "vision_dense/siglip2-v1", indexType: "vision_dense", dimension: 768))
        try await repo.commit(
            memory: Memory(memoryId: memID, sourceLocator: locator, canonicalText: nil, sourceType: "photo"),
            representations: [Representation(representationId: memID, memoryId: memID, modality: .visionDense, preprocessVersion: "siglip2-v1", contentHash: "h")],
            vectorsByGeneration: ["vision_dense/siglip2-v1": [CanonicalVectorEntry(id: memID, vector: Array(repeating: 0.25, count: 768))]],
            traceID: "t-wp6-seed"
        )

        let item = try await migration.migratePhoto(
            memoryId: memID,
            shadowGenerationID: shadowID,
            taskID: "t-wp6-2a",
            traceID: "t-wp6-2a"
        )

        #expect(item.state == "failed", "missing source must mark the build item failed")
        #expect(item.error == "source-missing")
        let items = try await registry.loadBuildItems(generationId: shadowID)
        #expect(items.count == 1)
        #expect(items.first?.state == "failed")
    }
}

// MARK: - WP6 步骤 1e-1h：视频帧确定性 ID + 取消保持路由

extension PhotoTextSearchMigrationTests {

    @Test("Video frame representation ID is deterministic across recovery (WP6 step 1e/1f)")
    func testVideoFrameMigrationUsesDeterministicRepresentationID() async throws {
        let id1 = CanonicalMemoryRepositoryActor.videoFrameRepresentationID(sourceLocator: "PHAsset/v1", frameIndex: 3)
        let id2 = CanonicalMemoryRepositoryActor.videoFrameRepresentationID(sourceLocator: "PHAsset/v1", frameIndex: 3)
        #expect(id1 == id2, "frame ID must be reproducible across recovery")
        let id3 = CanonicalMemoryRepositoryActor.videoFrameRepresentationID(sourceLocator: "PHAsset/v1", frameIndex: 4)
        #expect(id1 != id3, "different frame index must yield a different ID")
    }

    @Test("Migration cancellation keeps active route digest and preserves progress (WP6 step 1g/1h)")
    func testMigrationCancellationKeepsActiveRouteAndProgress() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let registry = GenerationRegistryActor(db: db)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let migration = PhotoSearchMigrationActor(
            generationRegistry: registry,
            canonicalRepository: repo,
            visionEmbedder: WP6MigrationEmbedder(),
            photoExtractor: WP6StubPhotoExtractor(imageData: Data([0x89, 0x50, 0x4E, 0x47])),
            progressActor: ProgressActor.shared
        )

        let beforeSnapshot = try await Self.seedActiveRoute(db: db, registry: registry)
        let st = try await migration.startPhotoShadowBuild(traceID: "t-wp6-1g")
        guard let shadowID = st.shadowGenerationID else { return }

        // 迁移一张照片使进度 = 1
        let locator = "PHAsset/wp6-cancel-\(UUID().uuidString)"
        let memID = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: locator, sourceType: "photo")
        try await registry.registerGeneration(IndexGeneration(generationId: "vision_dense/siglip2-v1", indexType: "vision_dense", dimension: 768))
        try await repo.commit(
            memory: Memory(memoryId: memID, sourceLocator: locator, canonicalText: nil, sourceType: "photo"),
            representations: [Representation(representationId: memID, memoryId: memID, modality: .visionDense, preprocessVersion: "siglip2-v1", contentHash: "h")],
            vectorsByGeneration: ["vision_dense/siglip2-v1": [CanonicalVectorEntry(id: memID, vector: Array(repeating: 0.25, count: 768))]],
            traceID: "t-wp6-seed"
        )
        _ = try await migration.migratePhoto(memoryId: memID, shadowGenerationID: shadowID, taskID: "t-wp6-1g", traceID: "t-wp6-1g")

        // 取消
        let afterCancel = await migration.cancelPhotoMigration(traceID: "t-wp6-1g")

        // 活跃路由 digest 不变
        let after = try await registry.loadActiveRoute()
        let afterSnapshot = after.flatMap { "active-v\($0.version)-\($0.textGeneration)" }
        #expect(afterSnapshot == beforeSnapshot, "cancellation must not publish or alter the active route")

        // 进度保留（processedCount == 1，phase 保持 shadowBuilding 可恢复）
        #expect(afterCancel.phase == .shadowBuilding)
        #expect(afterCancel.processedCount == 1, "cancellation must preserve processed progress")
        #expect(afterCancel.lastProcessedLocator == locator)
    }
}

// MARK: - WP6 步骤 2c-2d：歧义/orphan 向量阻断路由发布验证

extension PhotoTextSearchMigrationTests {

    @Test("Orphan legacy vector blocks route publication validation (WP6 step 2c/2d)")
    func testAmbiguousLegacyVectorBlocksPublication() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let registry = GenerationRegistryActor(db: db)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let migration = PhotoSearchMigrationActor(
            generationRegistry: registry,
            canonicalRepository: repo,
            visionEmbedder: WP6MigrationEmbedder(),
            photoExtractor: WP6StubPhotoExtractor(imageData: Data([0x89, 0x50, 0x4E, 0x47]))
        )

        _ = try await Self.seedActiveRoute(db: db, registry: registry)
        let st = try await migration.startPhotoShadowBuild(traceID: "t-wp6-2c")
        guard let shadowID = st.shadowGenerationID else { return }

        // 创建一张真实 photo memory（正常映射路径）
        try await registry.registerGeneration(IndexGeneration(generationId: "vision_dense/siglip2-v1", indexType: "vision_dense", dimension: 768))
        let locB = "PHAsset/wp6-amb-b-\(UUID().uuidString)"
        let memB = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: locB, sourceType: "photo")
        try await repo.commit(
            memory: Memory(memoryId: memB, sourceLocator: locB, canonicalText: nil, sourceType: "photo"),
            representations: [Representation(representationId: memB, memoryId: memB, modality: .visionDense, preprocessVersion: "siglip2-v1", contentHash: "h")],
            vectorsByGeneration: ["vision_dense/siglip2-v1": [CanonicalVectorEntry(id: memB, vector: Array(repeating: 0.25, count: 768))]],
            traceID: "t-wp6-seed"
        )

        guard let store = await registry.vectorStore(for: shadowID) else {
            Issue.record("shadow store unavailable")
            return
        }
        // 正常映射向量（id == memB，photoRepresentationID 恒等）
        try await store.ingest(vector: Array(repeating: 0.5, count: 768), id: memB, metadata: nil)
        #expect(try await migration.validateShadowGeneration(generationID: shadowID, traceID: "t-wp6-2c"),
                "fully mapped shadow must pass validation")

        // orphan 向量（无 Representation 行）——fail-closed 阻断（迁移算法 I.1）
        let orphan = UUID()
        try await store.ingest(vector: Array(repeating: 0.4, count: 768), id: orphan, metadata: nil)
        let valid = try await migration.validateShadowGeneration(generationID: shadowID, traceID: "t-wp6-2c")
        #expect(valid == false, "orphan vector must fail route publication validation")
    }
}

// MARK: - WP6 步骤 8a-8b：consent purge 清理 deletion journals

extension PhotoTextSearchMigrationTests {

    @Test("Consent purge clears deletion journals (WP6 step 8a/8b)")
    func testConsentPurgeClearsDeletionJournals() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let registry = GenerationRegistryActor(db: db)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)

        let memID = UUID()
        try await db.upsertDeletionJournal(MemoryDeletionJournal(
            operationID: "j-wp6-8a",
            memoryID: memID,
            auditSubjectHash: "h-8a",
            traceID: "t-wp6-8a",
            phase: .planned,
            vectorIDsByGeneration: []
        ))

        try await repo.purgeEverythingForConsent()

        let remaining = try await db.loadDeletionJournals(memoryId: memID)
        #expect(remaining.isEmpty, "consent purge must clear deletion journals (WP6 step 8a/8b)")
    }
}

// MARK: - WP6 步骤 4a/4c 前置：canonical route bytes 与 digest 确定性

extension PhotoTextSearchMigrationTests {

    nonisolated private static func makeRouteSnapshot() throws -> SearchRouteSnapshot {
        let policy = try FusionPolicySnapshot(
            policyID: "p-wp6",
            weights: [ChannelWeight(channel: .textDense, weight: 1.0)],
            rrfK: 60
        )
        return try SearchRouteSnapshot(
            snapshotID: "wp6-snap-1",
            schemaVersion: 1,
            routeVersion: 1,
            channels: [ChannelRoute(
                channel: .textDense,
                generationID: "text_dense/e5-v1",
                indexManifestID: nil,
                queryModelManifestID: nil,
                dimension: 384,
                alignmentSpaceID: nil,
                required: true
            )],
            fusion: policy,
            previousSnapshotID: nil,
            publishedAtEpochMilliseconds: 123,
            validationDigest: "placeholder"
        )
    }

    @Test("Canonical route bytes and digest are deterministic across calls (WP6 step 4a/4c 前置)")
    func testCanonicalRouteBytesAreDeterministic() throws {
        let route = try Self.makeRouteSnapshot()
        let bytes1 = try route.canonicalData()
        let bytes2 = try route.canonicalData()
        #expect(bytes1 == bytes2, "canonical bytes must be deterministic for persisted digest validation")
        let d1 = try route.computedDigest()
        let d2 = try route.computedDigest()
        #expect(d1 == d2, "digest must be stable")
        #expect(d1.count == 64, "digest must be SHA-256 hex")
    }
}

// MARK: - WP6 步骤 4a-4d：canonical bytes 持久化 + digest 校验

extension PhotoTextSearchMigrationTests {

    @Test("Publication persists canonical route bytes with matching digest (WP6 step 4a/4b)")
    func testPublicationPersistsCanonicalRouteBytes() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let registry = GenerationRegistryActor(db: db)
        let migration = PhotoSearchMigrationActor(db: db, generationRegistry: registry)
        let snapshot = try Self.makeRouteSnapshot()

        try await migration.publishRouteSnapshot(snapshot, traceID: "t-wp6-4a")

        let loaded = try await db.loadRouteSnapshot(snapshotID: snapshot.snapshotID)
        #expect(loaded != nil, "canonical route bytes must be persisted")
        #expect(loaded?.bytes == (try snapshot.canonicalData()))
        #expect(loaded?.digest == (try snapshot.computedDigest()))
    }

    @Test("Publication rejects digest mismatch without changing active route (WP6 step 4c/4d)")
    func testPublicationRejectsDigestMismatch() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let registry = GenerationRegistryActor(db: db)
        let migration = PhotoSearchMigrationActor(db: db, generationRegistry: registry)

        let v1 = try Self.makeRouteSnapshot()
        try await migration.publishRouteSnapshot(v1, traceID: "t-wp6-4c")
        let before = try await registry.loadActiveRoute()

        // 同 snapshotID、不同融合权重 → canonical bytes 不同 → digest 不一致
        let policy2 = try FusionPolicySnapshot(
            policyID: "p-wp6",
            weights: [ChannelWeight(channel: .textDense, weight: 0.5)],
            rrfK: 60
        )
        let v2 = try SearchRouteSnapshot(
            snapshotID: v1.snapshotID,
            schemaVersion: 1,
            routeVersion: 1,
            channels: v1.channels,
            fusion: policy2,
            previousSnapshotID: nil,
            publishedAtEpochMilliseconds: 123,
            validationDigest: "placeholder"
        )
        await #expect(throws: PhotoSearchMigrationError.digestMismatch) {
            try await migration.publishRouteSnapshot(v2, traceID: "t-wp6-4c")
        }
        // 持久化记录保持 v1 原样
        let loaded = try await db.loadRouteSnapshot(snapshotID: v1.snapshotID)
        #expect(loaded?.digest == (try v1.computedDigest()), "first persisted digest must be untouched")
        // 活跃路由不受影响
        let after = try await registry.loadActiveRoute()
        #expect(after?.textGeneration == before?.textGeneration)
    }
}

// MARK: - WP6 步骤 4e-4f：原子路由发布（单事务四通道同时可见）

extension PhotoTextSearchMigrationTests {

    @Test("Route publication makes all channels visible together in one transaction (WP6 step 4e/4f)")
    func testRouteTransactionPublishesAllChannelsTogether() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let registry = GenerationRegistryActor(db: db)

        // 注册四通道 generation 并激活
        let suffix = UUID().uuidString.prefix(6)
        let gens = [
            ("text_dense/e5-v1-\(suffix)", "text_dense", 384),
            ("vision_dense/siglip2-v1-\(suffix)", "vision_dense", 768),
            ("ocr_text/e5-v1-\(suffix)", "ocr_text", 384),
            ("lexical/f5-\(suffix)", "lexical", 384),
        ]
        for (genId, indexType, dim) in gens {
            try await registry.registerGeneration(IndexGeneration(generationId: genId, indexType: indexType, dimension: dim))
            try await registry.setGenerationState(genId, state: .ready)
            try await registry.setGenerationState(genId, state: .active)
        }

        let activated = try await registry.activateGeneration(gens[0].0)
        try await registry.publishRoute(ActiveRouteSet(
            textGeneration: gens[0].0,
            ocrGeneration: gens[2].0,
            visionGeneration: gens[1].0,
            lexicalGeneration: gens[3].0,
            version: activated.version
        ))

        // 单事务发布后四通道同时可见（全部来自同一次 commit，无部分发布）
        let route = try await registry.loadActiveRoute()
        #expect(route?.textGeneration == gens[0].0)
        #expect(route?.visionGeneration == gens[1].0)
        #expect(route?.ocrGeneration == gens[2].0)
        #expect(route?.lexicalGeneration == gens[3].0)
        #expect(route?.version == activated.version)
    }
}

// MARK: - WP6 步骤 5a：重启恢复 canonical digest

extension PhotoTextSearchMigrationTests {

    @Test("Restart restores canonical route digest unchanged (WP6 step 5a)")
    func testRestartRestoresCanonicalRouteDigest() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let snapshot = try Self.makeRouteSnapshot()

        // 第一生命周期：发布持久化
        let migration1 = PhotoSearchMigrationActor(
            db: db, generationRegistry: GenerationRegistryActor(db: db)
        )
        try await migration1.publishRouteSnapshot(snapshot, traceID: "t-wp6-5a")

        // 模拟重启：全新实例从同一持久化 DB 重读
        _ = PhotoSearchMigrationActor(db: db, generationRegistry: GenerationRegistryActor(db: db))
        let loaded = try await db.loadRouteSnapshot(snapshotID: snapshot.snapshotID)
        #expect(loaded != nil, "persisted route snapshot must survive restart")
        #expect(loaded?.digest == (try snapshot.computedDigest()),
                "canonical digest must be identical after restart")
        #expect(loaded?.bytes == (try snapshot.canonicalData()),
                "canonical bytes must be identical after restart")
    }
}

// MARK: - WP6 步骤 6a-6b：路由发布后检索缓存失效

extension PhotoTextSearchMigrationTests {

    @Test("Route migration invalidates all search cache entries (WP6 step 6a/6b)")
    func testRouteMigrationInvalidatesAllSearchCacheEntries() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let cache = SearchResultCacheActor()
        let migration = PhotoSearchMigrationActor(
            db: db,
            generationRegistry: GenerationRegistryActor(db: db),
            cache: cache
        )

        // 发布前写入两条缓存（旧路由身份）
        let keyA = SearchCacheKey(policyVersion: 1, modelVersion: "m", queryHash: "q-a", routeSnapshotID: "old-route")
        let keyB = SearchCacheKey(policyVersion: 1, modelVersion: "m", queryHash: "q-b", routeSnapshotID: "old-route")
        try await cache.store(key: keyA, result: CachedSearchResult(items: []))
        try await cache.store(key: keyB, result: CachedSearchResult(items: []))

        // 发布新路由快照
        let snapshot = try Self.makeRouteSnapshot()
        try await migration.publishRouteSnapshot(snapshot, traceID: "t-wp6-6a")

        #expect(try await cache.lookup(key: keyA) == nil, "cache must be fully invalidated after route migration")
        #expect(try await cache.lookup(key: keyB) == nil)
    }
}
