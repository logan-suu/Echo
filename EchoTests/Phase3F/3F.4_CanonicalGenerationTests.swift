// ==========================================
// 文件: 3F.4_CanonicalGenerationTests.swift
// 对应规格: docs/decisions/ADR-010-canonical-generation-lifecycle.md (全部决策)
//            docs/01-spec/用户故事与验收标准规格书.md → US-ING-006, US-PRV-004/006/007,
//            US-AWK-007, US-FBK-001/002/003
//            AGENTS.md D-002/D-003/D-004/D-005, §5 存储契约
// 任务: 3F.4 - Canonical storage 与 generation 生命周期
// AC 覆盖: deterministic IDs, 事务性 canonical/vector/FTS 提交, 崩溃点故障注入,
//          重启恢复, route 原子发布, 旧代回滚, 反馈 generation 身份, 全删除边界
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007/R-008, ADR-010
// 生成时间: 2026-08-09
// ==========================================

import Testing
import Foundation
import CryptoKit
@testable import Echo

@Suite("CanonicalGenerationTests", .serialized)
@MainActor
struct CanonicalGenerationTests {

    // MARK: - 共享清理工具

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
        try await db.execute(sql: "DELETE FROM AuditLog")

        // 清理默认 generation 存储目录中的持久化索引文件，保证测试隔离
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

    // MARK: - 确定性 ID

    @MainActor
        @Suite struct DeterministicID {

        @Test("deterministic ID is stable for identical inputs")
        func test_stable_across_calls() {
            let a = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/abc-123", sourceType: "photo")
            let b = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/abc-123", sourceType: "photo")
            #expect(a == b)
        }

        @Test("deterministic ID differs across sourceLocator")
        func test_differs_by_locator() {
            let a = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/aaa", sourceType: "photo")
            let b = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/bbb", sourceType: "photo")
            #expect(a != b)
        }

        @Test("deterministic ID differs across sourceType")
        func test_differs_by_sourceType() {
            let a = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/aaa", sourceType: "photo")
            let b = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/aaa", sourceType: "note")
            #expect(a != b)
        }

        @Test("deterministic ID is RFC 4122 v5-shaped")
        func test_rfc4122_shape() {
            let id = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "loc", sourceType: "photo")
            let u = id.uuid
            #expect((u.6 & 0xF0) == 0x50)
            #expect((u.8 & 0xC0) == 0x80)
        }
    }

    // MARK: - 事务性提交 / 崩溃点

    @MainActor
        @Suite struct TransactionalCommit {
        let db = DatabaseManager.shared
        let manifestActor = ModelManifestActor.shared

        init() async throws {
            try await CanonicalGenerationTests.wipeCanonicalTables()
            try await manifestActor.removeAll()
        }

        private func makeRegistry() -> GenerationRegistryActor {
            GenerationRegistryActor(db: db)
        }

        private func seedGeneration(_ registry: GenerationRegistryActor, id: String = "text_dense/e5-v1", dim: Int = 384) async throws {
            try await registry.registerGeneration(
                IndexGeneration(generationId: id, indexType: "text_dense", dimension: dim)
            )
            try await registry.setGenerationState(id, state: .ready)
            try await registry.setGenerationState(id, state: .active)
        }

        private func makeMemory(sourceLocator: String = "PHAsset/m1", text: String = "a red cat on the roof") -> Memory {
            let id = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: sourceLocator, sourceType: "photo")
            return Memory(
                memoryId: id,
                sourceLocator: sourceLocator,
                canonicalText: text,
                sourceType: "photo"
            )
        }

        private func makeRepo(_ registry: GenerationRegistryActor) -> CanonicalMemoryRepositoryActor {
            CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        }

        @Test("commit writes canonical + representation + FTS atomically")
        func test_commit_writes_all_channels() async throws {
            let registry = makeRegistry()
            try await seedGeneration(registry)
            let repo = makeRepo(registry)
            let memory = makeMemory()
            let rep = Representation(memoryId: memory.memoryId, modality: .textDense, preprocessVersion: "e5-v1", contentHash: "sha256:abc")

            try await repo.commit(
                memory: memory,
                representations: [rep],
                vectorsByGeneration: ["text_dense/e5-v1": [CanonicalVectorEntry(id: memory.memoryId, vector: Array(repeating: 0.5, count: 384))]],
                traceID: "t-commit-1"
            )

            let loaded = try await repo.loadMemory(memoryId: memory.memoryId)
            #expect(loaded != nil)
            #expect(loaded?.sourceLocator == "PHAsset/m1")

            let reps = try await repo.loadRepresentations(memoryId: memory.memoryId)
            #expect(reps.count == 1)
            #expect(reps[0].modality == .textDense)

            let store = await registry.vectorStore(for: "text_dense/e5-v1")
            #expect(await store?.liveCount == 1)

            let hits = try await repo.searchCanonical(matching: "roof")
            #expect(hits.contains(memory.memoryId))

            let rows = try await db.executeQuery(
                sql: "SELECT success FROM AuditLog WHERE eventType = 'ingestTransaction' ORDER BY timestamp DESC LIMIT 1",
                bindings: []
            )
            #expect(rows.first?["success"]?.intValue == 1)
        }

        @Test("vector write failure rolls back canonical (no half-write)")
        func test_vector_failure_compensates() async throws {
            let registry = makeRegistry()
            try await seedGeneration(registry)
            let repo = makeRepo(registry)
            let memory = makeMemory(sourceLocator: "PHAsset/m2")

            try await repo.setFault(.vectorWrite)
            do {
                try await repo.commit(
                    memory: memory,
                    representations: [],
                    vectorsByGeneration: ["text_dense/e5-v1": [CanonicalVectorEntry(id: memory.memoryId, vector: Array(repeating: 0.5, count: 384))]],
                    traceID: "t-fault-1"
                )
                #expect(Bool(false), "Expected injected vector fault")
            } catch {
                // expected — vector fault injected
            }
            try await repo.setFault(nil)

            #expect(try await repo.loadMemory(memoryId: memory.memoryId) == nil)
            #expect(try await repo.loadRepresentations(memoryId: memory.memoryId).isEmpty)
            let store = await registry.vectorStore(for: "text_dense/e5-v1")
            #expect(await store?.liveCount == 0)
            let hits = try await repo.searchCanonical(matching: "roof")
            #expect(!hits.contains(memory.memoryId))

            let rows = try await db.executeQuery(
                sql: "SELECT success FROM AuditLog WHERE eventType = 'ingestTransaction' ORDER BY timestamp DESC LIMIT 1",
                bindings: []
            )
            #expect(rows.first?["success"]?.intValue == 0)
        }

        @Test("crash after canonical write before vector write leaves no mixed state")
        func test_crash_point_between_boundaries() async throws {
            let registry = makeRegistry()
            try await seedGeneration(registry)
            let repo = makeRepo(registry)
            let memory = makeMemory(sourceLocator: "PHAsset/m3")

            try await repo.setFault(.afterCanonicalWrite)
            do {
                try await repo.commit(
                    memory: memory,
                    representations: [],
                    vectorsByGeneration: ["text_dense/e5-v1": [CanonicalVectorEntry(id: memory.memoryId, vector: Array(repeating: 0.5, count: 384))]],
                    traceID: "t-crash-1"
                )
                #expect(Bool(false), "Expected injected crash fault")
            } catch {
                // expected
            }
            try await repo.setFault(nil)

            #expect(try await repo.loadMemory(memoryId: memory.memoryId) == nil)
            let store = await registry.vectorStore(for: "text_dense/e5-v1")
            #expect(await store?.liveCount == 0)
        }

        @Test("searchCanonical escapes FTS5 syntax characters, no MATCH error (F-3)")
        func test_search_escapes_fts5_syntax() async throws {
            let registry = makeRegistry()
            try await seedGeneration(registry)
            let repo = makeRepo(registry)
            let memory = makeMemory(sourceLocator: "PHAsset/fts-1", text: "meeting notes parentheses stars quoted words")
            let rep = Representation(memoryId: memory.memoryId, modality: .textDense, preprocessVersion: "e5-v1", contentHash: "sha256:fts")
            try await repo.commit(memory: memory, representations: [rep], vectorsByGeneration: [:], traceID: "t-fts")

            // FTS5 语法字符（括号/星号/引号）不再导致 MATCH 运行时错误
            #expect(try await repo.searchCanonical(matching: "(parentheses)").contains(memory.memoryId))
            #expect(try await repo.searchCanonical(matching: "*stars*").contains(memory.memoryId))
            #expect(try await repo.searchCanonical(matching: "\"quoted\"").contains(memory.memoryId))
            #expect(try await repo.searchCanonical(matching: "meeting parentheses").contains(memory.memoryId))

            // 空/纯空白查询返回空数组（不抛错）
            #expect(try await repo.searchCanonical(matching: "   ").isEmpty)
            #expect(try await repo.searchCanonical(matching: "").isEmpty)
        }
    }

    // MARK: - 重启恢复 / route 原子发布 / 回滚

    @MainActor
        @Suite struct Lifecycle {
        let db = DatabaseManager.shared

        init() async throws {
            try await CanonicalGenerationTests.wipeCanonicalTables()
        }

        private func makeRegistry() -> GenerationRegistryActor {
            GenerationRegistryActor(db: db)
        }

        @Test("activateGeneration publishes route and demotes old active (atomic publish)")
        func test_activate_publishes_route() async throws {
            let registry = makeRegistry()

            try await registry.registerGeneration(IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384))
            try await registry.finishShadowBuild("text_dense/e5-v1", counts: 10, validationDigest: "digest-1")
            let route1 = try await registry.activateGeneration("text_dense/e5-v1")
            #expect(route1.textGeneration == "text_dense/e5-v1")
            #expect(route1.version == 1)

            try await registry.registerGeneration(IndexGeneration(generationId: "text_dense/e5-v2", indexType: "text_dense", dimension: 384))
            try await registry.finishShadowBuild("text_dense/e5-v2", counts: 5, validationDigest: "digest-2")
            let route2 = try await registry.activateGeneration("text_dense/e5-v2")
            #expect(route2.textGeneration == "text_dense/e5-v2")
            #expect(route2.version == 2)
            #expect(route2.previousTextGeneration == "text_dense/e5-v1")

            let loaded = try await registry.loadActiveRoute()
            #expect(loaded?.textGeneration == "text_dense/e5-v2")

            let old = try await registry.loadGeneration("text_dense/e5-v1")
            #expect(old?.state != .building)
        }

        @Test("activateGeneration rejects generation still building (no mixed route)")
        func test_activate_rejects_building() async throws {
            let registry = makeRegistry()
            try await registry.registerGeneration(IndexGeneration(generationId: "g-building", indexType: "text_dense", dimension: 384))
            do {
                _ = try await registry.activateGeneration("g-building")
                #expect(Bool(false), "Expected routeValidationFailed")
            } catch let error as Echo.GenerationError {
                if case .routeValidationFailed = error {
                    // expected
                } else {
                    #expect(Bool(false), "Wrong error: \(error)")
                }
            }
        }

        @Test("rollbackToPrevious restores the prior generation route")
        func test_rollback_restores_previous() async throws {
            let registry = makeRegistry()

            try await registry.registerGeneration(IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384))
            try await registry.finishShadowBuild("text_dense/e5-v1", counts: 10, validationDigest: "d1")
            _ = try await registry.activateGeneration("text_dense/e5-v1")

            try await registry.registerGeneration(IndexGeneration(generationId: "text_dense/e5-v2", indexType: "text_dense", dimension: 384))
            try await registry.finishShadowBuild("text_dense/e5-v2", counts: 5, validationDigest: "d2")
            _ = try await registry.activateGeneration("text_dense/e5-v2")

            let rolled = try await registry.rollbackToPrevious()
            #expect(rolled != nil)
            #expect(rolled?.textGeneration == "text_dense/e5-v1")

            let loaded = try await registry.loadActiveRoute()
            #expect(loaded?.textGeneration == "text_dense/e5-v1")
        }

        @Test("activateGeneration commits state migration + route in one transaction (F-2)")
        func test_activate_atomic_commit() async throws {
            let registry = makeRegistry()

            try await registry.registerGeneration(IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384))
            try await registry.finishShadowBuild("text_dense/e5-v1", counts: 10, validationDigest: "d1")
            _ = try await registry.activateGeneration("text_dense/e5-v1")

            try await registry.registerGeneration(IndexGeneration(generationId: "text_dense/e5-v2", indexType: "text_dense", dimension: 384))
            try await registry.finishShadowBuild("text_dense/e5-v2", counts: 5, validationDigest: "d2")
            _ = try await registry.activateGeneration("text_dense/e5-v2")

            // 单事务原子提交：旧代 .ready、新代 .active、路由指向新代且记录 previous
            let old = try await registry.loadGeneration("text_dense/e5-v1")
            #expect(old?.state == .ready)
            let new = try await registry.loadGeneration("text_dense/e5-v2")
            #expect(new?.state == .active)
            let route = try await registry.loadActiveRoute()
            #expect(route?.textGeneration == "text_dense/e5-v2")
            #expect(route?.previousTextGeneration == "text_dense/e5-v1")
        }

        @Test("rollbackToPrevious commits demotion + promotion + route in one transaction (F-2)")
        func test_rollback_atomic_commit() async throws {
            let registry = makeRegistry()

            try await registry.registerGeneration(IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384))
            try await registry.finishShadowBuild("text_dense/e5-v1", counts: 10, validationDigest: "d1")
            _ = try await registry.activateGeneration("text_dense/e5-v1")

            try await registry.registerGeneration(IndexGeneration(generationId: "text_dense/e5-v2", indexType: "text_dense", dimension: 384))
            try await registry.finishShadowBuild("text_dense/e5-v2", counts: 5, validationDigest: "d2")
            _ = try await registry.activateGeneration("text_dense/e5-v2")

            let rolled = try await registry.rollbackToPrevious()
            #expect(rolled?.textGeneration == "text_dense/e5-v1")

            let old = try await registry.loadGeneration("text_dense/e5-v1")
            #expect(old?.state == .active)
            let new = try await registry.loadGeneration("text_dense/e5-v2")
            #expect(new?.state == .ready)
            let route = try await registry.loadActiveRoute()
            #expect(route?.textGeneration == "text_dense/e5-v1")
            #expect(route?.previousTextGeneration == "text_dense/e5-v2")
        }

        @Test("restart restore reopens route and generation stores from disk")
        func test_restart_restore_active_route() async throws {
            let registry1 = makeRegistry()

            try await registry1.registerGeneration(IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384))
            try await registry1.finishShadowBuild("text_dense/e5-v1", counts: 3, validationDigest: "digest")
            _ = try await registry1.activateGeneration("text_dense/e5-v1")

            if let store = await registry1.vectorStore(for: "text_dense/e5-v1") {
                try await store.ingest(vector: Array(repeating: 0.5, count: 384), id: UUID())
            }
            try await registry1.persistStore(generationId: "text_dense/e5-v1")

            let registry2 = makeRegistry()
            let restored = try await registry2.restoreActiveRoute()
            #expect(restored != nil)
            #expect(restored?.textGeneration == "text_dense/e5-v1")

            let reopened = await registry2.vectorStore(for: "text_dense/e5-v1")
            #expect(reopened != nil)
            #expect(await reopened?.liveCount == 1)

            try? await registry2.removeStoreFile(generationId: "text_dense/e5-v1")
        }
    }

    // MARK: - 反馈 generation 身份

    @MainActor
        @Suite struct FeedbackIdentity {
        let db = DatabaseManager.shared
        let feedback = FeedbackActor.shared

        init() async throws {
            try await CanonicalGenerationTests.wipeCanonicalTables()
        }

        @Test("feedback row carries generation identity (US-FBK-001/002/003)")
        func test_feedback_generation_identity() async throws {
            let memoryId = UUID()
            let entry = FeedbackEntry(
                memoryId: memoryId,
                queryText: "red cat",
                sentiment: .like,
                cosineSimilarity: 0.9
            )
            try await feedback.recordFeedback(entry, traceID: "t-fb", generationId: "text_dense/e5-v1")

            let genId = try await feedback.generationId(for: entry.id)
            #expect(genId == "text_dense/e5-v1")

            let entries = try await feedback.fetchEntries(for: memoryId)
            #expect(entries.count == 1)
            #expect(entries[0].id == entry.id)
        }

        @Test("feedback with nil generation stores null and still resolves")
        func test_feedback_nil_generation() async throws {
            let memoryId = UUID()
            let entry = FeedbackEntry(memoryId: memoryId, queryText: "q", sentiment: .dislike, cosineSimilarity: 0.5)
            try await feedback.recordFeedback(entry, traceID: "t-fb2")

            let genId = try await feedback.generationId(for: entry.id)
            #expect(genId == nil)
        }
    }

    // MARK: - 全删除边界 (D-005) + ExcludedAssets 契约

    @MainActor
        @Suite struct DeletionBoundary {
        let db = DatabaseManager.shared
        let excluded = ExcludedAssetsActor.shared

        init() async throws {
            try await CanonicalGenerationTests.wipeCanonicalTables()
        }

        private func makeRegistry() -> GenerationRegistryActor {
            GenerationRegistryActor(db: db)
        }

        private func makeRepo(_ registry: GenerationRegistryActor) -> CanonicalMemoryRepositoryActor {
            CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        }

        private func seedMemory(_ repo: CanonicalMemoryRepositoryActor, _ registry: GenerationRegistryActor, locator: String) async throws -> Memory {
            try await registry.registerGeneration(IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384))
            try await registry.setGenerationState("text_dense/e5-v1", state: .ready)
            try await registry.setGenerationState("text_dense/e5-v1", state: .active)
            let memory = Memory(
                memoryId: CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: locator, sourceType: "photo"),
                sourceLocator: locator,
                canonicalText: "some text",
                sourceType: "photo"
            )
            try await repo.commit(
                memory: memory,
                representations: [Representation(memoryId: memory.memoryId, modality: .textDense, preprocessVersion: "e5-v1", contentHash: "h")],
                vectorsByGeneration: ["text_dense/e5-v1": [CanonicalVectorEntry(id: memory.memoryId, vector: Array(repeating: 0.5, count: 384))]],
                traceID: "t-seed"
            )
            return memory
        }

        @Test("仅从 Echo 移除 writes ExcludedAssets and clears all copies (US-PRV-004)")
        func test_delete_removeFromEcho_writesExcluded() async throws {
            let registry = makeRegistry()
            let repo = makeRepo(registry)
            let memory = try await seedMemory(repo, registry, locator: "PHAsset/echo-1")

            let result = try await repo.deleteMemory(
                memoryId: memory.memoryId,
                sourceLocator: "PHAsset/echo-1",
                sourceType: "photo",
                writeExcluded: true,
                traceID: "t-del-1"
            )
            #expect(result == true)

            #expect(try await excluded.contains(assetId: "PHAsset/echo-1"))

            #expect(try await repo.loadMemory(memoryId: memory.memoryId) == nil)
            #expect(try await repo.loadRepresentations(memoryId: memory.memoryId).isEmpty)
            let store = await registry.vectorStore(for: "text_dense/e5-v1")
            #expect(await store?.liveCount == 0)
            let hits = try await repo.searchCanonical(matching: "text")
            #expect(!hits.contains(memory.memoryId))

            let rows = try await db.executeQuery(
                sql: "SELECT excludedWritten FROM AuditLog WHERE eventType = 'memoryDeleted' ORDER BY timestamp DESC LIMIT 1",
                bindings: []
            )
            #expect(rows.first?["excludedWritten"]?.intValue == 1)
        }

        @Test("cascade delete does NOT write ExcludedAssets and cleans invalid records (US-PRV-007)")
        func test_cascade_delete_noExcluded_cleansInvalid() async throws {
            let registry = makeRegistry()
            let repo = makeRepo(registry)
            let memory = try await seedMemory(repo, registry, locator: "PHAsset/orig-1")

            try await excluded.add(assetId: "PHAsset/orig-1", sourceType: "photo", traceID: "t-excl")

            let result = try await repo.cascadeDeleteFromOriginal(
                assetId: "PHAsset/orig-1",
                sourceType: "photo",
                traceID: "t-cascade"
            )
            #expect(result.deletedCount == 1)
            #expect(result.excludedAutoCleaned == true)

            #expect(try await repo.loadMemory(memoryId: memory.memoryId) == nil)
            #expect(try await excluded.contains(assetId: "PHAsset/orig-1") == false)

            let rows = try await db.executeQuery(
                sql: "SELECT excludedWritten FROM AuditLog WHERE eventType = 'cascadeDeleteFromOriginal' ORDER BY timestamp DESC LIMIT 1",
                bindings: []
            )
            #expect(rows.first?["excludedWritten"]?.intValue == 0)
        }

        @Test("full deletion boundary covers translationCache (D-005)")
        func test_delete_covers_translationCache() async throws {
            let registry = makeRegistry()
            let repo = makeRepo(registry)
            let memory = try await seedMemory(repo, registry, locator: "PHAsset/tc-1")

            _ = try await db.executeWrite(
                sql: "INSERT INTO translationCache (memoryId, languagePair, translatedText, createdAt) VALUES (?, ?, ?, ?)",
                bindings: [.text(memory.memoryId.uuidString), .text("zh-Hans->en-US"), .text("译文"), .double(Date().timeIntervalSince1970)]
            )

            _ = try await repo.deleteMemory(memoryId: memory.memoryId, sourceType: "photo", writeExcluded: false, traceID: "t-tc")

            let rows = try await db.executeQuery(
                sql: "SELECT COUNT(*) AS c FROM translationCache WHERE memoryId = ?",
                bindings: [.text(memory.memoryId.uuidString)]
            )
            #expect(rows.first?["c"]?.intValue == 0)
        }

        @Test("deleteMemory cleans persisted disk copies for unloaded generations (F-1/D-005)")
        func test_delete_cleans_disk_copies_unloaded_generation() async throws {
            let registry = makeRegistry()
            let repo = makeRepo(registry)
            let memory = try await seedMemory(repo, registry, locator: "PHAsset/disk-1")
            try await registry.persistStore(generationId: "text_dense/e5-v1")
            let url = await registry.storeFileURL(for: "text_dense/e5-v1")
            #expect(FileManager.default.fileExists(atPath: url.path))
            let before = try VectorStoreActor.load(from: url)
            #expect(await before.liveCount == 1)

            // 模拟新会话：全新 registry 实例（storeInstances 为空），generation 仅存于 DB + 磁盘
            let freshRegistry = makeRegistry()
            let freshRepo = makeRepo(freshRegistry)
            let deleted = try await freshRepo.deleteMemory(
                memoryId: memory.memoryId,
                sourceType: "photo",
                writeExcluded: false,
                traceID: "t-disk-1"
            )
            #expect(deleted == true)

            let after = try VectorStoreActor.load(from: url)
            #expect(await after.liveCount == 0)
            try? await freshRegistry.removeStoreFile(generationId: "text_dense/e5-v1")
        }
    }

    // MARK: - US-AWK-007 编辑字段持久化 (DEF-38-001/002)

    @MainActor
        @Suite struct EditPersistence {
        let db = DatabaseManager.shared

        init() async throws {
            try await CanonicalGenerationTests.wipeCanonicalTables()
        }

        @Test("originalTimestamp/userEdited/userLocked persist and round-trip (US-AWK-007 AC-2/4/6)")
        func test_edit_fields_roundtrip() async throws {
            let registry = GenerationRegistryActor(db: db)
            let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
            try await registry.registerGeneration(IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384))
            try await registry.setGenerationState("text_dense/e5-v1", state: .ready)
            try await registry.setGenerationState("text_dense/e5-v1", state: .active)

            let original = Date(timeIntervalSince1970: 1_700_000_000)
            let memory = Memory(
                memoryId: UUID(),
                sourceLocator: "PHAsset/edit-1",
                canonicalText: "edited description",
                sourceType: "photo",
                originalTimestamp: original,
                userEdited: true,
                userLocked: true
            )
            try await repo.commit(memory: memory, representations: [], vectorsByGeneration: [:], traceID: "t-edit")

            let loaded = try await repo.loadMemory(memoryId: memory.memoryId)
            #expect(loaded != nil)
            #expect(loaded?.originalTimestamp == original)
            #expect(loaded?.userEdited == true)
            #expect(loaded?.userLocked == true)
        }
    }

    // MARK: - schema 迁移完整性

    @MainActor
        @Suite struct SchemaMigration {
        let db = DatabaseManager.shared
        let migrationActor = DatabaseMigrationActor.shared

        init() async throws {
            try await db.open()
        }

        @Test("v5 schema migration applied (new tables + columns exist)")
        func test_v5_schema_applied() async throws {
            #expect(try await migrationActor.isV5SchemaApplied())
        }
    }
}
