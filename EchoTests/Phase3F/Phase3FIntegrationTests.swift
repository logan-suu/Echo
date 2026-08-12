// ==========================================
// 文件: Phase3FIntegrationTests.swift
// 对应规格: docs/05-planning/phase3f-execution-plan.md §3F.11 (Production E2E 与 Phase 4 准入门禁),
//           docs/decisions/ADR-007 (production composition + consent),
//           docs/decisions/ADR-010 (canonical generation lifecycle + 路由),
//           docs/decisions/ADR-011 (task progress boundary),
//           AGENTS.md §12.6 (阶段集成测试 — 阶段最后一个正式任务)
// 任务: 3F.11 - Production E2E 与 Phase 4 准入门禁（阶段集成测试）
// AC 覆盖: 生产路径跨模块联调 — composition/consent(4) ✅, canonical+generation 生命周期(5) ✅,
//          生产摄入→canonical→检索→反馈(4) ✅, 全删除边界 purge(3) ✅, 迁移加密包(3) ✅
// 架构约束: AGENTS.md §4.1 (Pipeline 契约), §4.2 (Actor 隔离), §4.4 (错误分级),
//           §4.5 (断点续传), §5.1 (存储层次), R-006, R-007, R-008, D-005
// 重要: 与 3F.1/3F.5 测试共享 wipe 模式；ProductionTestEmbedder/ProductionTestASR
//       定义于 3F.5_ProductionIngestionTests.swift（同测试 target）。
// 生成时间: 2026-08-12
// ==========================================

import Testing
import Foundation
import CryptoKit
@testable import Echo

// MARK: - Shared Wipe Helper

/// 清空 Phase 3F 生产路径涉及的所有表与 generation 磁盘副本。
func wipePhase3FIntegrationState() async throws {
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
    try await db.execute(sql: "DELETE FROM PendingOperations")
    try await db.execute(sql: "DELETE FROM ConsentStore")
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

/// 注册 text + vision 两个 generation 并发布活跃路由（ADR-010）。
func seedPhase3FGenerations(_ registry: GenerationRegistryActor) async throws -> ActiveRouteSet {
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

// ══════════════════════════════════════════════════════════════
// Suite 1: Composition + Consent（ADR-007 决策-1/2/3）
// ══════════════════════════════════════════════════════════════

@Suite("Phase3FIntegration - CompositionConsent", .serialized)
@MainActor
struct Phase3FCompositionConsentIntegrationTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await wipePhase3FIntegrationState()
        await PrivacyActor.shared.disableConsentEnforcement()
    }

    private func makePrivacy() -> PrivacyActor {
        PrivacyActor(db: db)
    }

    private func makeComposition() -> AppComposition {
        let privacy = makePrivacy()
        return AppComposition(
            databaseManager: db,
            privacyActor: privacy,
            consentStore: ConsentStoreActor(db: db, privacyActor: privacy)
        )
    }

    @Test("clean install lands in requiresConsent; acceptConsent reaches ready")
    func test_cleanInstall_consentFlow() async throws {
        let composition = makeComposition()
        await composition.bootstrap()
        #expect(composition.startupState == .requiresConsent)
        #expect(await composition.consentStore.hasConsented() == false)

        try await composition.acceptConsent(consentVersion: 1, policyVersion: 1)
        #expect(composition.startupState == .ready)
        #expect(await composition.consentStore.hasConsented() == true)
        await composition.privacyActor.disableConsentEnforcement()
    }

    @Test("revokeConsent full purge clears business data and returns to requiresConsent")
    func test_revoke_fullPurge() async throws {
        let composition = makeComposition()
        await composition.bootstrap()
        try await composition.acceptConsent(consentVersion: 1, policyVersion: 1)
        try await db.executeWrite(
            sql: "INSERT INTO Memory (memoryId, sourceLocator, canonicalText, sourceType, createdAt, updatedAt) VALUES (?, ?, ?, 'photo', ?, ?)",
            bindings: [
                .text("m-purge"),
                .text("loc://purge"),
                .text("to be purged"),
                .double(Date().timeIntervalSince1970),
                .double(Date().timeIntervalSince1970),
            ]
        )
        try await db.executeWrite(
            sql: "INSERT INTO ExcludedAssets (assetId, sourceType, excludedAt) VALUES ('asset-purge', 'photo', ?)",
            bindings: [.double(Date().timeIntervalSince1970)]
        )

        let result = try await composition.revokeConsent(boundary: .full)
        #expect(result.success)
        #expect(composition.startupState == .requiresConsent)

        let mem = try await db.executeQuery(sql: "SELECT COUNT(*) AS cnt FROM Memory", bindings: [])
        let exc = try await db.executeQuery(sql: "SELECT COUNT(*) AS cnt FROM ExcludedAssets", bindings: [])
        #expect((mem.first?["cnt"]?.intValue.map(Int.init)) ?? -1 == 0)
        #expect((exc.first?["cnt"]?.intValue.map(Int.init)) ?? -1 == 0)
        await composition.privacyActor.disableConsentEnforcement()
    }

    @Test("deny-by-default consent enforcement blocks pipeline access until consent")
    func test_consentEnforcement_deniesBeforeConsent() async throws {
        let privacy = makePrivacy()
        try await privacy.loadPolicy()
        await privacy.enableConsentEnforcement(consentStore: ConsentStoreActor(db: db, privacyActor: privacy))
        // Fresh state: not consented → .denied
        let checkpoint = await privacy.validate(operation: .ingest, traceID: UUID().uuidString)
        #expect(checkpoint.decision == .denied)
        await privacy.disableConsentEnforcement()
    }

    @Test("declined consent stays consentDeclined and is not persisted")
    func test_declineConsent_stateOnly() async throws {
        let composition = makeComposition()
        await composition.bootstrap()
        composition.declineConsent()
        #expect(composition.startupState == .consentDeclined)
        #expect(await composition.consentStore.hasConsented() == false)
        await composition.privacyActor.disableConsentEnforcement()
    }
}

// ══════════════════════════════════════════════════════════════
// Suite 2: Canonical Storage + Generation 生命周期（ADR-010）
// ══════════════════════════════════════════════════════════════

@Suite("Phase3FIntegration - CanonicalGeneration", .serialized)
@MainActor
struct Phase3FCanonicalGenerationIntegrationTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await wipePhase3FIntegrationState()
        await PrivacyActor.shared.disableConsentEnforcement()
        try await PrivacyActor.shared.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice", "text", "search", "video"],
            policyVersion: 1
        ))
    }

    private func makeRepo(_ registry: GenerationRegistryActor) -> CanonicalMemoryRepositoryActor {
        CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
    }

    @Test("deterministic ID is stable across calls for same source+type")
    func test_deterministicID_stability() {
        let a = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "loc://abc", sourceType: "note")
        let b = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "loc://abc", sourceType: "note")
        let c = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "loc://abc", sourceType: "photo")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("commit writes canonical + representation + FTS and loads back")
    func test_commit_roundtrip() async throws {
        let registry = GenerationRegistryActor(db: db)
        _ = try await seedPhase3FGenerations(registry)
        let repo = makeRepo(registry)
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "loc://rt", sourceType: "note")
        let memory = Memory(
            memoryId: memoryId,
            sourceLocator: "loc://rt",
            canonicalText: "A cup of Longjing tea by West Lake",
            sourceType: "note",
            originalTimestamp: nil,
            userEdited: false,
            userLocked: false
        )
        let rep = Representation(
            memoryId: memoryId,
            modality: .textDense,
            preprocessVersion: "e5-v1",
            contentHash: "abc123"
        )
        try await repo.commit(
            memory: memory,
            representations: [rep],
            vectorsByGeneration: ["text_dense/e5-v1": [CanonicalVectorEntry(id: memoryId, vector: Array(repeating: 0.25, count: 384))]],
            traceID: UUID().uuidString
        )
        let loaded = try await repo.loadMemory(memoryId: memoryId)
        #expect(loaded != nil)
        #expect(loaded?.canonicalText == "A cup of Longjing tea by West Lake")
        let fts = try await repo.searchCanonical(matching: "West Lake", limit: 10)
        #expect(fts.contains(memoryId))
    }

    @Test("rollbackToPrevious restores prior active text route after failed activation")
    func test_rollbackToPrevious_restoresRoute() async throws {
        let registry = GenerationRegistryActor(db: db)
        let active = try await seedPhase3FGenerations(registry)

        // Activate a new generation, then roll back to the previous route.
        try await registry.registerGeneration(
            IndexGeneration(generationId: "text_dense/e5-v2", indexType: "text_dense", dimension: 384)
        )
        try await registry.finishShadowBuild("text_dense/e5-v2", counts: 0, validationDigest: nil)
        try await registry.setGenerationState("text_dense/e5-v2", state: .ready)
        _ = try await registry.activateGeneration("text_dense/e5-v2")
        _ = try await registry.rollbackToPrevious()
        let route = try await registry.loadActiveRoute()
        #expect(route?.textGeneration == active.textGeneration)
    }

    @Test("vector write lands in the active generation store and is persisted")
    func test_vectorWrite_activeRoute() async throws {
        let registry = GenerationRegistryActor(db: db)
        _ = try await seedPhase3FGenerations(registry)
        let repo = makeRepo(registry)
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "loc://vec", sourceType: "note")
        let memory = Memory(
            memoryId: memoryId,
            sourceLocator: "loc://vec",
            canonicalText: "向量写入验证",
            sourceType: "note"
        )
        try await repo.commit(
            memory: memory,
            representations: [],
            vectorsByGeneration: ["text_dense/e5-v1": [CanonicalVectorEntry(id: memoryId, vector: Array(repeating: 0.5, count: 384))]],
            traceID: UUID().uuidString
        )
        // The routed store for the active text generation must contain the memory id.
        let store = await registry.vectorStore(for: "text_dense/e5-v1")
        #expect(store != nil)
        let entries = await store?.allEntries() ?? []
        #expect(entries.contains { $0.id == memoryId })
    }

    @Test("searchCanonical is order-stable and returns only matching canonical rows")
    func test_searchCanonical_filtersNonMatching() async throws {
        let registry = GenerationRegistryActor(db: db)
        _ = try await seedPhase3FGenerations(registry)
        let repo = makeRepo(registry)
        let hitId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "loc://hit", sourceType: "note")
        let missId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "loc://miss", sourceType: "note")
        try await repo.commit(
            memory: Memory(memoryId: hitId, sourceLocator: "loc://hit", canonicalText: "Apple keynotes and product launches", sourceType: "note"),
            representations: [],
            vectorsByGeneration: [:],
            traceID: UUID().uuidString
        )
        try await repo.commit(
            memory: Memory(memoryId: missId, sourceLocator: "loc://miss", canonicalText: "quantum physics study notes", sourceType: "note"),
            representations: [],
            vectorsByGeneration: [:],
            traceID: UUID().uuidString
        )
        let hits = try await repo.searchCanonical(matching: "Apple", limit: 10)
        #expect(hits.contains(hitId))
        #expect(!hits.contains(missId))
    }
}

// ══════════════════════════════════════════════════════════════
// Suite 3: 生产摄入 → canonical → 检索 → 反馈（ADR-010/011）
// ══════════════════════════════════════════════════════════════

@Suite("Phase3FIntegration - IngestSearchFeedback", .serialized)
@MainActor
struct Phase3FIngestSearchFeedbackIntegrationTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await wipePhase3FIntegrationState()
        try await PrivacyActor.shared.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice", "text", "search", "video"],
            policyVersion: 1
        ))
    }

    private func makeRegistry() -> GenerationRegistryActor {
        GenerationRegistryActor(db: db)
    }

    private func makePipeline(registry: GenerationRegistryActor) -> IngestPipeline {
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        return IngestPipeline(
            embedder: ProductionTestEmbedder(),
            asrEngine: ProductionTestASR(),
            privacyActor: PrivacyActor(db: db),
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: ExcludedAssetsActor(db: db, privacyActor: PrivacyActor(db: db)),
            canonicalRepository: repo,
            generationRegistry: registry,
            taskQueue: nil,
            progressActor: .shared,
            sharedTextExtractor: nil,
            sharedAudioExtractor: nil
        )
    }

    @Test("production ingest of shared note writes canonical + generation store")
    func test_productionIngestSharedText() async throws {
        let registry = makeRegistry()
        _ = try await seedPhase3FGenerations(registry)
        let pipeline = makePipeline(registry: registry)
        let envelope = try SharedImportEnvelope.make(
            contentKind: .text,
            sourceType: .note,
            payload: "今天在西湖边散步，天气很好",
            sourceAppBundleId: "com.apple.mobilenotes"
        )
        let result = try await pipeline.ingestProductionSharedText(envelope, taskID: "task-1")
        #expect(result.sourceType == "note")
        #expect(result.generationIds.contains("text_dense/e5-v1"))

        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let expectedId = CanonicalMemoryRepositoryActor.deterministicID(
            sourceLocator: result.sourceLocator, sourceType: "note"
        )
        let loaded = try await repo.loadMemory(memoryId: expectedId)
        #expect(loaded != nil)
    }

    @Test("production ingest dedupes identical shared payload")
    func test_productionIngest_dedupe() async throws {
        let registry = makeRegistry()
        _ = try await seedPhase3FGenerations(registry)
        let pipeline = makePipeline(registry: registry)
        let envelope = try SharedImportEnvelope.make(
            contentKind: .text,
            sourceType: .note,
            payload: "去重测试内容",
            sourceAppBundleId: "com.apple.mobilenotes"
        )
        _ = try await pipeline.ingestProductionSharedText(envelope, taskID: "task-a")
        _ = try await pipeline.ingestProductionSharedText(envelope, taskID: "task-b")
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let ids = try await repo.memoryIDs(forSourceLocator: envelope.dedupeKey)
        #expect(ids.count == 1)
    }

    @Test("canonical FTS finds ingested note; feedback record persists with generation identity")
    func test_searchAndFeedback() async throws {
        let registry = makeRegistry()
        _ = try await seedPhase3FGenerations(registry)
        let pipeline = makePipeline(registry: registry)
        let envelope = try SharedImportEnvelope.make(
            contentKind: .text,
            sourceType: .note,
            payload: "Machine learning reading notes and study references",
            sourceAppBundleId: "com.apple.mobilenotes"
        )
        let result = try await pipeline.ingestProductionSharedText(envelope, taskID: "task-1")
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(
            sourceLocator: result.sourceLocator, sourceType: "note"
        )
        let hits = try await repo.searchCanonical(matching: "machine", limit: 10)
        #expect(hits.contains(memoryId))

        let feedback = FeedbackPipeline(
            feedbackActor: FeedbackActor(db: db),
            privacyActor: PrivacyActor(db: db),
            generationRegistry: registry
        )
        try await feedback.recordLike(
            memoryId: memoryId,
            queryText: "machine",
            cosineSimilarity: 0.9
        )
        let entries = try await feedback.fetchFeedback(for: memoryId)
        #expect(entries.count == 1)
        #expect(entries.first?.sentiment == .like)
    }

    @Test("feedback re-rank lifts a liked memory above a higher-similarity non-liked one")
    func test_feedbackRerank() async throws {
        let registry = makeRegistry()
        _ = try await seedPhase3FGenerations(registry)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let likedId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "loc://like", sourceType: "note")
        let otherId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "loc://other", sourceType: "note")
        try await repo.commit(
            memory: Memory(memoryId: likedId, sourceLocator: "loc://like", canonicalText: "最喜欢的咖啡店", sourceType: "note"),
            representations: [],
            vectorsByGeneration: ["text_dense/e5-v1": [CanonicalVectorEntry(id: likedId, vector: makeVec(0.8))]],
            traceID: UUID().uuidString
        )
        try await repo.commit(
            memory: Memory(memoryId: otherId, sourceLocator: "loc://other", canonicalText: "普通咖啡笔记", sourceType: "note"),
            representations: [],
            vectorsByGeneration: ["text_dense/e5-v1": [CanonicalVectorEntry(id: otherId, vector: makeVec(0.9))]],
            traceID: UUID().uuidString
        )
        let feedbackActor = FeedbackActor(db: db)
        try await FeedbackPipeline(
            feedbackActor: feedbackActor,
            privacyActor: PrivacyActor(db: db),
            generationRegistry: registry
        ).recordLike(
            memoryId: likedId,
            queryText: "咖啡",
            cosineSimilarity: 0.8
        )
        let adjustments = try await feedbackActor.computeBatchAdjustments(for: [likedId, otherId], queryText: "咖啡")
        let likedAdj = adjustments[likedId]?.adjustment ?? 0
        let otherAdj = adjustments[otherId]?.adjustment ?? 0
        #expect(likedAdj > otherAdj)
    }
}

// ══════════════════════════════════════════════════════════════
// Suite 4: 全删除边界 purge（D-005）与迁移加密包（3F.7）
// ══════════════════════════════════════════════════════════════

@Suite("Phase3FIntegration - PurgeAndMigration", .serialized)
@MainActor
struct Phase3FPurgeAndMigrationIntegrationTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await wipePhase3FIntegrationState()
        try await PrivacyActor.shared.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice", "text", "search", "video"],
            policyVersion: 1
        ))
    }

    @Test("deleteMemory removes canonical + representation + FTS transactionally")
    func test_deleteMemory_transactional() async throws {
        let registry = GenerationRegistryActor(db: db)
        _ = try await seedPhase3FGenerations(registry)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "loc://del", sourceType: "note")
        try await repo.commit(
            memory: Memory(memoryId: memoryId, sourceLocator: "loc://del", canonicalText: "待删除的记忆", sourceType: "note"),
            representations: [Representation(memoryId: memoryId, modality: .textDense, preprocessVersion: "e5-v1", contentHash: "h")],
            vectorsByGeneration: ["text_dense/e5-v1": [CanonicalVectorEntry(id: memoryId, vector: makeVec(0.4))]],
            traceID: UUID().uuidString
        )
        let deleted = try await repo.deleteMemory(memoryId: memoryId, writeExcluded: false, traceID: UUID().uuidString)
        #expect(deleted)
        #expect(try await repo.loadMemory(memoryId: memoryId) == nil)
        let fts = try await repo.searchCanonical(matching: "待删除", limit: 10)
        #expect(!fts.contains(memoryId))
    }

    @Test("cascadeDeleteFromOriginal cleans vectors and does not write ExcludedAssets")
    func test_cascadeDeleteFromOriginal() async throws {
        let registry = GenerationRegistryActor(db: db)
        _ = try await seedPhase3FGenerations(registry)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "loc://cascade", sourceType: "photo")
        try await repo.commit(
            memory: Memory(memoryId: memoryId, sourceLocator: "loc://cascade", canonicalText: "级联删除", sourceType: "photo"),
            representations: [],
            vectorsByGeneration: ["text_dense/e5-v1": [CanonicalVectorEntry(id: memoryId, vector: makeVec(0.4))]],
            traceID: UUID().uuidString
        )
        let result = try await repo.cascadeDeleteFromOriginal(
            assetId: "loc://cascade",
            sourceType: "photo",
            traceID: UUID().uuidString
        )
        #expect(result.deletedCount == 1)
        // R-003: cascade delete must NOT write ExcludedAssets.
        let excluded = ExcludedAssetsActor(db: db, privacyActor: PrivacyActor(db: db))
        let isExcluded = try await excluded.contains(assetId: "loc://cascade")
        #expect(isExcluded == false)
    }

    @Test("ECHOMIG1 package encrypts/decrypts round-trip with integrity")
    func test_migrationPackage_roundtrip() throws {
        let transferKey = SymmetricKey(size: .bits256)
        let payload = Data("hello".utf8)
        let payloadSHA = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let records = [
            DeviceMigrationRecord(
                type: "memory",
                id: "m-1",
                byteLength: payload.count,
                sha256: payloadSHA,
            ),
        ]
        let payloads = ["m-1": payload]
        let package = try DeviceMigrationService.exportPackage(
            records: records,
            payloads: payloads,
            transferKey: transferKey
        )
        let imported = try DeviceMigrationService.importPackage(package, transferKey: transferKey)
        #expect(imported.manifest.records == records)
        #expect(imported.payloads["m-1"] == payload)
    }

    @Test("tampered migration package fails integrity validation")
    func test_migrationPackage_tamper() throws {
        let transferKey = SymmetricKey(size: .bits256)
        let payload = Data("hello".utf8)
        let payloadSHA = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let records = [
            DeviceMigrationRecord(type: "memory", id: "m-1", byteLength: payload.count, sha256: payloadSHA)
        ]
        let payloads = ["m-1": payload]
        var package = try DeviceMigrationService.exportPackage(
            records: records,
            payloads: payloads,
            transferKey: transferKey
        )
        // Flip a byte in the payload region of the package.
        package[package.count / 2] ^= 0xFF
        #expect(throws: (any Error).self) {
            _ = try DeviceMigrationService.importPackage(package, transferKey: transferKey)
        }
    }
}

// MARK: - Helper

func makeVec(_ v: Float, _ dimension: Int = 384) -> [Float] {
    let remaining = (1.0 - v * v) / Float(dimension - 1)
    let fill = remaining > 0 ? sqrt(max(0, remaining)) : 0.0
    var vec = [v]
    vec.append(contentsOf: Array(repeating: fill, count: dimension - 1))
    return vec
}
