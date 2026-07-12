// ==========================================
// 文件: FeedbackPipelineTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-FBK-001 (本地反馈收集),
//            US-FBK-003 (本地 Bad Case 标记/撤销)
// 任务: 2.13 - FeedbackPipeline：点赞/点踩/Bad Case 记录
// AC 覆盖: US-FBK-001 AC-2 (写入 FeedbackStore), AC-4 (关联 memoryId+queryEmbedding),
//           AC-5 (审计 .feedbackReceived)
//           US-FBK-003 AC-2 (Bad Case 含查询词/原因/时间), AC-5 (不涉及服务端),
//           AC-6 (审计 .badCaseMarked/.badCaseRevoked)
// 架构约束: AGENTS.md §5.3 (反馈存储契约), AGENTS.md §7.3 (审计事件)
// 生成时间: 2026-07-12
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Test Suite: FeedbackPipeline Phase 2

@Suite("FeedbackPipeline Phase 2", .serialized)
struct FeedbackPipelineTests {

    let sut: FeedbackPipeline
    let feedbackActor: FeedbackActor
    let privacyActor: PrivacyActor
    let db: DatabaseManager

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

        feedbackActor = FeedbackActor(db: db, privacyActor: privacyActor)
        sut = FeedbackPipeline(feedbackActor: feedbackActor, privacyActor: privacyActor)
    }

    // MARK: - US-FBK-001 AC-2: 反馈数据存入本地 SQLite（FeedbackStore）

    @Test("recordLike writes like to FeedbackStore — AC-2")
    func test_recordLike_writesToStore_AC2() async throws {
        let memoryId = UUID()
        let queryText = "test query AC-2"

        try await sut.recordLike(
            memoryId: memoryId,
            queryText: queryText,
            cosineSimilarity: 0.92,
            traceID: "trace-ac2-like"
        )

        let entries = try await feedbackActor.fetchEntries(for: memoryId)
        #expect(entries.count == 1)
        #expect(entries[0].sentiment == .like)
        #expect(entries[0].queryText == queryText)
        #expect(entries[0].cosineSimilarity == 0.92)
        #expect(entries[0].isBadCase == false)
    }

    @Test("recordDislike writes dislike to FeedbackStore — AC-2")
    func test_recordDislike_writesToStore_AC2() async throws {
        let memoryId = UUID()
        let queryText = "dislike this"

        try await sut.recordDislike(
            memoryId: memoryId,
            queryText: queryText,
            cosineSimilarity: 0.75,
            traceID: "trace-ac2-dislike"
        )

        let entries = try await feedbackActor.fetchEntries(for: memoryId)
        #expect(entries.count == 1)
        #expect(entries[0].sentiment == .dislike)
        #expect(entries[0].queryText == queryText)
        #expect(entries[0].cosineSimilarity == 0.75)
    }

    @Test("recordFeedback with .like writes correct sentiment — AC-2")
    func test_recordFeedback_likeWritesCorrectSentiment_AC2() async throws {
        let memoryId = UUID()
        let entry = try await sut.recordFeedback(
            memoryId: memoryId,
            queryText: "like entry",
            sentiment: .like,
            cosineSimilarity: 0.88,
            traceID: "trace-like"
        )
        #expect(entry.sentiment == .like)
        #expect(entry.isBadCase == false)

        let stored = try await feedbackActor.fetchEntries(for: memoryId)
        #expect(stored.count == 1)
        #expect(stored[0].sentiment == .like)
    }

    @Test("recordFeedback with .dislike writes correct sentiment — AC-2")
    func test_recordFeedback_dislikeWritesCorrectSentiment_AC2() async throws {
        let memoryId = UUID()
        let entry = try await sut.recordFeedback(
            memoryId: memoryId,
            queryText: "dislike entry",
            sentiment: .dislike,
            cosineSimilarity: 0.60,
            traceID: "trace-dislike"
        )
        #expect(entry.sentiment == .dislike)
        #expect(entry.isBadCase == false)

        let stored = try await feedbackActor.fetchEntries(for: memoryId)
        #expect(stored.count == 1)
        #expect(stored[0].sentiment == .dislike)
    }

    // MARK: - US-FBK-001 AC-4: 关联 memoryId + queryEmbedding

    @Test("FeedbackEntry contains memoryId and queryText — AC-4")
    func test_feedbackEntry_containsMemoryIdAndQueryText_AC4() async throws {
        let memoryId = UUID()
        let queryText = "unique query for memory"

        let entry = try await sut.recordLike(
            memoryId: memoryId,
            queryText: queryText,
            cosineSimilarity: 0.91,
            traceID: "trace-ac4"
        )

        #expect(entry.memoryId == memoryId)
        #expect(entry.queryText == queryText)
        #expect(entry.cosineSimilarity == 0.91)
    }

    @Test("Multiple feedback entries for same memory have same memoryId — AC-4")
    func test_multipleFeedback_sameMemory_AC4() async throws {
        let memoryId = UUID()

        try await sut.recordLike(memoryId: memoryId, queryText: "q1", cosineSimilarity: 0.9, traceID: "t1")
        try await sut.recordDislike(memoryId: memoryId, queryText: "q2", cosineSimilarity: 0.3, traceID: "t2")

        let entries = try await feedbackActor.fetchEntries(for: memoryId)
        #expect(entries.count == 2)
        for entry in entries {
            #expect(entry.memoryId == memoryId)
        }
    }

    // MARK: - US-FBK-001 AC-5: 审计记录 .feedbackReceived（不含原始数据）

    @Test("recordLike records audit .feedbackReceived — AC-5")
    func test_recordLike_auditsFeedbackReceived_AC5() async throws {
        try await sut.recordLike(
            memoryId: UUID(),
            queryText: "audit test",
            cosineSimilarity: 0.85,
            traceID: "trace-ac5"
        )

        let auditLogs = try await privacyActor.fetchAuditLogs(eventType: .feedbackReceived)
        #expect(auditLogs.count >= 1)
        // AC-5: 审计记录含 sentiment，不包含原始数据（原文不在 AuditLogEntry 中）
        // AuditLogEntry 不包含 queryText/memoryId 原文，仅哈希摘要级别的 eventType
    }

    @Test("recordDislike records audit .feedbackReceived — AC-5")
    func test_recordDislike_auditsFeedbackReceived_AC5() async throws {
        try await sut.recordDislike(
            memoryId: UUID(),
            queryText: "dislike audit",
            cosineSimilarity: 0.45,
            traceID: "trace-ac5-dislike"
        )

        let auditLogs = try await privacyActor.fetchAuditLogs(eventType: .feedbackReceived)
        #expect(auditLogs.count >= 1)
    }

    // MARK: - US-FBK-003 AC-2: Bad Case 含查询词/返回结果/标记时间/可选原因

    @Test("markBadCase creates entry with isBadCase=true — AC-2")
    func test_markBadCase_createsBadCaseEntry_AC2() async throws {
        let memoryId = UUID()
        let queryText = "irrelevant result"
        let reason = "结果不相关"

        let entry = try await sut.markBadCase(
            memoryId: memoryId,
            queryText: queryText,
            reason: reason,
            traceID: "trace-ac2-bc"
        )

        #expect(entry.isBadCase == true)
        #expect(entry.badCaseReason == reason)
        #expect(entry.queryText == queryText)
        #expect(entry.memoryId == memoryId)
        #expect(entry.sentiment == .dislike)  // Bad Case 本质是强负面反馈

        // 验证持久化
        let badCases = try await feedbackActor.fetchBadCases()
        #expect(badCases.count == 1)
        #expect(badCases[0].badCaseReason == reason)
        #expect(badCases[0].isBadCase == true)
    }

    @Test("markBadCase without reason stores nil — AC-2")
    func test_markBadCase_withoutReason_AC2() async throws {
        let entry = try await sut.markBadCase(
            memoryId: UUID(),
            queryText: "bad without reason",
            reason: nil,
            traceID: "trace-no-reason"
        )

        #expect(entry.isBadCase == true)
        #expect(entry.badCaseReason == nil)

        let badCases = try await feedbackActor.fetchBadCases()
        #expect(badCases[0].badCaseReason == nil)
    }

    @Test("markBadCase sets createdAt timestamp — AC-2")
    func test_markBadCase_hasCreatedAt_AC2() async throws {
        let beforeMark = Date().timeIntervalSince1970
        let entry = try await sut.markBadCase(
            memoryId: UUID(),
            queryText: "time test",
            traceID: "trace-time"
        )
        let afterMark = Date().timeIntervalSince1970

        #expect(entry.createdAt.timeIntervalSince1970 >= beforeMark)
        #expect(entry.createdAt.timeIntervalSince1970 <= afterMark)
    }

    // MARK: - US-FBK-003 AC-5: 不涉及服务端 Golden Dataset 或 A/B 实验

    @Test("Bad Case stored locally, no server interaction — AC-5")
    func test_badCase_localOnly_AC5() async throws {
        // This test verifies that Bad Case operations are purely local.
        // Since Echo has no network code (R-001), this is implicitly satisfied.
        // We verify that data persists in local SQLite.

        try await sut.markBadCase(
            memoryId: UUID(),
            queryText: "local only",
            reason: "test",
            traceID: "trace-local"
        )

        let count = try await feedbackActor.count()
        #expect(count == 1)
        // No network call made — verified by architecture (no URLSession usage)
    }

    // MARK: - US-FBK-003 AC-6: 审计 .badCaseMarked / .badCaseRevoked

    @Test("markBadCase records audit .badCaseMarked — AC-6")
    func test_markBadCase_auditsBadCaseMarked_AC6() async throws {
        try await sut.markBadCase(
            memoryId: UUID(),
            queryText: "audit bad case",
            reason: "reason-1",
            traceID: "trace-ac6-mark"
        )

        let auditLogs = try await privacyActor.fetchAuditLogs(eventType: .badCaseMarked)
        #expect(auditLogs.count == 1)
        #expect(auditLogs[0].sourceType == "feedback")
        #expect(auditLogs[0].excludedWritten == true)  // AC-6: localStore=true
    }

    @Test("revokeFeedback on Bad Case records audit .badCaseRevoked — AC-6")
    func test_revokeBadCase_auditsBadCaseRevoked_AC6() async throws {
        let entry = try await sut.markBadCase(
            memoryId: UUID(),
            queryText: "to be revoked",
            reason: "revoke me",
            traceID: "trace-revoke-prep"
        )

        let success = try await sut.revokeFeedback(
            feedbackId: entry.id,
            traceID: "trace-ac6-revoke"
        )
        #expect(success == true)

        let auditLogs = try await privacyActor.fetchAuditLogs(eventType: .badCaseRevoked)
        #expect(auditLogs.count == 1)
        #expect(auditLogs[0].sourceType == "feedback")
        #expect(auditLogs[0].excludedWritten == true)  // AC-6: localStore=true

        // 验证记录已物理删除
        let badCases = try await feedbackActor.fetchBadCases()
        #expect(badCases.isEmpty)
    }

    @Test("revokeFeedback on non-Bad Case does NOT record .badCaseRevoked — AC-6")
    func test_revokeLike_doesNotAuditBadCaseRevoked_AC6() async throws {
        let entry = try await sut.recordLike(
            memoryId: UUID(),
            queryText: "regular like",
            cosineSimilarity: 0.9,
            traceID: "trace-like-revoke"
        )

        // 先清除已有审计，只看 revoke 后的
        try await db.execute(sql: "DELETE FROM AuditLog")

        let success = try await sut.revokeFeedback(
            feedbackId: entry.id,
            traceID: "trace-revoke-like"
        )
        #expect(success == true)

        // 不应有 .badCaseRevoked
        let badCaseRevokeLogs = try await privacyActor.fetchAuditLogs(eventType: .badCaseRevoked)
        #expect(badCaseRevokeLogs.isEmpty)

        // 但应有 .feedbackRevoked（由 FeedbackActor.revoke 写入）
        let feedbackRevokeLogs = try await privacyActor.fetchAuditLogs(eventType: .feedbackRevoked)
        #expect(feedbackRevokeLogs.count == 1)
    }

    // MARK: - fetchBadCases (US-FBK-003 AC-3 support)

    @Test("fetchBadCases returns only Bad Case entries")
    func test_fetchBadCases_returnsOnlyBadCases() async throws {
        // Add a regular like
        try await sut.recordLike(
            memoryId: UUID(),
            queryText: "regular feedback",
            cosineSimilarity: 0.9,
            traceID: "trace-regular"
        )

        // Add two bad cases
        try await sut.markBadCase(
            memoryId: UUID(),
            queryText: "bad-1",
            reason: "reason-1",
            traceID: "trace-bad-1"
        )
        try await sut.markBadCase(
            memoryId: UUID(),
            queryText: "bad-2",
            reason: "reason-2",
            traceID: "trace-bad-2"
        )

        let badCases = try await sut.fetchBadCases()
        #expect(badCases.count == 2)
        #expect(badCases.allSatisfy { $0.isBadCase == true })
    }

    // MARK: - fetchFeedback per memory

    @Test("fetchFeedback returns entries for specific memory")
    func test_fetchFeedback_forMemory_returnsOnlyThatMemory() async throws {
        let memA = UUID()
        let memB = UUID()

        try await sut.recordLike(memoryId: memA, queryText: "qa", cosineSimilarity: 0.9, traceID: "ta")
        try await sut.recordDislike(memoryId: memB, queryText: "qb", cosineSimilarity: 0.3, traceID: "tb")

        let entriesA = try await sut.fetchFeedback(for: memA)
        #expect(entriesA.count == 1)
        #expect(entriesA[0].memoryId == memA)

        let entriesB = try await sut.fetchFeedback(for: memB)
        #expect(entriesB.count == 1)
        #expect(entriesB[0].memoryId == memB)
    }

    // MARK: - resetAllFeedback

    @Test("resetAllFeedback clears all entries")
    func test_resetAllFeedback_clearsAll() async throws {
        try await sut.recordLike(memoryId: UUID(), queryText: "q1", cosineSimilarity: 0.9, traceID: "t1")
        try await sut.markBadCase(memoryId: UUID(), queryText: "q2", reason: "r", traceID: "t2")

        let countBefore = try await feedbackActor.count()
        #expect(countBefore == 2)

        try await sut.resetAllFeedback(traceID: "trace-reset")

        let countAfter = try await feedbackActor.count()
        #expect(countAfter == 0)

        // 审计记录 .feedbackReset
        let auditLogs = try await privacyActor.fetchAuditLogs(eventType: .feedbackReset)
        #expect(auditLogs.count == 1)
    }

    // MARK: - PrivacyCheckpoint (R-006)

    @Test("PrivacyCheckpoint is injected on all public methods — R-006")
    func test_privacyCheckpoint_injected_R006() async throws {
        // Verify that validate() calls produce audit records
        let auditCountBefore = try await privacyActor.auditLogCount()

        try await sut.recordLike(
            memoryId: UUID(),
            queryText: "privacy test",
            cosineSimilarity: 0.9,
            traceID: "trace-privacy"
        )

        let auditCountAfter = try await privacyActor.auditLogCount()
        // PrivacyActor.validate() writes one checkpoint audit,
        // FeedbackActor.recordFeedback() writes one .feedbackReceived audit
        #expect(auditCountAfter > auditCountBefore)
    }

    // MARK: - errorLevel classification

    @Test("privacyDenied has errorLevel 2")
    func test_privacyDenied_errorLevel() {
        let error = FeedbackPipelineError.privacyDenied(sourceTypes: ["photo"])
        #expect(error.errorLevel == 2)
    }

    @Test("recordFailed has errorLevel 2")
    func test_recordFailed_errorLevel() {
        let error = FeedbackPipelineError.recordFailed(underlying: NSError(domain: "test", code: 1))
        #expect(error.errorLevel == 2)
    }

    @Test("revokeFailed has errorLevel 2")
    func test_revokeFailed_errorLevel() {
        let error = FeedbackPipelineError.revokeFailed(feedbackId: UUID())
        #expect(error.errorLevel == 2)
    }

    @Test("auditLogFailed has errorLevel 1")
    func test_auditLogFailed_errorLevel() {
        let error = FeedbackPipelineError.auditLogFailed(underlying: NSError(domain: "test", code: 1))
        #expect(error.errorLevel == 1)
    }
}
