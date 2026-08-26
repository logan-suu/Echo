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

    nonisolated private static func seedActiveRoute(db: DatabaseManager, registry: GenerationRegistryActor) async throws -> String {
        let genId = "text_dense/e5-v1-\(UUID().uuidString.prefix(6))"
        try await registry.registerGeneration(IndexGeneration(generationId: genId, indexType: "text_dense", dimension: 384))
        try await registry.setGenerationState(genId, state: .ready)
        try await registry.setGenerationState(genId, state: .active)
        let published = try await registry.activateGeneration(genId)
        try await registry.publishRoute(ActiveRouteSet(textGeneration: published.textGeneration, version: published.version))
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
