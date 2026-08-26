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
