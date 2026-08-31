// ==========================================
// 文件: Phase1IntegrationTests.swift
// 对应规格: docs/02-architecture/架构设计文档.md §5.1 (存储层次), §7 (隐私校验)
//            docs/01-spec/用户故事与验收标准规格书.md §US-PRV-001, §US-FBK-001~003, §US-SYS-001
// 任务: Phase 1 集成测试 - 基础设施搭建阶段验收
// 测试范围: DatabaseManager + ExcludedAssetsActor + FeedbackActor + ProgressActor +
//           PendingOpsActor + VectorStoreActor + PrivacyActor 跨组件集成
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007/R-008, §12.6 (阶段集成测试契约)
// 生成时间: 2026-07-05
// ==========================================

import Testing
import Foundation
import ProximaKit
@testable import Echo

// MARK: - Phase 1 Integration Test Suite

@Suite("Phase1Integration", .serialized)
struct Phase1IntegrationTests {

    // MARK: - Shared Fixtures

    let db = DatabaseManager.shared
    let excludedAssets = ExcludedAssetsActor.shared
    let feedback = FeedbackActor.shared
    let progress = ProgressActor.shared
    let pendingOps = PendingOpsActor.shared
    let privacy = PrivacyActor.shared

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
        try await db.execute(sql: "DELETE FROM FeedbackStore")
        try await db.execute(sql: "DELETE FROM TaskProgress")
        try await db.execute(sql: "DELETE FROM PendingOperations")
    }

    // MARK: - Suite 1: Database Tables Cross-Verification

    @Suite("DatabaseTables")
    struct DatabaseTablesTests {
        let db = DatabaseManager.shared

        init() async throws {
            try await db.open()
        }

        @Test("All 5 tables exist and are queryable")
        func test_allTablesExist() async throws {
            let tables = try await db.executeQuery(
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
                bindings: []
            )
            let names = tables.compactMap { $0["name"]?.stringValue }
            #expect(names.contains("ExcludedAssets"))
            #expect(names.contains("FeedbackStore"))
            #expect(names.contains("TaskProgress"))
            #expect(names.contains("PendingOperations"))
        }

        @Test("ExcludedAssets table has correct schema")
        func test_excludedAssetsSchema() async throws {
            let columns = try await db.executeQuery(
                sql: "PRAGMA table_info(ExcludedAssets)",
                bindings: []
            )
            let colNames = columns.compactMap { $0["name"]?.stringValue }
            #expect(colNames.contains("assetId"))
            #expect(colNames.contains("sourceType"))
            #expect(colNames.contains("excludedAt"))
        }

        @Test("FeedbackStore table has correct schema")
        func test_feedbackStoreSchema() async throws {
            let columns = try await db.executeQuery(
                sql: "PRAGMA table_info(FeedbackStore)",
                bindings: []
            )
            let colNames = columns.compactMap { $0["name"]?.stringValue }
            #expect(colNames.contains("feedbackId"))
            #expect(colNames.contains("memoryId"))
            #expect(colNames.contains("queryText"))
            #expect(colNames.contains("sentiment"))
            #expect(colNames.contains("cosineSimilarity"))
            #expect(colNames.contains("createdAt"))
            #expect(colNames.contains("isBadCase"))
        }

        @Test("TaskProgress table has correct schema")
        func test_taskProgressSchema() async throws {
            let columns = try await db.executeQuery(
                sql: "PRAGMA table_info(TaskProgress)",
                bindings: []
            )
            let colNames = columns.compactMap { $0["name"]?.stringValue }
            #expect(colNames.contains("taskId"))
            #expect(colNames.contains("taskType"))
            #expect(colNames.contains("lastProcessedIndex"))
            #expect(colNames.contains("totalCount"))
            #expect(colNames.contains("resumeData"))
        }

        @Test("PendingOperations table has correct schema")
        func test_pendingOperationsSchema() async throws {
            let columns = try await db.executeQuery(
                sql: "PRAGMA table_info(PendingOperations)",
                bindings: []
            )
            let colNames = columns.compactMap { $0["name"]?.stringValue }
            #expect(colNames.contains("operationId"))
            #expect(colNames.contains("operationType"))
            #expect(colNames.contains("retryCount"))
            #expect(colNames.contains("parameters"))
            #expect(colNames.contains("lastError"))
        }

        @Test("WAL mode is enabled")
        func test_walModeEnabled() async throws {
            let rows = try await db.executeQuery(
                sql: "PRAGMA journal_mode",
                bindings: []
            )
            let mode = rows.first?["journal_mode"]?.stringValue ?? ""
            #expect(mode == "wal")
        }

        @Test("Foreign keys are enabled")
        func test_foreignKeysEnabled() async throws {
            let rows = try await db.executeQuery(
                sql: "PRAGMA foreign_keys",
                bindings: []
            )
            let val = rows.first?["foreign_keys"]?.intValue ?? 0
            #expect(val == 1)
        }
    }

    // MARK: - Suite 2: ExcludedAssetsActor + DatabaseManager Integration

    @Suite("ExcludedAssetsIntegration")
    struct ExcludedAssetsIntegrationTests {
        let sut = ExcludedAssetsActor.shared
        let db = DatabaseManager.shared

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM ExcludedAssets")
        }

        @Test("Add and query excluded asset round-trip")
        func test_addAndQueryRoundTrip() async throws {
            let assetId = "photo-001"
            try await sut.add(assetId: assetId, sourceType: "photo")
            let exists = try await sut.contains(assetId: assetId)
            #expect(exists)

            let rows = try await db.executeQuery(
                sql: "SELECT assetId, sourceType FROM ExcludedAssets WHERE assetId = ?",
                bindings: [.text(assetId)]
            )
            #expect(rows.count == 1)
            #expect(rows.first?["sourceType"]?.stringValue == "photo")
        }

        @Test("Remove excluded asset cleans DB")
        func test_removeCleansDB() async throws {
            let assetId = "photo-002"
            try await sut.add(assetId: assetId, sourceType: "photo")
            let removed = try await sut.remove(assetId: assetId)
            #expect(removed)
            let exists = try await sut.contains(assetId: assetId)
            #expect(!exists)
        }

        @Test("Remove non-existent asset returns false")
        func test_removeNonExistent() async throws {
            let removed = try await sut.remove(assetId: "nonexistent")
            #expect(!removed)
        }

        @Test("Batch restore by source type removes excluded assets")
        func test_batchRestore() async throws {
            let ids = ["batch-1", "batch-2", "batch-3"]
            for id in ids {
                try await sut.add(assetId: id, sourceType: "photo")
            }
            try await sut.batchRestore(sourceType: "photo")
            for id in ids {
                #expect(try await !sut.contains(assetId: id))
            }
        }

        @Test("List excluded assets returns correct items")
        func test_listAllExcludedAssets() async throws {
            try await sut.add(assetId: "list-1", sourceType: "photo")
            try await sut.add(assetId: "list-2", sourceType: "note")
            let items = try await sut.listAll()
            let ids = items.map { $0.assetId }
            #expect(ids.contains("list-1"))
            #expect(ids.contains("list-2"))
        }

        @Test("Count returns correct number of excluded assets")
        func test_count() async throws {
            try await sut.add(assetId: "count-1", sourceType: "photo")
            try await sut.add(assetId: "count-2", sourceType: "note")
            let c = try await sut.count()
            #expect(c == 2)
        }

        @Test("Cleanup invalid record removes from DB")
        func test_cleanupInvalidRecord() async throws {
            try await sut.add(assetId: "cleanup-1", sourceType: "photo")
            try await sut.cleanupInvalidRecord(assetId: "cleanup-1")
            #expect(try await !sut.contains(assetId: "cleanup-1"))
        }
    }

    // MARK: - Suite 3: FeedbackActor + DatabaseManager Integration

    @Suite("FeedbackIntegration")
    struct FeedbackIntegrationTests {
        let sut = FeedbackActor.shared
        let db = DatabaseManager.shared

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM FeedbackStore")
        }

        @Test("Record feedback persists to DB")
        func test_recordFeedbackPersists() async throws {
            let entry = FeedbackEntry(
                id: UUID(),
                memoryId: UUID(),
                queryText: "test_query",
                sentiment: .like,
                cosineSimilarity: 0.85,
                createdAt: Date(),
                isBadCase: false,
                badCaseReason: nil
            )
            try await sut.recordFeedback(entry)

            let rows = try await db.executeQuery(
                sql: "SELECT feedbackId, sentiment, cosineSimilarity FROM FeedbackStore WHERE memoryId = ?",
                bindings: [.text(entry.memoryId.uuidString)]
            )
            #expect(rows.count == 1)
            #expect(rows.first?["sentiment"]?.stringValue == "like")
        }

        @Test("Compute adjustment returns zero adjustment below threshold")
        func test_adjustmentBelowThreshold() async throws {
            let memoryId = UUID()
            let queryText = "low_similarity_query"
            let entry = FeedbackEntry(
                id: UUID(),
                memoryId: memoryId,
                queryText: queryText,
                sentiment: .like,
                cosineSimilarity: 0.50,
                createdAt: Date(),
                isBadCase: false,
                badCaseReason: nil
            )
            try await sut.recordFeedback(entry)

            let adjustment = try await sut.computeAdjustment(for: memoryId, queryText: queryText)
            #expect(adjustment.adjustment == 0.0)
            #expect(adjustment.feedbackCount == 0)
        }

        @Test("Compute adjustment applies above threshold")
        func test_adjustmentAboveThreshold() async throws {
            let memoryId = UUID()
            let queryText = "high_similarity_query"
            let entry = FeedbackEntry(
                id: UUID(),
                memoryId: memoryId,
                queryText: queryText,
                sentiment: .like,
                cosineSimilarity: 0.92,
                createdAt: Date(),
                isBadCase: false,
                badCaseReason: nil
            )
            try await sut.recordFeedback(entry)

            let adjustment = try await sut.computeAdjustment(for: memoryId, queryText: queryText)
            #expect(adjustment.feedbackCount > 0)
            #expect(adjustment.adjustment > 0.0)
        }

        @Test("Reset feedback cleans DB")
        func test_resetFeedback() async throws {
            let entry = FeedbackEntry(
                id: UUID(),
                memoryId: UUID(),
                queryText: "query",
                sentiment: .dislike,
                cosineSimilarity: 0.90,
                createdAt: Date(),
                isBadCase: true,
                badCaseReason: "irrelevant"
            )
            try await sut.recordFeedback(entry)
            try await sut.reset()

            let rows = try await db.executeQuery(
                sql: "SELECT COUNT(*) as cnt FROM FeedbackStore",
                bindings: []
            )
            let count = rows.first?["cnt"]?.intValue ?? -1
            #expect(count == 0)
        }

        @Test("Revoke single feedback removes it")
        func test_revokeFeedback() async throws {
            let feedbackId = UUID()
            let entry = FeedbackEntry(
                id: feedbackId,
                memoryId: UUID(),
                queryText: "revoke me",
                sentiment: .like,
                cosineSimilarity: 0.85,
                createdAt: Date(),
                isBadCase: false,
                badCaseReason: nil
            )
            try await sut.recordFeedback(entry)
            let revoked = try await sut.revoke(feedbackId: feedbackId)
            #expect(revoked)
            let c = try await sut.count()
            #expect(c == 0)
        }

        @Test("Fetch bad cases returns only bad cases")
        func test_fetchBadCases() async throws {
            let badEntry = FeedbackEntry(
                id: UUID(),
                memoryId: UUID(),
                queryText: "bad query",
                sentiment: .dislike,
                cosineSimilarity: 0.90,
                createdAt: Date(),
                isBadCase: true,
                badCaseReason: "wrong result"
            )
            try await sut.recordFeedback(badEntry)
            let badCases = try await sut.fetchBadCases()
            #expect(badCases.count == 1)
            #expect(badCases.first?.isBadCase == true)
        }
    }

    // MARK: - Suite 4: ProgressActor + DatabaseManager Integration

    @Suite("ProgressIntegration")
    struct ProgressIntegrationTests {
        let sut = ProgressActor.shared
        let db = DatabaseManager.shared

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM TaskProgress")
        }

        @Test("Save and load progress round-trip")
        func test_saveAndLoadRoundTrip() async throws {
            let task = TaskProgress(
                taskId: "ingest-batch-1",
                taskType: .fullIndex,
                lastProcessedIndex: 42,
                totalCount: 100,
                lastProcessedId: "item-42",
                resumeData: Data([0x01, 0x02, 0x03]),
                updatedAt: Date(),
                createdAt: Date()
            )
            try await sut.save(progress: task)
            let loaded = try await sut.load(taskId: "ingest-batch-1")
            #expect(loaded != nil)
            #expect(loaded?.lastProcessedIndex == 42)
            #expect(loaded?.totalCount == 100)
            #expect(loaded?.lastProcessedId == "item-42")
        }

        @Test("Update progress modifies DB correctly")
        func test_updateProgressModifiesDB() async throws {
            let task = TaskProgress(
                taskId: "update-test",
                taskType: .dataSourceSync,
                lastProcessedIndex: 0,
                totalCount: 50,
                lastProcessedId: nil,
                resumeData: nil,
                updatedAt: Date(),
                createdAt: Date()
            )
            try await sut.save(progress: task)
            try await sut.updateProgress(taskId: "update-test", lastProcessedIndex: 25, lastProcessedId: "item-25")

            let loaded = try await sut.load(taskId: "update-test")
            #expect(loaded?.lastProcessedIndex == 25)
            #expect(loaded?.lastProcessedId == "item-25")
        }

        @Test("Delete progress cleans DB")
        func test_deleteProgress() async throws {
            let task = TaskProgress(
                taskId: "delete-test",
                taskType: .fullIndex,
                lastProcessedIndex: 10,
                totalCount: 100,
                lastProcessedId: nil,
                resumeData: nil,
                updatedAt: Date(),
                createdAt: Date()
            )
            try await sut.save(progress: task)
            try await sut.delete(taskId: "delete-test")

            let loaded = try await sut.load(taskId: "delete-test")
            #expect(loaded == nil)
        }

        @Test("Load non-existent task returns nil")
        func test_loadNonExistent() async throws {
            let loaded = try await sut.load(taskId: "never-saved")
            #expect(loaded == nil)
        }

        @Test("Has pending progress detects unfinished tasks")
        func test_hasPendingProgress() async throws {
            let task = TaskProgress(
                taskId: "pending-test",
                taskType: .fullIndex,
                lastProcessedIndex: 5,
                totalCount: 100,
                updatedAt: Date(),
                createdAt: Date()
            )
            try await sut.save(progress: task)
            let hasPending = try await sut.hasPendingProgress(taskType: .fullIndex)
            #expect(hasPending)
        }
    }

    // MARK: - Suite 5: PendingOpsActor + DatabaseManager Integration

    @Suite("PendingOpsIntegration")
    struct PendingOpsIntegrationTests {
        let sut = PendingOpsActor.shared
        let db = DatabaseManager.shared

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM PendingOperations")
        }

        @Test("Add and load pending operation round-trip")
        func test_addAndLoadRoundTrip() async throws {
            let op = PendingOperation(
                operationId: "op-001",
                operationType: "ingest",
                retryCount: 0,
                parameters: Data([0xAB, 0xCD]),
                createdAt: Date(),
                lastError: "disk full"
            )
            try await sut.add(operation: op)
            let loaded = try await sut.load(operationId: "op-001")
            #expect(loaded != nil)
            #expect(loaded?.operationType == "ingest")
            #expect(loaded?.retryCount == 0)
            #expect(loaded?.lastError == "disk full")
        }

        @Test("Update retry count increments and sets error")
        func test_updateRetryCount() async throws {
            let op = PendingOperation(
                operationId: "op-002",
                operationType: "sync",
                retryCount: 1,
                parameters: Data(),
                createdAt: Date(),
                lastError: "timeout"
            )
            try await sut.add(operation: op)
            try await sut.updateRetry(operationId: "op-002", lastError: "retry failed")

            let loaded = try await sut.load(operationId: "op-002")
            #expect(loaded?.retryCount == 2)
            #expect(loaded?.lastError == "retry failed")
        }

        @Test("Remove operation deletes from DB")
        func test_removeOperation() async throws {
            let op = PendingOperation(
                operationId: "op-003",
                operationType: "sync",
                retryCount: 0,
                parameters: Data(),
                createdAt: Date(),
                lastError: nil
            )
            try await sut.add(operation: op)
            let removed = try await sut.remove(operationId: "op-003")
            #expect(removed)
            #expect(try await sut.load(operationId: "op-003") == nil)
        }

        @Test("List all returns all pending operations")
        func test_listAll() async throws {
            for i in 0..<3 {
                try await sut.add(operation: PendingOperation(
                    operationId: "list-op-\(i)",
                    operationType: "ingest",
                    retryCount: 0,
                    parameters: Data(),
                    createdAt: Date(),
                    lastError: nil
                ))
            }
            let all = try await sut.listAll()
            #expect(all.count == 3)
        }

        @Test("Cleanup removes all pending operations")
        func test_cleanup() async throws {
            try await sut.add(operation: PendingOperation(
                operationId: "cleanup-op",
                operationType: "ingest",
                retryCount: 0,
                parameters: Data(),
                createdAt: Date(),
                lastError: nil
            ))
            try await sut.cleanup()
            let c = try await sut.count()
            #expect(c == 0)
        }
    }

    // MARK: - Suite 6: VectorStoreActor + DatabaseManager Integration

    @Suite("VectorStoreDBIntegration")
    struct VectorStoreDBIntegrationTests {
        let db = DatabaseManager.shared

        init() async throws {
            try await db.open()
        }

        @Test("VectorStoreActor creates with default dimension")
        func test_defaultDimension() {
            let store = VectorStoreActor(dimension: 512)
            #expect(store.dimension == 512)
        }

        @Test("Ingest and search round-trip")
        func test_ingestAndSearch() async throws {
            let store = VectorStoreActor(dimension: 4)
            let id = UUID()
            let vector: [Float] = [0.1, 0.2, 0.3, 0.4]
            try await store.ingest(vector: vector, id: id)

            let results = await store.search(query: vector, k: 1)
            #expect(results.count == 1)
            #expect(results.first?.id == id)
        }

        @Test("Batch ingest and search")
        func test_batchIngestAndSearch() async throws {
            let store = VectorStoreActor(dimension: 4)
            let entries: [(vector: [Float], id: UUID, metadata: Data?)] = [
                ([0.9, 0.0, 0.0, 0.0], UUID(), Data("first".utf8)),
                ([0.0, 0.9, 0.0, 0.0], UUID(), Data("second".utf8)),
                ([0.0, 0.0, 0.9, 0.0], UUID(), Data("third".utf8)),
            ]
            try await store.batchIngest(entries)
            let count = await store.liveCount
            #expect(count == 3)

            let results = await store.search(query: [0.9, 0.1, 0.0, 0.0], k: 3)
            #expect(results.count == 3)
            #expect(results.first?.id == entries[0].id)
        }

        @Test("Delete vector reduces count")
        func test_deleteVector() async throws {
            let store = VectorStoreActor(dimension: 4)
            let id = UUID()
            try await store.ingest(vector: [0.5, 0.5, 0.5, 0.5], id: id)
            #expect(await store.liveCount == 1)

            let deleted = await store.delete(id: id)
            #expect(deleted)
            #expect(await store.liveCount == 0)
        }

        @Test("Dimension mismatch throws error")
        func test_dimensionMismatch() async throws {
            let store = VectorStoreActor(dimension: 4)
            do {
                try await store.ingest(vector: [0.1, 0.2], id: UUID())
                Issue.record("Expected dimension mismatch error")
            } catch let error as Echo.VectorStoreError {
                switch error {
                case .dimensionMismatch(let expected, let got):
                    #expect(expected == 4)
                    #expect(got == 2)

                default:
                    Issue.record("Unexpected error type: \(error)")
                }
            }
        }

        @Test("Save and load persistence round-trip")
        func test_saveAndLoadPersistence() async throws {
            let store = VectorStoreActor(dimension: 4)
            let id = UUID()
            try await store.ingest(vector: [0.7, 0.7, 0.7, 0.7], id: id)

            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("phase1-integration-test.pxkt")
            defer { try? FileManager.default.removeItem(at: tmpURL) }

            try await store.save(to: tmpURL)
            let restored = try VectorStoreActor.load(from: tmpURL)
            #expect(await restored.liveCount == 1)

            let results = await restored.search(query: [0.7, 0.7, 0.7, 0.7], k: 1)
            #expect(results.first?.id == id)
        }

        @Test("Search respects k limit")
        func test_searchRespectsK() async throws {
            let store = VectorStoreActor(dimension: 4)
            for i in 0..<10 {
                try await store.ingest(vector: [Float(i) * 0.1, 0.0, 0.0, 0.0], id: UUID())
            }
            let results = await store.search(query: [0.5, 0.0, 0.0, 0.0], k: 3)
            #expect(results.count == 3)
        }

        @Test("IsEmpty returns true for empty index")
        func test_isEmpty() async throws {
            let store = VectorStoreActor(dimension: 4)
            #expect(await store.isEmpty)
        }
    }

    // MARK: - Suite 7: PrivacyActor Integration

    @Suite("PrivacyIntegration")
    struct PrivacyIntegrationTests {
        let sut = PrivacyActor.shared

        @Test("Validate allows operation with no source types")
        func test_validateNoSourceTypes() async throws {
            let checkpoint = await sut.validate(
                operation: .search,
                traceID: UUID().uuidString,
                sourceTypes: []
            )
            #expect(checkpoint.isAllowed)
            #expect(checkpoint.decision == .allowed)
        }

        @Test("Validate allows authorized source type")
        func test_validateAuthorizedSource() async throws {
            let checkpoint = await sut.validate(
                operation: .ingest,
                traceID: UUID().uuidString,
                sourceTypes: ["photo"]
            )
            #expect(checkpoint.isAllowed)
        }

        @Test("Validate denies unauthorized source type")
        func test_validateUnauthorizedSource() async throws {
            let checkpoint = await sut.validate(
                operation: .sync,
                traceID: UUID().uuidString,
                sourceTypes: ["contacts"]
            )
            #expect(!checkpoint.isAllowed)
            #expect(checkpoint.decision == .denied)
        }

        @Test("Validate denies if any source type is unauthorized")
        func test_validatePartialUnauthorized() async throws {
            let checkpoint = await sut.validate(
                operation: .search,
                traceID: UUID().uuidString,
                sourceTypes: ["photo", "contacts"]
            )
            #expect(!checkpoint.isAllowed)
        }

        @Test("Validate sets correct operation type on checkpoint")
        func test_validateOperationType() async throws {
            for op: PrivacyOperation in [.search, .ingest, .sync, .delete, .awakening, .feedback] {
                let checkpoint = await sut.validate(
                    operation: op,
                    traceID: UUID().uuidString
                )
                #expect(checkpoint.operation == op)
            }
        }

        @Test("IsSourceAuthorized returns correct value")
        func test_isSourceAuthorized() async throws {
            #expect(await sut.isSourceAuthorized("photo"))
            #expect(await sut.isSourceAuthorized("note"))
            #expect(await sut.isSourceAuthorized("voice"))
            #expect(await !sut.isSourceAuthorized("contacts"))
        }

        @Test("GetPolicy returns current policy")
        func test_getPolicy() async throws {
            let policy = await sut.getPolicy()
            #expect(policy.preferredLanguage == "zh-Hans")
            #expect(policy.authorizedSourceTypes.contains("photo"))
        }

        @Test("UpdatePolicy changes authorization")
        func test_updatePolicy() async throws {
            let originalPolicy = await sut.getPolicy()
            var newPolicy = originalPolicy
            newPolicy.authorizedSourceTypes = ["photo"]
            try await sut.updatePolicy(newPolicy)
            #expect(await sut.isSourceAuthorized("photo"))
            #expect(await !sut.isSourceAuthorized("note"))
            #expect(await !sut.isSourceAuthorized("voice"))

            try await sut.updatePolicy(originalPolicy)
        }
    }

    // MARK: - Suite 8: Cross-Actor End-to-End Integration

    @Suite("CrossActorIntegration")
    struct CrossActorIntegrationTests {
        let db = DatabaseManager.shared
        let excludedAssets = ExcludedAssetsActor.shared
        let feedback = FeedbackActor.shared
        let privacy = PrivacyActor.shared

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM ExcludedAssets")
            try await db.execute(sql: "DELETE FROM FeedbackStore")
        }

        @Test("Privacy check to ExcludedAssets filter to Feedback storage pipeline")
        func test_privacyExcludeFeedbackPipeline() async throws {
            let traceID = UUID().uuidString
            let checkpoint = await privacy.validate(
                operation: .ingest,
                traceID: traceID,
                sourceTypes: ["photo"]
            )
            #expect(checkpoint.isAllowed)

            try await excludedAssets.add(assetId: "pipeline-test-1", sourceType: "photo")
            #expect(try await excludedAssets.contains(assetId: "pipeline-test-1"))

            let entry = FeedbackEntry(
                id: UUID(),
                memoryId: UUID(),
                queryText: "pipeline query",
                sentiment: .like,
                cosineSimilarity: 0.88,
                createdAt: Date(),
                isBadCase: false,
                badCaseReason: nil
            )
            try await feedback.recordFeedback(entry)

            let adjustment = try await feedback.computeAdjustment(
                for: entry.memoryId,
                queryText: entry.queryText
            )
            #expect(adjustment.feedbackCount > 0)

            try await excludedAssets.remove(assetId: "pipeline-test-1")
            #expect(try await !excludedAssets.contains(assetId: "pipeline-test-1"))
        }

        @Test("VectorStore plus ExcludedAssets combined query pipeline")
        func test_vectorStoreWithExcludedFilter() async throws {
            let store = VectorStoreActor(dimension: 4)
            let id1 = UUID()
            let id2 = UUID()
            let id2String = id2.uuidString
            try await store.ingest(vector: [0.9, 0.0, 0.0, 0.0], id: id1)
            try await store.ingest(vector: [0.95, 0.0, 0.0, 0.0], id: id2)

            try await excludedAssets.add(assetId: id2String, sourceType: "photo")

            let excludedItems = try await excludedAssets.listAll()
            let excludedIds = Set(excludedItems.map { $0.assetId })
            let results = await store.search(
                query: [1.0, 0.0, 0.0, 0.0],
                k: 2
            ) { candidateId in
                !excludedIds.contains(candidateId.uuidString)
            }
            #expect(results.count == 1)
            #expect(results.first?.id == id1)
        }

        @Test("Privacy denies operation for unauthorized data source")
        func test_privacyDeniedPipeline() async throws {
            let traceID = UUID().uuidString
            let checkpoint = await privacy.validate(
                operation: .search,
                traceID: traceID,
                sourceTypes: ["calendar"]
            )
            #expect(!checkpoint.isAllowed)
            #expect(checkpoint.decision == .denied)
        }
    }
}
