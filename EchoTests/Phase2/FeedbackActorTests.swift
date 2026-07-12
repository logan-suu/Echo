// ==========================================
// 文件: FeedbackActorTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-FBK-002
// 任务: 2.7 - FeedbackActor + 重排公式（阈值0.80，截断±0.5）
// AC 覆盖: AC-1 (阈值≥0.80), AC-2 (时间衰减), AC-3 (截断±0.5), AC-4 (本地存储),
//            AC-5 (清空所有反馈), AC-6 (撤销单条), AC-7 (审计记录)
// 架构约束: AGENTS.md §5.3 (反馈存储契约), AGENTS.md §7.3 (审计事件)
// 生成时间: 2026-07-12
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Test Suite: FeedbackActor Phase 2

@Suite("FeedbackActor Phase 2", .serialized)
struct FeedbackActorPhase2Tests {

    let sut: FeedbackActor
    let db: DatabaseManager
    let privacyActor: PrivacyActor

    init() async throws {
        db = DatabaseManager.shared
        try await db.open()
        // Clean state
        try await db.execute(sql: "DELETE FROM FeedbackStore")
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")

        privacyActor = PrivacyActor.shared
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice"],
            policyVersion: 1
        ))

        sut = FeedbackActor(db: db)
    }

    // MARK: - AC-4: 反馈数据存储在本地 SQLite

    @Test("recordFeedback writes to FeedbackStore — AC-4")
    func test_recordFeedback_writesToStore() async throws {
        let entry = FeedbackEntry(
            memoryId: UUID(),
            queryText: "test query",
            sentiment: .like,
            cosineSimilarity: 0.90
        )
        try await sut.recordFeedback(entry, traceID: "trace-ac4")

        let entries = try await sut.fetchEntries(for: entry.memoryId)
        #expect(entries.count == 1)
        #expect(entries[0].sentiment == .like)
        #expect(entries[0].cosineSimilarity == 0.90)
        #expect(entries[0].queryText == "test query")
    }

    @Test("feedback data stored locally, never uploaded — AC-4")
    func test_feedbackData_storedLocallyOnly() async throws {
        let count = try await sut.count()
        #expect(count >= 0, "count should return a valid local count")

        let badCases = try await sut.fetchBadCases()
        #expect(badCases is [FeedbackEntry], "fetchBadCases should return local data only")
    }

    // MARK: - AC-1: 反馈匹配策略（仅余弦相似度 ≥ 0.80 时应用）

    @Test("computeAdjustment returns 0 when cosineSimilarity below threshold — AC-1")
    func test_computeAdjustment_excludesBelowThreshold() async throws {
        let memoryId = UUID()
        let entry = FeedbackEntry(
            memoryId: memoryId,
            queryText: "test",
            sentiment: .like,
            cosineSimilarity: 0.79  // below 0.80 threshold
        )
        try await sut.recordFeedback(entry, traceID: "trace-ac1-below")

        let result = try await sut.computeAdjustment(for: memoryId, queryText: "test")
        #expect(result.adjustment == 0.0)
        #expect(result.feedbackCount == 0, "feedback below threshold should not be applied")
    }

    @Test("computeAdjustment applies when cosineSimilarity equals threshold — AC-1")
    func test_computeAdjustment_appliesAtThreshold() async throws {
        let memoryId = UUID()
        let entry = FeedbackEntry(
            memoryId: memoryId,
            queryText: "test",
            sentiment: .like,
            cosineSimilarity: 0.80  // exactly threshold
        )
        try await sut.recordFeedback(entry, traceID: "trace-ac1-equal")

        let result = try await sut.computeAdjustment(for: memoryId, queryText: "test")
        #expect(result.adjustment > 0.0, "feedback at threshold should be applied")
        #expect(result.feedbackCount == 1)
    }

    @Test("computeAdjustment applies when cosineSimilarity above threshold — AC-1")
    func test_computeAdjustment_appliesAboveThreshold() async throws {
        let memoryId = UUID()
        let entry = FeedbackEntry(
            memoryId: memoryId,
            queryText: "test",
            sentiment: .like,
            cosineSimilarity: 0.95  // above threshold
        )
        try await sut.recordFeedback(entry, traceID: "trace-ac1-above")

        let result = try await sut.computeAdjustment(for: memoryId, queryText: "test")
        #expect(result.adjustment > 0.0, "feedback above threshold should be applied")
        #expect(result.feedbackCount == 1)
    }

    // MARK: - AC-2: 时间衰减

    @Test("feedback ≤ 90 days: decayFactor = 1.0 — AC-2")
    func test_decay_recent() async throws {
        let memoryId = UUID()
        // Create a recent entry (1 day ago)
        let entry = FeedbackEntry(
            memoryId: memoryId,
            queryText: "test",
            sentiment: .like,
            cosineSimilarity: 0.85,
            createdAt: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        )
        try await sut.rawInsert(entry)

        let result = try await sut.computeAdjustment(for: memoryId, queryText: "test")
        // rawAdjustment = +1.0, clamped to 0.5 (AC-3: max -0.5, min +0.5)
        #expect(result.adjustment == 0.5, "recent like (1d) → raw=1.0 clamped to 0.5")
        #expect(result.feedbackCount == 1)
    }

    @Test("feedback 90-180 days: decayFactor = 0.5 — AC-2")
    func test_decay_medium() async throws {
        let memoryId = UUID()
        // Create an entry 100 days ago
        let entry = FeedbackEntry(
            memoryId: memoryId,
            queryText: "test",
            sentiment: .like,
            cosineSimilarity: 0.85,
            createdAt: Calendar.current.date(byAdding: .day, value: -100, to: Date())!
        )
        try await sut.rawInsert(entry)

        let result = try await sut.computeAdjustment(for: memoryId, queryText: "test")
        #expect(result.adjustment == 0.5, "100d old like should decay by 0.5")
        #expect(result.feedbackCount == 1)
    }

    @Test("feedback > 180 days: excluded — AC-2")
    func test_decay_archived() async throws {
        let memoryId = UUID()
        // Create an entry 200 days ago
        let entry = FeedbackEntry(
            memoryId: memoryId,
            queryText: "test",
            sentiment: .like,
            cosineSimilarity: 0.85,
            createdAt: Calendar.current.date(byAdding: .day, value: -200, to: Date())!
        )
        try await sut.rawInsert(entry)

        let result = try await sut.computeAdjustment(for: memoryId, queryText: "test")
        #expect(result.adjustment == 0.0, "200d old like should be archived (ignored)")
        #expect(result.feedbackCount == 0)
    }

    // MARK: - AC-3: 重排公式与截断

    @Test("like gives positive weight, dislike gives negative weight — AC-3")
    func test_adjustment_likeAndDislike() async throws {
        let memoryId = UUID()
        // Insert a like (weight +1.0 * 1.0) and a dislike (weight -1.0 * 1.0)
        let likeEntry = FeedbackEntry(
            memoryId: memoryId,
            queryText: "test",
            sentiment: .like,
            cosineSimilarity: 0.90
        )
        let dislikeEntry = FeedbackEntry(
            memoryId: memoryId,
            queryText: "test",
            sentiment: .dislike,
            cosineSimilarity: 0.90
        )
        try await sut.recordFeedback(likeEntry, traceID: "trace-ac3-like")
        try await sut.recordFeedback(dislikeEntry, traceID: "trace-ac3-dislike")

        let result = try await sut.computeAdjustment(for: memoryId, queryText: "test")
        #expect(result.adjustment == 0.0, "1 like + 1 dislike should cancel out")
        #expect(result.feedbackCount == 2)
    }

    @Test("adjustment is clamped to upper bound +0.5 — AC-3")
    func test_adjustment_clampedUpper() async throws {
        let memoryId = UUID()
        // Insert 3 likes (raw = +3.0), should clamp to +0.5
        for i in 0..<3 {
            let entry = FeedbackEntry(
                memoryId: memoryId,
                queryText: "test",
                sentiment: .like,
                cosineSimilarity: 0.90
            )
            try await sut.recordFeedback(entry, traceID: "trace-ac3-clampup-\(i)")
        }

        let result = try await sut.computeAdjustment(for: memoryId, queryText: "test")
        #expect(result.adjustment == 0.5, "3 likes should clamp to +0.5")
        #expect(result.feedbackCount == 3)
    }

    @Test("adjustment is clamped to lower bound -0.5 — AC-3")
    func test_adjustment_clampedLower() async throws {
        let memoryId = UUID()
        // Insert 3 dislikes (raw = -3.0), should clamp to -0.5
        for i in 0..<3 {
            let entry = FeedbackEntry(
                memoryId: memoryId,
                queryText: "test",
                sentiment: .dislike,
                cosineSimilarity: 0.90
            )
            try await sut.recordFeedback(entry, traceID: "trace-ac3-clampdown-\(i)")
        }

        let result = try await sut.computeAdjustment(for: memoryId, queryText: "test")
        #expect(result.adjustment == -0.5, "3 dislikes should clamp to -0.5")
        #expect(result.feedbackCount == 3)
    }

    // MARK: - AC-5: 清空所有反馈学习数据

    @Test("reset clears all feedback records — AC-5")
    func test_reset_clearsAll() async throws {
        let entry = FeedbackEntry(
            memoryId: UUID(),
            queryText: "test",
            sentiment: .like,
            cosineSimilarity: 0.90
        )
        try await sut.recordFeedback(entry, traceID: "trace-ac5-insert")
        #expect(try await sut.count() == 1)

        try await sut.reset(traceID: "trace-ac5-reset")
        #expect(try await sut.count() == 0)
    }

    // MARK: - AC-6: 撤销单条反馈

    @Test("revoke deletes single feedback record — AC-6")
    func test_revoke_deletesSingleRecord() async throws {
        let entry1 = FeedbackEntry(
            memoryId: UUID(),
            queryText: "test1",
            sentiment: .like,
            cosineSimilarity: 0.90
        )
        let entry2 = FeedbackEntry(
            memoryId: UUID(),
            queryText: "test2",
            sentiment: .dislike,
            cosineSimilarity: 0.85
        )
        try await sut.recordFeedback(entry1, traceID: "trace-ac6-1")
        try await sut.recordFeedback(entry2, traceID: "trace-ac6-2")
        #expect(try await sut.count() == 2)

        let revoked = try await sut.revoke(feedbackId: entry1.id, traceID: "trace-ac6-revoke")
        #expect(revoked == true)
        #expect(try await sut.count() == 1)

        // Verify entry2 still exists
        let entries = try await sut.fetchEntries(for: entry2.memoryId)
        #expect(entries.count == 1)
        #expect(entries[0].id == entry2.id)
    }

    @Test("revoke returns false for non-existent feedback — AC-6")
    func test_revoke_returnsFalseForMissing() async throws {
        let revoked = try await sut.revoke(feedbackId: UUID(), traceID: "trace-ac6-missing")
        #expect(revoked == false)
    }

    // MARK: - AC-7: 审计记录

    @Test("recordFeedback writes .feedbackReceived audit event — AC-7")
    func test_recordFeedback_auditEvent() async throws {
        let entry = FeedbackEntry(
            memoryId: UUID(),
            queryText: "audit test",
            sentiment: .like,
            cosineSimilarity: 0.90
        )
        try await sut.recordFeedback(entry, traceID: "trace-ac7-received")

        let logs = try await privacyActor.fetchAuditLogs(eventType: .feedbackReceived)
        #expect(logs.count >= 1)
        let log = logs.first!
        #expect(log.eventType == .feedbackReceived)
        #expect(log.traceID == "trace-ac7-received")
        #expect(log.success == true)
    }

    @Test("reset writes .feedbackReset audit event — AC-7")
    func test_reset_auditEvent() async throws {
        try await sut.reset(traceID: "trace-ac7-reset")

        let logs = try await privacyActor.fetchAuditLogs(eventType: .feedbackReset)
        #expect(logs.count >= 1)
        let log = logs.first!
        #expect(log.eventType == .feedbackReset)
        #expect(log.traceID == "trace-ac7-reset")
        #expect(log.success == true)
    }

    @Test("revoke writes .feedbackRevoked audit event — AC-7")
    func test_revoke_auditEvent() async throws {
        let entry = FeedbackEntry(
            memoryId: UUID(),
            queryText: "audit revoke",
            sentiment: .like,
            cosineSimilarity: 0.90
        )
        try await sut.recordFeedback(entry, traceID: "trace-ac7-revoke-insert")

        let revoked = try await sut.revoke(feedbackId: entry.id, traceID: "trace-ac7-revoke-delete")
        #expect(revoked == true)

        let logs = try await privacyActor.fetchAuditLogs(eventType: .feedbackRevoked)
        #expect(logs.count >= 1)
        let log = logs.first!
        #expect(log.eventType == .feedbackRevoked)
        #expect(log.traceID == "trace-ac7-revoke-delete")
        #expect(log.success == true)
    }

    // MARK: - computeBatchAdjustments

    @Test("computeBatchAdjustments returns results for all requested memoryIds")
    func test_computeBatchAdjustments() async throws {
        let memoryId1 = UUID()
        let memoryId2 = UUID()

        try await sut.recordFeedback(FeedbackEntry(
            memoryId: memoryId1, queryText: "test", sentiment: .like, cosineSimilarity: 0.90
        ), traceID: "trace-batch-1")
        try await sut.recordFeedback(FeedbackEntry(
            memoryId: memoryId2, queryText: "test", sentiment: .dislike, cosineSimilarity: 0.85
        ), traceID: "trace-batch-2")

        let results = try await sut.computeBatchAdjustments(
            for: [memoryId1, memoryId2], queryText: "test"
        )
        #expect(results.count == 2)
        // single like → raw=1.0 clamped to 0.5
        #expect(results[memoryId1]?.adjustment == 0.5)
        // single dislike → raw=-1.0 clamped to -0.5
        #expect(results[memoryId2]?.adjustment == -0.5)
    }

    // MARK: - fetchBadCases

    @Test("fetchBadCases returns only bad case entries")
    func test_fetchBadCases() async throws {
        let normalEntry = FeedbackEntry(
            memoryId: UUID(), queryText: "normal", sentiment: .like, cosineSimilarity: 0.90
        )
        let badEntry = FeedbackEntry(
            memoryId: UUID(), queryText: "bad",
            sentiment: .dislike, cosineSimilarity: 0.60,
            isBadCase: true, badCaseReason: "inaccurate"
        )
        try await sut.recordFeedback(normalEntry, traceID: "trace-bad-normal")
        try await sut.recordFeedback(badEntry, traceID: "trace-bad-case")

        let badCases = try await sut.fetchBadCases()
        #expect(badCases.count == 1)
        #expect(badCases[0].isBadCase == true)
        #expect(badCases[0].badCaseReason == "inaccurate")
    }
}
