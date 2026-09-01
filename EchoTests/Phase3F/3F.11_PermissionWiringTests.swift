// ==========================================
// 文件: 3F.11_PermissionWiringTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-001 AC-3 (照片授权请求)/AC-5 (.dataSourceConnected),
//            US-SRC-012 (相册变更同步/首次全量导入), US-AWK-001 AC-4 (通知授权前置)
//            docs/decisions/ADR-008-source-import-boundaries.md §决策-1/决策-5, ADR-012 决策-2/3
// 任务: 3F.11 修复 — 生产权限接线（Live Review 发现：无照片权限请求入口 + 无首次全量导入触发
//      + AwakeningSettingsViewModel.requestNotificationPermission 为 stub）
// AC 覆盖: 首次全量导入仅取本地资产 + 排除项 fail-closed + PrivacyCheckpoint 拒绝返回空结果
//          + .dataSourceConnected 审计 + Settings 授权入口状态流转 + 通知真实授权（live/denied/fallback）
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-006 (PrivacyCheckpoint), §4.4 (L1~L4)
// 生成时间: 2026-08-14
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Test Fakes

/// 本套件专用假照片库 — 模拟 PhotoKit 授权/资产状态（真实实现 RealPhotoLibrary）。
private struct WiringFakePhotoLibrary: PhotoLibraryServing {
    let access: PhotoAccess
    let assets: [PhotoAssetReference]
    let downloaded: Set<String>

    func currentAccess() async -> PhotoAccess { access }
    func requestAccess() async -> PhotoAccess { access }
    func allAssetReferences() async -> [PhotoAssetReference] {
        (access == .denied || access == .notDetermined) ? [] : assets
    }
    func isAssetDownloaded(_ assetId: String) async -> Bool { downloaded.contains(assetId) }
}

// MARK: - Test Suite: Permission Wiring (3F.11 fix)

@Suite("PermissionWiringTests", .serialized)
@MainActor
struct PermissionWiringTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await PermissionWiringTests.wipeCanonicalTables()
        await PrivacyActor.shared.disableConsentEnforcement()
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

    // MARK: - Helpers

    private func makeRegistry() -> GenerationRegistryActor {
        GenerationRegistryActor(db: db)
    }

    /// 注册并激活 text + vision 两个 generation（ADR-010 路由），返回活跃路由。
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

    /// 构造生产式 SyncPipeline（canonical + generation 路由，与 AppDelegate 装配一致）。
    private func makeSync(
        registry: GenerationRegistryActor,
        privacy: PrivacyActor
    ) -> SyncPipeline {
        SyncPipeline(
            embedder: ProductionTestEmbedder(),
            privacyActor: privacy,
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: ExcludedAssetsActor(db: db, privacyActor: privacy),
            progressActor: .shared,
            canonicalRepository: CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry),
            generationRegistry: registry
        )
    }

    private func makeAdapter(
        access: PhotoAccess,
        assets: [PhotoAssetReference],
        downloaded: Set<String>,
        privacy: PrivacyActor
    ) -> PhotoKitSourceAdapter {
        PhotoKitSourceAdapter(
            library: WiringFakePhotoLibrary(access: access, assets: assets, downloaded: downloaded),
            privacyActor: privacy,
            configuration: .production
        )
    }

    private func makePhotoRefs(_ ids: [String]) -> [PhotoAssetReference] {
        ids.map {
            PhotoAssetReference(assetId: $0, mediaType: "image", creationDate: nil, modificationDate: nil)
        }
    }

    // ══════════════════════════════════════════════════════════════
    // 1. SyncPipeline.importPhotoLibrary — 首次全量导入
    // ══════════════════════════════════════════════════════════════

    @Test("importPhotoLibrary imports only locally-available photos and writes dataSourceConnected audit")
    func importPhotoLibraryLocallyAvailable() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let privacy = PrivacyActor(db: db)
        let sync = makeSync(registry: registry, privacy: privacy)
        let adapter = makeAdapter(
            access: .authorized,
            assets: makePhotoRefs(["a1", "a2", "a3"]),
            downloaded: ["a1", "a2"],
            privacy: privacy
        )

        let result = try await sync.importPhotoLibrary(adapter: adapter)

        #expect(result.replacedCount == 2)

        // canonical 落库验证（vision 通道）
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        for id in ["a1", "a2"] {
            let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: id, sourceType: "photo")
            #expect(try await repo.loadMemory(memoryId: memoryId) != nil)
        }
        let missingId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "a3", sourceType: "photo")
        #expect(try await repo.loadMemory(memoryId: missingId) == nil)

        // 每代向量计数
        let store = await registry.vectorStore(for: "vision_dense/siglip2-v1")
        #expect(await store?.liveCount == 2)

        // US-SRC-001 AC-5: .dataSourceConnected 审计（仅 hash-only content）
        let logs = try await privacy.fetchAuditLogs(eventType: .dataSourceConnected)
        #expect(logs.count == 1)
    }

    @Test("importPhotoLibrary skips excluded assets (fail-closed)")
    func importPhotoLibrarySkipsExcluded() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let privacy = PrivacyActor(db: db)
        let excluded = ExcludedAssetsActor(db: db, privacyActor: privacy)
        try await excluded.add(assetId: "a1", sourceType: "photo", traceID: "exclude-test")

        let sync = makeSync(registry: registry, privacy: privacy)
        let adapter = makeAdapter(
            access: .authorized,
            assets: makePhotoRefs(["a1", "a2", "a3"]),
            downloaded: ["a1", "a2", "a3"],
            privacy: privacy
        )

        let result = try await sync.importPhotoLibrary(adapter: adapter)

        #expect(result.replacedCount == 2)
        #expect(result.skippedCount == 1)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let excludedId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "a1", sourceType: "photo")
        #expect(try await repo.loadMemory(memoryId: excludedId) == nil)
    }

    @Test("importPhotoLibrary privacy denied returns empty result without audit")
    func importPhotoLibraryPrivacyDenied() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let privacy = PrivacyActor(db: db)
        // 策略不含 photo 授权 → PrivacyCheckpoint 拒绝（R-006）
        try await privacy.updatePolicy(
            UserPolicy(preferredLanguage: "zh-Hans", authorizedSourceTypes: [], policyVersion: 2)
        )
        defer { Task { try? await privacy.updatePolicy(UserPolicy(policyVersion: 3)) } }

        let sync = makeSync(registry: registry, privacy: privacy)
        let adapter = makeAdapter(
            access: .authorized,
            assets: makePhotoRefs(["a1", "a2"]),
            downloaded: ["a1", "a2"],
            privacy: privacy
        )

        let result = try await sync.importPhotoLibrary(adapter: adapter)

        #expect(result.replacedCount == 0)
        let logs = try await privacy.fetchAuditLogs(eventType: .dataSourceConnected)
        #expect(logs.isEmpty)
    }

    // ══════════════════════════════════════════════════════════════
    // 2. SettingsViewModel.requestPhotoLibraryAccess — 授权入口
    // ══════════════════════════════════════════════════════════════

    @Test("SettingsViewModel requestPhotoLibraryAccess grants and triggers initial import")
    func settingsRequestPhotoAccessGranted() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let privacy = PrivacyActor(db: db)
        let sync = makeSync(registry: registry, privacy: privacy)
        let composition = AppComposition(
            databaseManager: db,
            generationRegistry: registry,
            textEmbedder: ProductionTestEmbedder(),
            visionEmbedder: ProductionTestEmbedder(),
            asrEngine: nil
        )
        composition.attachProductionSyncPipeline(sync)
        let adapter = makeAdapter(
            access: .authorized,
            assets: makePhotoRefs(["b1", "b2"]),
            downloaded: ["b1", "b2"],
            privacy: privacy
        )
        let vm = SettingsViewModel(composition: composition, photoSourceAdapter: adapter)

        await vm.requestPhotoLibraryAccess()

        guard case .completed(let importedCount) = vm.photoImportState else {
            Issue.record("expected completed state, got \(vm.photoImportState)")
            return
        }
        #expect(importedCount == 2)
        let logs = try await privacy.fetchAuditLogs(eventType: .dataSourceConnected)
        #expect(logs.count == 1)
    }

    @Test("SettingsViewModel requestPhotoLibraryAccess denied shows recoverable error")
    func settingsRequestPhotoAccessDenied() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let privacy = PrivacyActor(db: db)
        let composition = AppComposition(
            databaseManager: db,
            generationRegistry: registry,
            textEmbedder: ProductionTestEmbedder(),
            visionEmbedder: ProductionTestEmbedder(),
            asrEngine: nil
        )
        let adapter = makeAdapter(
            access: .denied,
            assets: makePhotoRefs(["c1"]),
            downloaded: ["c1"],
            privacy: privacy
        )
        let vm = SettingsViewModel(composition: composition, photoSourceAdapter: adapter)

        await vm.requestPhotoLibraryAccess()

        guard case .error(.l2Recoverable) = vm.photoImportState else {
            Issue.record("expected l2Recoverable error, got \(vm.photoImportState)")
            return
        }
    }

    @Test("SettingsViewModel requestPhotoLibraryAccess without pipeline shows blocking error")
    func settingsRequestPhotoAccessNoPipeline() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let privacy = PrivacyActor(db: db)
        // composition 未 attach pipeline（装配未完成）
        let composition = AppComposition(
            databaseManager: db,
            generationRegistry: registry,
            textEmbedder: ProductionTestEmbedder(),
            visionEmbedder: ProductionTestEmbedder(),
            asrEngine: nil
        )
        let adapter = makeAdapter(
            access: .authorized,
            assets: makePhotoRefs(["d1"]),
            downloaded: ["d1"],
            privacy: privacy
        )
        let vm = SettingsViewModel(composition: composition, photoSourceAdapter: adapter)

        await vm.requestPhotoLibraryAccess()

        guard case .error(.l3Blocking) = vm.photoImportState else {
            Issue.record("expected l3Blocking error, got \(vm.photoImportState)")
            return
        }
    }

    // ══════════════════════════════════════════════════════════════
    // 3. AwakeningSettingsViewModel.requestNotificationPermission
    // ══════════════════════════════════════════════════════════════

    @Test("requestNotificationPermission live scheduler authorized → granted")
    func notificationLiveGranted() async throws {
        let stub = StubNotificationScheduler()
        stub.authState = .authorized
        let vm = AwakeningSettingsViewModel(notificationScheduler: stub)

        await vm.requestNotificationPermission()

        #expect(vm.notificationAuthStep == .granted)
    }

    @Test("requestNotificationPermission live scheduler denied → denied")
    func notificationLiveDenied() async throws {
        let stub = StubNotificationScheduler()
        stub.authState = .denied
        let vm = AwakeningSettingsViewModel(notificationScheduler: stub)

        await vm.requestNotificationPermission()

        #expect(vm.notificationAuthStep == .denied)
    }

    @Test("requestNotificationPermission without live scheduler fails closed")
    func notificationMissingBoundary() async throws {
        let vm = AwakeningSettingsViewModel()

        await vm.requestNotificationPermission()

        #expect(vm.notificationAuthStep == .denied)
    }

    // ══════════════════════════════════════════════════════════════
    // 4. ProgressActor.loadAll + BackgroundTaskViewModel 实时轮询
    // ══════════════════════════════════════════════════════════════

    @Test("ProgressActor.loadAll returns active tasks")
    func progressLoadAll() async throws {
        let progress = ProgressActor.shared
        try await db.execute(sql: "DELETE FROM TaskProgress")
        try await progress.save(progress: TaskProgress(
            taskId: "t1",
            taskType: .dataSourceSync,
            lastProcessedIndex: 3,
            totalCount: 10,
            lastProcessedId: "a3"
        ))

        let all = try await progress.loadAll()

        #expect(all.count == 1)
        #expect(all[0].taskId == "t1")
        #expect(all[0].totalCount == 10)
        #expect(all[0].lastProcessedIndex == 3)
    }

    @Test("BackgroundTaskViewModel polls real TaskProgress live")
    func taskPanelLivePolling() async throws {
        let progress = ProgressActor.shared
        try await db.execute(sql: "DELETE FROM TaskProgress")
        try await progress.save(progress: TaskProgress(
            taskId: "live-1",
            taskType: .fullIndex,
            lastProcessedIndex: 2,
            totalCount: 5,
            lastProcessedId: "x"
        ))
        let vm = BackgroundTaskViewModel(
            progressActor: progress,
            pollIntervalNanoseconds: 50_000_000
        )

        vm.openPanel()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if vm.tasks.count == 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(vm.tasks.count == 1)
        #expect(vm.tasks[0].taskId == "live-1")
        #expect(vm.tasks[0].processedCount == 2)
        #expect(vm.tasks[0].totalCount == 5)

        vm.closePanel()
        #expect(vm.tasks.isEmpty)
        // 清理：避免测试数据污染 App 生产数据库（Live Review 曾误读为真实任务）
        try await db.execute(sql: "DELETE FROM TaskProgress")
    }

    // ══════════════════════════════════════════════════════════════
    // 5. GenerationRegistry.ensureInitialGenerations — 生产初始路由
    // ══════════════════════════════════════════════════════════════

    @Test("ensureInitialGenerations creates text+vision route and is idempotent")
    func ensureInitialGenerations() async throws {
        let registry = makeRegistry()
        try await db.execute(sql: "DELETE FROM IndexGeneration")
        try await db.execute(sql: "DELETE FROM ActiveRouteSet")

        try await registry.ensureInitialGenerations()

        let route = try await registry.loadActiveRoute()
        #expect(route != nil)
        #expect(route?.textGeneration == "text_dense/e5-v1")
        #expect(route?.visionGeneration == "vision_dense/siglip2-v1")

        let generations = try await registry.loadGenerations()
        #expect(generations.count == 2)

        // 幂等：二次调用不改变路由
        let versionBefore = route?.version
        try await registry.ensureInitialGenerations()
        let route2 = try await registry.loadActiveRoute()
        #expect(route2?.version == versionBefore)
    }

    // ══════════════════════════════════════════════════════════════
    // 6. UserPolicy defaults contain real sources only
    // ══════════════════════════════════════════════════════════════

    @Test("UserPolicy default authorizes third-party share without a search pseudo-source")
    func policyAuthorizesThirdPartyRealSourceOnly() {
        let policy = UserPolicy()
        #expect(policy.authorizedSourceTypes.contains("thirdParty"),
                "Files/Safari 等第三方分享产生的 sourceType 必须默认授权，否则 ingest 被隐私门禁拒绝")
        #expect(!policy.authorizedSourceTypes.contains("search"),
                "Search is a PrivacyOperation, not a user-authorizable source type")
    }

    // ══════════════════════════════════════════════════════════════
    // 7. SearchPipeline 查询向量按 store 原生维度对齐（384d text_dense）
    // ══════════════════════════════════════════════════════════════

    @Test("search finds ingested text memory in 384d store (dimension-aligned query)")
    func searchFindsTextMemory() async throws {
        let registry = makeRegistry()
        let route = try await seedGenerations(registry)
        let privacy = PrivacyActor(db: db)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let ingest = IngestPipeline(
            embedder: ProductionTestEmbedder(),
            asrEngine: nil,
            privacyActor: privacy,
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: ExcludedAssetsActor(db: db, privacyActor: privacy),
            canonicalRepository: repo,
            generationRegistry: registry,
            taskQueue: nil,
            progressActor: .shared,
            visionEmbedder: ProductionTestEmbedder()
        )
        let envelope = try SharedImportEnvelope.make(
            contentKind: .text,
            sourceType: .note,
            payload: "昨晚在西湖边看日落",
            sourceAppBundleId: "com.apple.mobilenotes",
            createdAt: Date()
        )
        let ingestResult = try await ingest.ingestProductionSharedText(
            envelope,
            taskID: "search-fixture",
            traceID: "search-fixture"
        )
        #expect(ingestResult.sourceType == "note")

        let textStore = await registry.vectorStore(for: route.textGeneration)
        #expect(textStore != nil)
        #expect(await textStore?.dimension == 384)
        #expect(await textStore?.liveCount == 1, "文本记忆应已写入 text_dense store")

        let search = SearchPipeline(
            embedder: ProductionTestEmbedder(),
            privacyActor: privacy,
            vectorStore: textStore!,
            feedbackActor: .shared,
            canonicalRepository: repo
        )
        let items = try await search.search(query: "西湖", k: 5, traceID: "search-query")
        #expect(!items.isEmpty, "384d 查询向量应对齐 384d store 维度，搜索应命中已摄入文本")
    }
}
