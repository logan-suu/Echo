// ==========================================
// 文件: SQLiteActorTests.swift
// 对应规格: docs/02-architecture/架构设计文档.md §5.1 (存储层次), §6 (断点续传)
//            docs/01-spec/用户故事与验收标准规格书.md §US-FBK-001~003, §US-SYS-001
// 任务: 1.4 - 集成 SQLite，创建 ExcludedAssets, Feedback, TaskProgress, PendingOperations 表
// AC 覆盖: US-PRV-004 (写入条件), US-FBK-002 (AC-1/2/3 重排公式), US-SYS-001 (AC-4 进度清理)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007/R-008
// 生成时间: 2026-07-04
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Test Suite: ExcludedAssetsActor

@Suite("ExcludedAssetsActor", .serialized)
struct ExcludedAssetsActorTests {

    let sut = ExcludedAssetsActor.shared
    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
    }

    @Test("contains returns false for unknown assetId")
    func test_contains_unknownAsset() async throws {
        let exists = try await sut.contains(assetId: "nonexistent")
        #expect(exists == false)
    }

    @Test("add then contains returns true")
    func test_addThenContains() async throws {
        try await sut.add(assetId: "asset-1", sourceType: "photo")
        let exists = try await sut.contains(assetId: "asset-1")
        #expect(exists == true)
    }

    @Test("remove existing asset succeeds and contains returns false")
    func test_remove_existing() async throws {
        try await sut.add(assetId: "asset-r1", sourceType: "photo")
        let removed = try await sut.remove(assetId: "asset-r1")
        #expect(removed == true)
        #expect(try await sut.contains(assetId: "asset-r1") == false)
    }

    @Test("remove non-existing asset returns false")
    func test_remove_nonExisting() async throws {
        let removed = try await sut.remove(assetId: "no-such-asset")
        #expect(removed == false)
    }

    @Test("count reflects add operations")
    func test_count() async throws {
        try await sut.add(assetId: "c1", sourceType: "photo")
        try await sut.add(assetId: "c2", sourceType: "note")
        try await sut.add(assetId: "c3", sourceType: "photo")
        let cnt = try await sut.count()
        #expect(cnt == 3)
    }

    @Test("batchRestore removes all entries for given sourceType")
    func test_batchRestore() async throws {
        try await sut.add(assetId: "br1", sourceType: "photo")
        try await sut.add(assetId: "br2", sourceType: "photo")
        try await sut.add(assetId: "br3", sourceType: "note")
        try await sut.batchRestore(sourceType: "photo")
        #expect(try await sut.count() == 1)
        #expect(try await sut.contains(assetId: "br3") == true)
    }

    @Test("cleanupInvalidRecord removes excluded record without writing")
    func test_cleanupInvalidRecord() async throws {
        try await sut.add(assetId: "clean-me", sourceType: "photo")
        try await sut.cleanupInvalidRecord(assetId: "clean-me")
        #expect(try await sut.contains(assetId: "clean-me") == false)
        #expect(try await sut.count() == 0)
    }

    @Test("listAll returns paginated results")
    func test_listAll() async throws {
        try await sut.add(assetId: "l1", sourceType: "photo")
        try await sut.add(assetId: "l2", sourceType: "note")
        let results = try await sut.listAll(limit: 1, offset: 0)
        #expect(results.count == 1)
    }
}

// MARK: - Test Suite: FeedbackActor

@Suite("FeedbackActor", .serialized)
struct FeedbackActorTests {

    let sut = FeedbackActor.shared
    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM FeedbackStore")
    }

    func makeEntry(memoryId: UUID, sentiment: FeedbackSentiment, sim: Double, daysAgo: Int = 0) -> FeedbackEntry {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return FeedbackEntry(memoryId: memoryId, queryText: "test query", sentiment: sentiment, cosineSimilarity: sim, createdAt: date)
    }

    @Test("recordFeedback stores entry and increments count")
    func test_recordFeedback() async throws {
        let entry = makeEntry(memoryId: UUID(), sentiment: .like, sim: 0.85)
        try await sut.recordFeedback(entry)
        #expect(try await sut.count() == 1)
    }

    @Test("computeAdjustment returns 0 for memory with no feedback")
    func test_noFeedback_zeroAdjustment() async throws {
        let result = try await sut.computeAdjustment(for: UUID(), queryText: "anything")
        #expect(result.adjustment == 0)
        #expect(result.feedbackCount == 0)
    }

    @Test("computeAdjustment ignores feedback below threshold 0.80")
    func test_adjustment_belowThreshold_ignored() async throws {
        let memId = UUID()
        try await sut.recordFeedback(makeEntry(memoryId: memId, sentiment: .like, sim: 0.75))
        let result = try await sut.computeAdjustment(for: memId, queryText: "test")
        #expect(result.adjustment == 0)
        #expect(result.feedbackCount == 0)
    }

    @Test("computeAdjustment applies like with decay 1.0 clamped to 0.5 for single feedback")
    func test_adjustment_likeRecent() async throws {
        let memId = UUID()
        try await sut.recordFeedback(makeEntry(memoryId: memId, sentiment: .like, sim: 0.85, daysAgo: 5))
        let result = try await sut.computeAdjustment(for: memId, queryText: "test")
        // raw=1.0, clamped to 0.5 per AC-3
        #expect(result.adjustment == 0.5)
        #expect(result.feedbackCount == 1)
    }

    @Test("computeAdjustment applies dislike clamping to -0.5 for single feedback")
    func test_adjustment_dislike() async throws {
        let memId = UUID()
        try await sut.recordFeedback(makeEntry(memoryId: memId, sentiment: .dislike, sim: 0.90, daysAgo: 1))
        let result = try await sut.computeAdjustment(for: memId, queryText: "test")
        // raw=-1.0, clamped to -0.5 per AC-3
        #expect(result.adjustment == -0.5)
    }

    @Test("computeAdjustment applies medium decay (0.5) for 91-180 day old feedback")
    func test_adjustment_mediumDecay() async throws {
        let memId = UUID()
        try await sut.recordFeedback(makeEntry(memoryId: memId, sentiment: .like, sim: 0.90, daysAgo: 100))
        let result = try await sut.computeAdjustment(for: memId, queryText: "test")
        #expect(result.adjustment == 0.5)
    }

    @Test("computeAdjustment ignores feedback older than 180 days")
    func test_adjustment_archived() async throws {
        let memId = UUID()
        try await sut.recordFeedback(makeEntry(memoryId: memId, sentiment: .like, sim: 0.90, daysAgo: 200))
        let result = try await sut.computeAdjustment(for: memId, queryText: "test")
        #expect(result.adjustment == 0)
        #expect(result.feedbackCount == 0)
    }

    @Test("computeAdjustment clamps to upper bound 0.5")
    func test_adjustment_clampedUpper() async throws {
        let memId = UUID()
        // 2 likes = 2.0, clamped to 0.5
        try await sut.recordFeedback(makeEntry(memoryId: memId, sentiment: .like, sim: 0.85, daysAgo: 1))
        try await sut.recordFeedback(makeEntry(memoryId: memId, sentiment: .like, sim: 0.85, daysAgo: 2))
        let result = try await sut.computeAdjustment(for: memId, queryText: "test")
        #expect(result.adjustment == 0.5)
        #expect(result.feedbackCount == 2)
    }

    @Test("computeAdjustment clamps to lower bound -0.5")
    func test_adjustment_clampedLower() async throws {
        let memId = UUID()
        try await sut.recordFeedback(makeEntry(memoryId: memId, sentiment: .dislike, sim: 0.85, daysAgo: 1))
        try await sut.recordFeedback(makeEntry(memoryId: memId, sentiment: .dislike, sim: 0.85, daysAgo: 2))
        let result = try await sut.computeAdjustment(for: memId, queryText: "test")
        #expect(result.adjustment == -0.5)
    }

    @Test("revoke removes feedback and adjustment recalibrates")
    func test_revoke() async throws {
        let memId = UUID()
        let entry = makeEntry(memoryId: memId, sentiment: .like, sim: 0.85)
        try await sut.recordFeedback(entry)
        #expect(try await sut.count() == 1)

        try await sut.revoke(feedbackId: entry.id)
        #expect(try await sut.count() == 0)

        let result = try await sut.computeAdjustment(for: memId, queryText: "test")
        #expect(result.adjustment == 0)
    }

    @Test("reset clears all feedback")
    func test_reset() async throws {
        try await sut.recordFeedback(makeEntry(memoryId: UUID(), sentiment: .like, sim: 0.85))
        try await sut.recordFeedback(makeEntry(memoryId: UUID(), sentiment: .dislike, sim: 0.90))
        #expect(try await sut.count() == 2)

        try await sut.reset()
        #expect(try await sut.count() == 0)
    }

    @Test("recordBadCase stores bad case with reason")
    func test_badCase() async throws {
        let memId = UUID()
        let entry = FeedbackEntry(
            memoryId: memId, queryText: "bad result",
            sentiment: .dislike, cosineSimilarity: 0.95,
            isBadCase: true, badCaseReason: "irrelevant"
        )
        try await sut.recordFeedback(entry)

        let badCases = try await sut.fetchBadCases()
        #expect(badCases.count == 1)
        #expect(badCases[0].badCaseReason == "irrelevant")
    }
}

// MARK: - Test Suite: ProgressActor

@Suite("ProgressActor", .serialized)
struct ProgressActorTests {

    let sut = ProgressActor.shared
    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM TaskProgress")
    }

    @Test("save and load round-trip preserves data")
    func test_saveLoad_roundtrip() async throws {
        let progress = TaskProgress(
            taskId: "task-001",
            taskType: .fullIndex,
            lastProcessedIndex: 42,
            totalCount: 100
        )
        try await sut.save(progress: progress)

        let loaded = try await sut.load(taskId: "task-001")
        #expect(loaded != nil)
        #expect(loaded?.taskType == .fullIndex)
        #expect(loaded?.lastProcessedIndex == 42)
        #expect(loaded?.totalCount == 100)
    }

    @Test("load returns nil for unknown taskId")
    func test_load_unknown() async throws {
        let loaded = try await sut.load(taskId: "no-such-task")
        #expect(loaded == nil)
    }

    @Test("updateProgress modifies index and id")
    func test_updateProgress() async throws {
        let progress = TaskProgress(taskId: "task-u1", taskType: .dataSourceSync, totalCount: 50)
        try await sut.save(progress: progress)

        try await sut.updateProgress(taskId: "task-u1", lastProcessedIndex: 25, lastProcessedId: "asset-25")

        let loaded = try await sut.load(taskId: "task-u1")
        #expect(loaded?.lastProcessedIndex == 25)
        #expect(loaded?.lastProcessedId == "asset-25")
    }

    @Test("updateProgress on unknown task throws notFound")
    func test_updateProgress_unknownTask() async throws {
        do {
            try await sut.updateProgress(taskId: "ghost", lastProcessedIndex: 1, lastProcessedId: nil)
            #expect(Bool(false), "Expected notFound error")
        } catch let error as Echo.DatabaseError {
            if case .notFound = error {
                // expected
            } else {
                #expect(Bool(false), "Wrong error: \(error)")
            }
        }
    }

    @Test("delete removes progress record per US-SYS-001 AC-4")
    func test_delete_cleanup() async throws {
        let progress = TaskProgress(taskId: "task-del", taskType: .modelLoad, totalCount: 1)
        try await sut.save(progress: progress)

        try await sut.delete(taskId: "task-del")

        #expect(try await sut.load(taskId: "task-del") == nil)
    }

    @Test("hasPendingProgress returns true when progress exists")
    func test_hasPendingProgress() async throws {
        let progress = TaskProgress(taskId: "task-hp", taskType: .fullIndex, totalCount: 10)
        try await sut.save(progress: progress)

        let hasPending = try await sut.hasPendingProgress(taskType: .fullIndex)
        #expect(hasPending == true)
    }

    @Test("save overwrites existing progress with same taskId")
    func test_save_overwrite() async throws {
        let p1 = TaskProgress(taskId: "task-ow", taskType: .fullIndex, lastProcessedIndex: 10, totalCount: 100)
        try await sut.save(progress: p1)

        let p2 = TaskProgress(taskId: "task-ow", taskType: .fullIndex, lastProcessedIndex: 50, totalCount: 100)
        try await sut.save(progress: p2)

        let loaded = try await sut.load(taskId: "task-ow")
        #expect(loaded?.lastProcessedIndex == 50)
    }
}

// MARK: - Test Suite: PendingOpsActor

@Suite("PendingOpsActor", .serialized)
struct PendingOpsActorTests {

    let sut = PendingOpsActor.shared
    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM PendingOperations")
    }

    func makeOp(operationId: String = UUID().uuidString, operationType: String = "ingest_image") -> PendingOperation {
        let params = try! JSONEncoder().encode(["assetId": "img-123"])
        return PendingOperation(operationId: operationId, operationType: operationType, parameters: params)
    }

    @Test("add and load round-trip")
    func test_addLoad_roundtrip() async throws {
        let op = makeOp()
        try await sut.add(operation: op)

        let loaded = try await sut.load(operationId: op.operationId)
        #expect(loaded != nil)
        #expect(loaded?.operationType == "ingest_image")
        #expect(loaded?.retryCount == 0)
    }

    @Test("load returns nil for unknown operation")
    func test_load_unknown() async throws {
        let loaded = try await sut.load(operationId: "nonexistent")
        #expect(loaded == nil)
    }

    @Test("updateRetry increments retryCount")
    func test_updateRetry() async throws {
        let op = makeOp()
        try await sut.add(operation: op)
        try await sut.updateRetry(operationId: op.operationId, lastError: "disk full")

        let loaded = try await sut.load(operationId: op.operationId)
        #expect(loaded?.retryCount == 1)
        #expect(loaded?.lastError == "disk full")
    }

    @Test("remove deletes operation")
    func test_remove() async throws {
        let op = makeOp()
        try await sut.add(operation: op)
        try await sut.remove(operationId: op.operationId)

        #expect(try await sut.load(operationId: op.operationId) == nil)
    }

    @Test("listAll returns all pending operations")
    func test_listAll() async throws {
        try await sut.add(operation: makeOp(operationId: "op-1"))
        try await sut.add(operation: makeOp(operationId: "op-2"))
        try await sut.add(operation: makeOp(operationId: "op-3"))

        let all = try await sut.listAll()
        #expect(all.count == 3)
    }

    @Test("count reflects current state")
    func test_count() async throws {
        try await sut.add(operation: makeOp())
        #expect(try await sut.count() == 1)

        try await sut.add(operation: makeOp())
        #expect(try await sut.count() == 2)
    }

    @Test("cleanup removes all pending operations")
    func test_cleanup() async throws {
        try await sut.add(operation: makeOp())
        try await sut.add(operation: makeOp())
        #expect(try await sut.count() == 2)

        try await sut.cleanup()
        #expect(try await sut.count() == 0)
    }
}

// MARK: - Test Suite: Concurrency Safety

@Suite("SQLiteActor Concurrency Safety", .serialized)
struct SQLiteActorConcurrencyTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
    }

    @Test("concurrent reads on ExcludedAssetsActor do not crash")
    func test_concurrentReads_excludedAssets() async throws {
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
        let actor = ExcludedAssetsActor.shared
        try await actor.add(assetId: "concurrent-test", sourceType: "photo")

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    (try? await actor.contains(assetId: "concurrent-test")) ?? false
                }
            }
            var results = 0
            for await r in group { if r { results += 1 } }
            #expect(results == 20)
        }
    }

    @Test("concurrent feedback recording and reading does not crash")
    func test_concurrentFeedback() async throws {
        try await db.execute(sql: "DELETE FROM FeedbackStore")
        let actor = FeedbackActor.shared
        let memId = UUID()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let entry = FeedbackEntry(
                        memoryId: memId, queryText: "q\(i)",
                        sentiment: .like, cosineSimilarity: 0.85
                    )
                    try? await actor.recordFeedback(entry)
                }
            }
            for _ in 0..<5 {
                group.addTask {
                    _ = try? await actor.count()
                }
            }
        }

        let count = try await actor.count()
        #expect(count == 10)
    }
}
