// ==========================================
// 文件: 3F.7_UIToCoreIntegrationTests.swift
// 对应规格: docs/05-planning/phase3f-execution-plan.md → 3F.7 (UI 到 Core 全域接线)
//            docs/ui/architecture.md §7 (适配器契约), AGENTS.md §17.4 (Core 只读消费)
// 任务: 3F.7 - UI 到 Core 全域接线
// AC 覆盖: 默认 live adapter（无 fixture fallback）、真实设置值（live DataOverview）、
//          SearchViewModel 默认 live pipeline、跨 surface journey（settings→search→migration）
// 架构约束: AGENTS.md §8.1 (@MainActor @Observable 薄适配器), §9.4 (串行执行)
// 重要: TDD — 验证 ViewModel 默认构造解析 live Core 依赖（无 fixture 占位）。
// 生成时间: 2026-08-11
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Suite: UI to Core Integration (3F.7)

@Suite("UIToCoreIntegrationTests", .serialized)
@MainActor
struct UIToCoreIntegrationTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await UIToCoreIntegrationTests.wipeWiringTables()
    }

    private static func wipeWiringTables() async throws {
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

    private func seedMemory(locator: String, sourceType: String, text: String?) async throws {
        try await db.executeWrite(
            sql: """
            INSERT OR REPLACE INTO Memory (memoryId, sourceLocator, canonicalText, sourceType, createdAt, updatedAt, recoverability, originalTimestamp, userEdited, userLocked)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(UUID().uuidString),
                .text(locator),
                text.map(DBBinding.text) ?? .null,
                .text(sourceType),
                .double(Date().timeIntervalSince1970),
                .double(Date().timeIntervalSince1970),
                .text("full"),
                .null,
                .int(0),
                .int(0),
            ]
        )
    }

    // MARK: - 默认 live adapter（无 fixture fallback）

    @Test("3F.7: LiveAppAdapters.makeDataOverviewService returns live service over shared DB")
    func test_LiveDataOverviewService() async throws {
        try await seedMemory(locator: "photo-1", sourceType: "photo", text: nil)
        let service = LiveAppAdapters.makeDataOverviewService()
        let snap = try await service.snapshot()
        #expect(snap.memoryCount == 1)
        #expect(snap.databaseBytes > 0)
    }

    @Test("3F.7: SettingsViewModel default construction wires live DataOverview (no fixture fabricated counts)")
    func test_Settings_LiveCounts() async throws {
        try await seedMemory(locator: "photo-1", sourceType: "photo", text: nil)
        try await seedMemory(locator: "note-1", sourceType: "note", text: "note")
        try await seedMemory(locator: "voice-1", sourceType: "voice", text: "voice")

        let vm = SettingsViewModel(
            composition: AppComposition.shared,
            dataOverviewService: LiveAppAdapters.makeDataOverviewService()
        )
        await vm.loadSettings()
        guard case .completed(let sections) = vm.state else {
            Issue.record("Expected .completed, got \(vm.state)")
            return
        }
        // live 值来自 Memory 表（非 fixture 的 1247/42.3MB 占位）
        #expect(sections.storage.indexCount == 3)
        #expect(sections.modelStatus.totalModels == ModelLoaderActor.ModelType.allCases.count)
    }

    @Test("3F.7: SearchViewModel default construction resolves live pipeline via composition")
    func test_Search_DefaultLivePipeline() async throws {
        let vm = SearchViewModel(composition: AppComposition.shared)
        #expect(vm.viewState == .idle)
        // 空查询不触发搜索
        vm.submitQuery("   ")
        #expect(vm.viewState == .idle)
    }

    // MARK: - 默认 live 接线回归修复（PR#59 审查）

    private func seedActiveTextRoute() async throws -> GenerationRegistryActor {
        let registry = GenerationRegistryActor(db: db)
        try await registry.registerGeneration(
            IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384)
        )
        try await registry.finishShadowBuild("text_dense/e5-v1", counts: 0, validationDigest: nil)
        try await registry.setGenerationState("text_dense/e5-v1", state: .ready)
        let route = try await registry.activateGeneration("text_dense/e5-v1")
        try await registry.publishRoute(ActiveRouteSet(textGeneration: route.textGeneration, version: route.version))
        return registry
    }

    private func seedSearchPolicy() async throws {
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
    }

    private func makeTestComposition(registry: GenerationRegistryActor) -> AppComposition {
        AppComposition(
            databaseManager: db,
            generationRegistry: registry,
            textEmbedder: MigrationTestEmbedder(),
            visionEmbedder: MigrationTestEmbedder(),
            asrEngine: nil
        )
    }

    private func awaitSearchCompletion(_ vm: SearchViewModel, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .completed = vm.viewState { return }
            if case .error = vm.viewState { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Search did not reach terminal state: \(vm.viewState)")
    }

    @Test("3F.7: live pipeline reused across searches → follow-up audit fires (US-RET-005, 🟡-2 fix)")
    func test_Search_LiveFollowUpReusesPipeline() async throws {
        let registry = try await seedActiveTextRoute()
        try await seedSearchPolicy()
        let vm = SearchViewModel(composition: makeTestComposition(registry: registry))

        vm.submitQuery("follow up test")
        await awaitSearchCompletion(vm)
        let firstPipeline = vm.resolvedPipeline
        #expect(firstPipeline != nil, "live pipeline must be resolved and cached")

        vm.submitQuery("follow up test")
        await awaitSearchCompletion(vm)
        #expect(vm.resolvedPipeline === firstPipeline, "same SearchPipeline instance must be reused (🟡-2)")

        // 行为断言：同一实例上重复查询触发 .followUpQuery 审计（US-RET-005 AC-4）
        let entries = try await PrivacyActor.shared.fetchAuditLogs(limit: 50, eventType: .followUpQuery)
        #expect(entries.count >= 1, "repeated query on reused pipeline must write follow-up audit")
    }

    @Test("3F.7: live feedback intent persists to FeedbackStore (US-FBK-001, 🟡-3 fix)")
    func test_Search_LiveFeedbackPersists() async throws {
        let registry = try await seedActiveTextRoute()
        let vm = SearchViewModel(composition: makeTestComposition(registry: registry))

        vm.submitQuery("feedback query")
        await awaitSearchCompletion(vm)

        let memoryID = UUID()
        let item = SearchResultItem(
            id: memoryID,
            assetId: "note-fb-1",
            sourceType: "note",
            timestamp: Date().timeIntervalSince1970,
            originalText: "feedback note",
            cosineSimilarity: 0.9
        )
        vm.recordLike(SearchResultModel(from: item))

        // recordLike 经 Task 异步转发至 FeedbackPipeline → FeedbackActor；轮询等待落库
        let deadline = Date().addingTimeInterval(5)
        var persisted = 0
        while Date() < deadline {
            persisted = try await FeedbackActor.shared.count()
            if persisted >= 1 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(persisted >= 1, "live feedback intent must persist to FeedbackStore (US-FBK-001, 🟡-3)")
    }

    @Test("3F.7: no active route → explicit route-unavailable, not silent empty store (US-RET-008, 🟡-4 fix)")
    func test_Search_NoRouteIsExplicitError() async throws {
        let registry = GenerationRegistryActor(db: db)
        let vm = SearchViewModel(composition: makeTestComposition(registry: registry))
        vm.submitQuery("no route query")
        await awaitSearchCompletion(vm)
        guard case .error = vm.viewState else {
            Issue.record("Expected .error route-unavailable, got \(vm.viewState)")
            return
        }
    }

    // MARK: - 跨 surface journey

    @Test("3F.7: settings → data overview → JSON export journey")
    func test_Journey_SettingsToExport() async throws {
        try await seedMemory(locator: "note-journey", sourceType: "note", text: "journey note")
        let service = LiveAppAdapters.makeDataOverviewService()
        let json = try await service.exportJSON()
        #expect(json.contains("memoryCount"))
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect((parsed?["memoryCount"] as? NSNumber)?.intValue == 1)
    }

    @Test("3F.7: migration package round-trip through live actor")
    func test_Journey_MigrationRoundTrip() async throws {
        // 注册活跃 text generation（迁移导入需要）
        let registry = GenerationRegistryActor(db: db)
        try await registry.registerGeneration(
            IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384)
        )
        try await registry.finishShadowBuild("text_dense/e5-v1", counts: 0, validationDigest: nil)
        try await registry.setGenerationState("text_dense/e5-v1", state: .ready)
        let route = try await registry.activateGeneration("text_dense/e5-v1")
        try await registry.publishRoute(ActiveRouteSet(textGeneration: route.textGeneration, version: route.version))

        let actor = DeviceMigrationActor(
            db: db,
            canonicalRepository: CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry),
            generationRegistry: registry,
            textEmbedder: MigrationTestEmbedder()
        )
        try await seedMemory(locator: "note-mig", sourceType: "note", text: "migration test")
        let (package, key) = try await actor.exportPackage()
        // 清空后导入
        try await db.execute(sql: "DELETE FROM MemoryFTS")
        try await db.execute(sql: "DELETE FROM Representation")
        try await db.execute(sql: "DELETE FROM Memory")

        let result = try await actor.importPackage(
            package: package,
            transferKey: key,
            strategy: .overwrite,
            fromDevice: "iPhone-A",
            toDevice: "iPhone-B"
        )
        #expect(result.integrityCheckPassed)
        #expect(result.memoryCount == 1)
    }
}
