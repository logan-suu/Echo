// ==========================================
// 文件: RA_GenerationRegistryTests.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-A.3 (IndexGeneration) + R-A.4 (ActiveRouteSet)
// 任务: R-A.3/R-A.4 - 分代索引管理 + 原子服务路由
// AC 覆盖: registerGeneration, setGenerationState, buildItem CRUD,
//          publishRoute 验证, validateRoute, fallbackRoute, 混代禁止
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007/R-008
// 生成时间: 2026-07-31
// ==========================================

import Testing
import Foundation
@testable import Echo

@Suite("R-A.3 GenerationRegistry", .serialized)
struct GenerationRegistryTests {

    let sut = GenerationRegistryActor.shared
    let manifestActor = ModelManifestActor.shared
    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
        // Clean up R-A tables for a fresh state
        try await db.execute(sql: "DELETE FROM ActiveRouteSet")
        try await db.execute(sql: "DELETE FROM IndexBuildItem")
        try await db.execute(sql: "DELETE FROM IndexGeneration")
        try await db.execute(sql: "DELETE FROM ModelManifest")
    }

    @Test("registerGeneration persists metadata and creates vector store instance")
    func test_register_generation() async throws {
        let gen = IndexGeneration(
            generationId: "text_dense/e5-v1",
            indexType: "text_dense",
            manifestId: "e5-small-v1"
        )
        try await sut.registerGeneration(gen)

        let loaded = try await sut.loadGeneration("text_dense/e5-v1")
        #expect(loaded != nil)
        #expect(loaded?.indexType == "text_dense")
        #expect(loaded?.state == .building)

        let store = await sut.vectorStore(for: "text_dense/e5-v1")
        #expect(store != nil)
    }

    @Test("registerGeneration is idempotent for same generationId")
    func test_register_idempotent() async throws {
        try await sut.registerGeneration(
            IndexGeneration(generationId: "g1", indexType: "text_dense")
        )
        try await sut.registerGeneration(
            IndexGeneration(generationId: "g1", indexType: "text_dense")
        )
        #expect(try await sut.loadGenerations().count == 1)
    }

    @Test("setGenerationState transitions building → ready → active")
    func test_setState_transitions() async throws {
        try await sut.registerGeneration(
            IndexGeneration(generationId: "g-state", indexType: "text_dense")
        )
        try await sut.setGenerationState("g-state", state: .ready, counts: 42, validationDigest: "digest-1")
        let ready = try await sut.loadGeneration("g-state")
        #expect(ready?.state == .ready)
        #expect(ready?.counts == 42)
        #expect(ready?.validationDigest == "digest-1")

        try await sut.setGenerationState("g-state", state: .active)
        let active = try await sut.loadGeneration("g-state")
        #expect(active?.state == .active)
    }

    @Test("setGenerationState rejects illegal transition building → retired")
    func test_setState_rejects_illegal_transition() async throws {
        try await sut.registerGeneration(
            IndexGeneration(generationId: "g-illegal", indexType: "text_dense")
        )
        do {
            try await sut.setGenerationState("g-illegal", state: .retired)
            #expect(Bool(false), "Expected illegalStateTransition")
        } catch let error as Echo.GenerationError {
            if case .illegalStateTransition(let from, let to) = error {
                #expect(from == .building)
                #expect(to == .retired)
            } else {
                #expect(Bool(false), "Wrong error: \(error)")
            }
        }
    }

    @Test("isLegalTransition allows building → ready, rejects building → retired")
    func test_isLegalTransition_table() {
        #expect(GenerationState.ready.isLegalTransition(from: .building))
        #expect(GenerationState.active.isLegalTransition(from: .ready))
        #expect(GenerationState.retired.isLegalTransition(from: .active))
        #expect(!GenerationState.retired.isLegalTransition(from: .building))
        #expect(!GenerationState.building.isLegalTransition(from: .active))
        #expect(!GenerationState.active.isLegalTransition(from: .retired))
    }

    @Test("upsertBuildItem and updateBuildItem track build progress")
    func test_buildItem_lifecycle() async throws {
        // Register parent generation first (FK constraint on IndexBuildItem.generationId)
        try await sut.registerGeneration(
            IndexGeneration(generationId: "g-build", indexType: "text_dense")
        )
        let item = IndexBuildItem(
            generationId: "g-build",
            representationId: "rep-1"
        )
        try await sut.upsertBuildItem(item)

        try await sut.updateBuildItem(
            generationId: "g-build",
            representationId: "rep-1",
            state: "done"
        )
        let items = try await sut.loadBuildItems(generationId: "g-build")
        #expect(items.count == 1)
        #expect(items[0].state == "done")
        #expect(try await sut.completedCount(for: "g-build") == 1)
    }

    @Test("updateBuildItem retry increments retryCount")
    func test_buildItem_retry() async throws {
        // Register parent generation first (FK constraint)
        try await sut.registerGeneration(
            IndexGeneration(generationId: "g-retry", indexType: "text_dense")
        )
        try await sut.upsertBuildItem(IndexBuildItem(generationId: "g-retry", representationId: "r1"))
        try await sut.updateBuildItem(
            generationId: "g-retry",
            representationId: "r1",
            state: "failed",
            error: "timeout",
            retryIncrement: true
        )
        let items = try await sut.loadBuildItems(generationId: "g-retry")
        #expect(items[0].retryCount == 1)
        #expect(items[0].error == "timeout")
    }
}

@Suite("R-A.4 ActiveRouteSet", .serialized)
struct ActiveRouteSetTests {

    let sut = GenerationRegistryActor.shared
    let manifestActor = ModelManifestActor.shared
    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM ActiveRouteSet")
        try await db.execute(sql: "DELETE FROM IndexBuildItem")
        try await db.execute(sql: "DELETE FROM IndexGeneration")
        try await db.execute(sql: "DELETE FROM ModelManifest")
    }

    private func seedActiveGeneration(_ id: String = "text_dense/e5-v1") async throws {
        try await sut.registerGeneration(
            IndexGeneration(generationId: id, indexType: "text_dense")
        )
        try await sut.setGenerationState(id, state: .ready)
        try await sut.setGenerationState(id, state: .active)
    }

    @Test("publishRoute persists route after validation")
    func test_publish_route() async throws {
        try await seedActiveGeneration()
        let route = ActiveRouteSet(
            textGeneration: "text_dense/e5-v1",
            version: 1
        )
        try await sut.publishRoute(route)

        let loaded = try await sut.loadActiveRoute()
        #expect(loaded != nil)
        #expect(loaded?.textGeneration == "text_dense/e5-v1")
        #expect(loaded?.version == 1)
    }

    @Test("publishRoute throws when generation is missing")
    func test_publish_missing_generation_throws() async throws {
        let route = ActiveRouteSet(textGeneration: "nonexistent-gen")
        do {
            try await sut.publishRoute(route)
            #expect(Bool(false), "Expected routeValidationFailed")
        } catch let error as Echo.GenerationError {
            if case .routeValidationFailed = error {
                // expected
            } else {
                #expect(Bool(false), "Wrong error: \(error)")
            }
        }
    }

    @Test("publishRoute throws when generation is still building")
    func test_publish_building_generation_throws() async throws {
        try await sut.registerGeneration(
            IndexGeneration(generationId: "building-gen", indexType: "text_dense")
        )
        let route = ActiveRouteSet(textGeneration: "building-gen")
        do {
            try await sut.publishRoute(route)
            #expect(Bool(false), "Expected routeValidationFailed")
        } catch {
            #expect(error is Echo.GenerationError)
        }
    }

    @Test("validateRoute returns false for missing generation, true for valid")
    func test_validateRoute() async throws {
        try await seedActiveGeneration()

        let valid = ActiveRouteSet(textGeneration: "text_dense/e5-v1")
        #expect(try await sut.validateRoute(valid) == true)

        let invalid = ActiveRouteSet(textGeneration: "missing-gen")
        #expect(try await sut.validateRoute(invalid) == false)
    }

    @Test("validateRoute rejects manifest dimension mismatch (W-1)")
    func test_validateRoute_dimension_mismatch() async throws {
        // Register generation with dimension 384 (E5)
        try await sut.registerGeneration(
            IndexGeneration(
                generationId: "text_dense/e5-v2",
                indexType: "text_dense",
                manifestId: "e5-small-v1",
                dimension: 384
            )
        )
        try await sut.setGenerationState("text_dense/e5-v2", state: .ready)
        try await sut.setGenerationState("text_dense/e5-v2", state: .active)

        // Register manifest with mismatched dimension 512
        try await manifestActor.register(
            ModelManifest(
                modelId: "e5-small-v1",
                revision: "rev",
                artifactHash: "hash",
                licenseId: "license",
                runtime: .coreML,
                dimension: 512
            )
        )

        let route = ActiveRouteSet(textGeneration: "text_dense/e5-v2")
        #expect(try await sut.validateRoute(route) == false)
    }

    @Test("validateRoute accepts matching manifest dimension")
    func test_validateRoute_dimension_match() async throws {
        try await sut.registerGeneration(
            IndexGeneration(
                generationId: "text_dense/e5-v3",
                indexType: "text_dense",
                manifestId: "e5-small-v1",
                dimension: 384
            )
        )
        try await sut.setGenerationState("text_dense/e5-v3", state: .ready)
        try await sut.setGenerationState("text_dense/e5-v3", state: .active)

        try await manifestActor.register(
            ModelManifest(
                modelId: "e5-small-v1",
                revision: "rev",
                artifactHash: "hash",
                licenseId: "license",
                runtime: .coreML,
                dimension: 384
            )
        )

        let route = ActiveRouteSet(textGeneration: "text_dense/e5-v3")
        #expect(try await sut.validateRoute(route) == true)
    }

    @Test("fallbackRoute returns nil when no active generation exists")
    func test_fallback_nil_when_no_active() async throws {
        let fallback = try await sut.fallbackRoute()
        #expect(fallback == nil)
    }

    @Test("fallbackRoute returns active text generation when current route invalid")
    func test_fallback_returns_active() async throws {
        try await seedActiveGeneration()
        let fallback = try await sut.fallbackRoute()
        #expect(fallback != nil)
        #expect(fallback?.textGeneration == "text_dense/e5-v1")
    }

    @Test("route version increments on re-publish")
    func test_publish_version_increment() async throws {
        try await seedActiveGeneration()
        try await sut.publishRoute(ActiveRouteSet(textGeneration: "text_dense/e5-v1", version: 1))
        try await sut.publishRoute(ActiveRouteSet(textGeneration: "text_dense/e5-v1", version: 2))
        let loaded = try await sut.loadActiveRoute()
        #expect(loaded?.version == 2)
    }

    // MARK: - 3F.4: Generation Lifecycle (ADR-010 决策-2/3)

    @Test("finishShadowBuild sets building generation to ready (3F.4)")
    func test_finishShadowBuild_ready() async throws {
        try await sut.registerGeneration(
            IndexGeneration(generationId: "g-shadow", indexType: "text_dense", dimension: 384)
        )
        try await sut.finishShadowBuild("g-shadow", counts: 7, validationDigest: "digest")
        let loaded = try await sut.loadGeneration("g-shadow")
        #expect(loaded?.state == .ready)
        #expect(loaded?.counts == 7)
        #expect(loaded?.validationDigest == "digest")
    }

    @Test("activateGeneration rejects a building generation (no mixed route) (3F.4)")
    func test_activate_rejects_building() async throws {
        try await sut.registerGeneration(
            IndexGeneration(generationId: "g-not-ready", indexType: "text_dense", dimension: 384)
        )
        do {
            _ = try await sut.activateGeneration("g-not-ready")
            #expect(Bool(false), "Expected routeValidationFailed")
        } catch let error as Echo.GenerationError {
            if case .routeValidationFailed = error {
                // expected
            } else {
                #expect(Bool(false), "Wrong error: \(error)")
            }
        }
    }

    @Test("activateGeneration publishes route with previousTextGeneration (3F.4)")
    func test_activate_tracks_previous() async throws {
        try await sut.registerGeneration(
            IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384)
        )
        try await sut.finishShadowBuild("text_dense/e5-v1", counts: 1, validationDigest: "d1")
        let route1 = try await sut.activateGeneration("text_dense/e5-v1")
        #expect(route1.version == 1)
        #expect(route1.previousTextGeneration == nil)

        try await sut.registerGeneration(
            IndexGeneration(generationId: "text_dense/e5-v2", indexType: "text_dense", dimension: 384)
        )
        try await sut.finishShadowBuild("text_dense/e5-v2", counts: 1, validationDigest: "d2")
        let route2 = try await sut.activateGeneration("text_dense/e5-v2")
        #expect(route2.version == 2)
        #expect(route2.previousTextGeneration == "text_dense/e5-v1")
    }

    @Test("rollbackToPrevious restores prior active generation (3F.4)")
    func test_rollback_restores_previous() async throws {
        try await sut.registerGeneration(
            IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384)
        )
        try await sut.finishShadowBuild("text_dense/e5-v1", counts: 1, validationDigest: "d1")
        _ = try await sut.activateGeneration("text_dense/e5-v1")

        try await sut.registerGeneration(
            IndexGeneration(generationId: "text_dense/e5-v2", indexType: "text_dense", dimension: 384)
        )
        try await sut.finishShadowBuild("text_dense/e5-v2", counts: 1, validationDigest: "d2")
        _ = try await sut.activateGeneration("text_dense/e5-v2")

        let rolled = try await sut.rollbackToPrevious()
        #expect(rolled != nil)
        #expect(rolled?.textGeneration == "text_dense/e5-v1")

        let loaded = try await sut.loadActiveRoute()
        #expect(loaded?.textGeneration == "text_dense/e5-v1")
    }

    @Test("rollbackToPrevious returns nil when no previous exists (3F.4)")
    func test_rollback_nil_without_previous() async throws {
        try await sut.registerGeneration(
            IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384)
        )
        try await sut.finishShadowBuild("text_dense/e5-v1", counts: 1, validationDigest: "d1")
        _ = try await sut.activateGeneration("text_dense/e5-v1")

        let rolled = try await sut.rollbackToPrevious()
        #expect(rolled == nil)
    }

    @Test("restoreActiveRoute returns nil when no route persisted (3F.4)")
    func test_restore_nil_without_route() async throws {
        let fresh = GenerationRegistryActor(db: db)
        let restored = try await fresh.restoreActiveRoute()
        #expect(restored == nil)
    }
}
