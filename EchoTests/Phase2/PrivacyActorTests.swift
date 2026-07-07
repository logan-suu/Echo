// ==========================================
// 文件: PrivacyActorTests.swift
// 对应规格: docs/02-architecture/架构设计文档.md §7 (隐私校验与审计追踪)
//            docs/01-spec/用户故事与验收标准规格书.md → US-PRV-001
// 任务: 1.8 - 搭建单元测试框架，编写第一个 Actor 测试用例
//       2.1 - PrivacyActor + UserPolicy 实现 (Full Implementation)
// AC 覆盖: US-PRV-001 AC-1 (策略即时生效), AC-2 (被拒数据不进 Retriever),
//          AC-3 (Denial Response), AC-4 (缓存失效), AC-5 (重新授权不清除排除表),
//          AC-6 (审计记录 .denied/.reauthorized)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §7.1 (PrivacyCheckpoint 强制注入)
//           §7.3 (审计日志), §5.4 (30天保留)
// 生成时间: 2026-07-05 (Stub), 2026-07-07 (Task 2.1 Full Implementation)
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Test Suite: PrivacyActor

@Suite("PrivacyActor", .serialized)
struct PrivacyActorTests {

    let sut = PrivacyActor.shared
    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
        // Clean audit logs and policy from previous runs
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        // Reset to known defaults
        try await sut.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice"],
            policyVersion: 1
        ))
    }

    // MARK: - PrivacyCheckpoint Tests (Existing, AC-1/2/3)

    @Test("validate returns allowed when no source types specified (no restrictions)")
    func test_validate_noSourceTypes_allowed() async throws {
        let traceID = UUID().uuidString
        let checkpoint = await sut.validate(
            operation: .search,
            traceID: traceID,
            sourceTypes: []
        )

        #expect(checkpoint.decision == .allowed)
        #expect(checkpoint.traceID == traceID)
        #expect(checkpoint.operation == .search)
        #expect(checkpoint.isAllowed == true)
    }

    @Test("validate returns allowed for authorized source type (photo)")
    func test_validate_authorizedSourceType_allowed() async throws {
        let traceID = UUID().uuidString
        let checkpoint = await sut.validate(
            operation: .ingest,
            traceID: traceID,
            sourceTypes: ["photo"]
        )

        #expect(checkpoint.decision == .allowed)
        #expect(checkpoint.operation == .ingest)
        #expect(checkpoint.sourceTypes == ["photo"])
    }

    @Test("validate returns denied for unauthorized source type — AC-2/AC-3")
    func test_validate_unauthorizedSourceType_denied() async throws {
        let traceID = UUID().uuidString
        let checkpoint = await sut.validate(
            operation: .sync,
            traceID: traceID,
            sourceTypes: ["calendar"] // not in default authorized set
        )

        #expect(checkpoint.decision == .denied)
        #expect(checkpoint.isAllowed == false)
    }

    @Test("validate returns denied when any source type among multiple is unauthorized — AC-3")
    func test_validate_partialAuthorization_denied() async throws {
        let traceID = UUID().uuidString
        // "photo" is authorized, "calendar" is not — all must pass
        let checkpoint = await sut.validate(
            operation: .sync,
            traceID: traceID,
            sourceTypes: ["photo", "calendar"]
        )

        #expect(checkpoint.decision == .denied)
    }

    // MARK: - Policy Management Tests (AC-1: 策略即时生效)

    @Test("getPolicy returns policy with zh-Hans language and version 1")
    func test_getPolicy_defaultPolicy() async throws {
        let policy = await sut.getPolicy()

        #expect(policy.preferredLanguage == "zh-Hans")
        #expect(policy.policyVersion == 1)
    }

    @Test("updatePolicy changes authorized source types — AC-1: takes effect before next validate")
    func test_updatePolicy_changesAuthorization() async throws {
        let originalPolicy = await sut.getPolicy()

        // Revoke "note" authorization
        var newPolicy = originalPolicy
        newPolicy.authorizedSourceTypes = ["photo"]
        try await sut.updatePolicy(newPolicy)

        let updated = await sut.getPolicy()
        #expect(updated.authorizedSourceTypes == ["photo"])

        // AC-1: 策略即时生效 — validate should now deny "note"
        let checkpoint = await sut.validate(
            operation: .ingest,
            traceID: UUID().uuidString,
            sourceTypes: ["note"]
        )
        #expect(checkpoint.decision == .denied, "AC-1: 策略更新后下一次检索调用前已生效")

        // Now re-authorize "note" — should be allowed again
        var reAuthPolicy = updated
        reAuthPolicy.authorizedSourceTypes = ["photo", "note"]
        try await sut.updatePolicy(reAuthPolicy)

        let reCheckpoint = await sut.validate(
            operation: .ingest,
            traceID: UUID().uuidString,
            sourceTypes: ["note"]
        )
        #expect(reCheckpoint.decision == .allowed, "AC-1: 重新授权后即时生效")

        // Restore original policy
        try await sut.updatePolicy(originalPolicy)
    }

    @Test("isSourceAuthorized returns true for default authorized type")
    func test_isSourceAuthorized() async throws {
        let authorized = await sut.isSourceAuthorized("photo")
        #expect(authorized == true)
    }

    @Test("isSourceAuthorized returns false for unauthorized type")
    func test_isSourceAuthorized_false() async throws {
        let authorized = await sut.isSourceAuthorized("calendar")
        #expect(authorized == false)
    }

    // MARK: - Audit Log Tests (AC-6: 审计记录)

    @Test("validate writes audit log entry — AC-6: records decision and policyVersion")
    func test_validate_writesAuditLog() async throws {
        let traceID = UUID().uuidString
        _ = await sut.validate(
            operation: .ingest,
            traceID: traceID,
            sourceTypes: ["photo"]
        )

        let logs = try await sut.fetchAuditLogs(limit: 10)
        #expect(!logs.isEmpty, "validate() should write audit log entry")

        // AC-6: 审计记录含 decision, traceID, policyVersion
        let matching = logs.filter { $0.traceID == traceID }
        #expect(!matching.isEmpty, "应该能找到对应 traceID 的审计记录")
        #expect(matching.first?.policyVersion == 1)
        #expect(matching.first?.success == true)
    }

    @Test("validate denied operation writes success=false audit log — AC-6")
    func test_validate_denied_writesAuditLog_failure() async throws {
        let traceID = UUID().uuidString
        _ = await sut.validate(
            operation: .ingest,
            traceID: traceID,
            sourceTypes: ["calendar"] // unauthorized
        )

        let logs = try await sut.fetchAuditLogs(limit: 10)
        let denied = logs.filter { $0.traceID == traceID }
        #expect(!denied.isEmpty, "AC-6: 拒绝操作应写入审计日志")
        #expect(denied.first?.success == false, "AC-6: decision=.denied → success=false")
    }

    @Test("writeAuditLog persists entry with all fields")
    func test_writeAuditLog_allFields() async throws {
        let traceID = UUID().uuidString
        try await sut.writeAuditLog(
            eventType: .memoryIngested,
            traceID: traceID,
            policyVersion: 2,
            success: true,
            sourceType: "photo",
            affectedCount: 42,
            excludedWritten: false,
            sourceLanguage: "zh-Hans",
            elapsedMs: 150
        )

        let logs = try await sut.fetchAuditLogs(limit: 1)
        let entry = logs.first(where: { $0.traceID == traceID })
        #expect(entry != nil)
        #expect(entry?.eventType == .memoryIngested)
        #expect(entry?.policyVersion == 2)
        #expect(entry?.sourceType == "photo")
        #expect(entry?.affectedCount == 42)
        #expect(entry?.excludedWritten == false)
        #expect(entry?.sourceLanguage == "zh-Hans")
        #expect(entry?.elapsedMs == 150)
    }

    @Test("fetchAuditLogs by eventType filter works")
    func test_fetchAuditLogs_byEventType() async throws {
        let tid1 = UUID().uuidString
        let tid2 = UUID().uuidString
        try await sut.writeAuditLog(eventType: .memoryIngested, traceID: tid1, policyVersion: 1)
        try await sut.writeAuditLog(eventType: .memoryDeleted, traceID: tid2, policyVersion: 1)

        let ingested = try await sut.fetchAuditLogs(eventType: .memoryIngested)
        #expect(ingested.allSatisfy { $0.eventType == .memoryIngested })
    }

    @Test("auditLogCount returns correct count")
    func test_auditLogCount() async throws {
        let before = try await sut.auditLogCount()
        try await sut.writeAuditLog(eventType: .memoryDeleted, traceID: UUID().uuidString, policyVersion: 1)
        let after = try await sut.auditLogCount()
        #expect(after == before + 1)
    }

    // MARK: - Cleanup Tests (AGENTS.md §5.4: 30-day retention)

    @Test("cleanupOldAuditLogs removes entries older than retentionDays")
    func test_cleanupOldAuditLogs_removesOldEntries() async throws {
        // First ensure cleanup area is clean
        try await db.execute(sql: "DELETE FROM AuditLog")

        // Write an old audit log entry directly (50 days ago)
        let oldTimestamp = Date().timeIntervalSince1970 - Double(50 * 86400)
        try await db.executeWrite(
            sql: "INSERT INTO AuditLog (eventType, timestamp, traceID, policyVersion, success) VALUES (?, ?, ?, ?, ?)",
            bindings: [
                .text("reauthorized"),
                .double(oldTimestamp),
                .text(UUID().uuidString),
                .int(1),
                .int(1),
            ]
        )

        // Write a recent entry (1 day ago)
        let recentTimestamp = Date().timeIntervalSince1970 - 86400
        try await db.executeWrite(
            sql: "INSERT INTO AuditLog (eventType, timestamp, traceID, policyVersion, success) VALUES (?, ?, ?, ?, ?)",
            bindings: [
                .text("reauthorized"),
                .double(recentTimestamp),
                .text(UUID().uuidString),
                .int(1),
                .int(1),
            ]
        )

        // Cleanup with 30-day retention
        let removed = try await sut.cleanupOldAuditLogs(retentionDays: 30)

        #expect(removed >= 1, "应该删除超过30天的记录")

        let remaining = try await sut.auditLogCount()
        #expect(remaining > 0, "1天前的记录应该保留")
    }

    @Test("cleanupOldAuditLogs returns 0 when nothing to clean")
    func test_cleanupOldAuditLogs_noOldEntries() async throws {
        try await db.execute(sql: "DELETE FROM AuditLog")
        // Write only a recent entry
        try await sut.writeAuditLog(eventType: .feedbackReceived, traceID: UUID().uuidString, policyVersion: 1)
        let removed = try await sut.cleanupOldAuditLogs(retentionDays: 30)
        #expect(removed == 0, "没有超过30天的记录，不应删除任何东西")
    }

    // MARK: - Policy Persistence Tests (AC-1)

    @Test("loadPolicy restores policy from SQLite UserPolicyStore")
    func test_loadPolicy_restoresPersistedPolicy() async throws {
        // Save a known policy
        var customPolicy = UserPolicy(
            preferredLanguage: "en-US",
            authorizedSourceTypes: ["voice"],
            policyVersion: 5
        )
        try await sut.updatePolicy(customPolicy)

        // Reset in-memory state by creating a new instance scenario:
        // loadPolicy from DB should restore the persisted policy
        try await sut.loadPolicy()
        let loaded = await sut.getPolicy()

        #expect(loaded.preferredLanguage == "en-US", "AC-1: 持久化策略应从 SQLite 恢复")
        #expect(loaded.authorizedSourceTypes == ["voice"])
        #expect(loaded.policyVersion == 5)

        // Restore defaults
        try await sut.updatePolicy(UserPolicy())
    }

    // MARK: - AC-5: Re-authorization Tests

    @Test("updatePolicy detects reauthorized source types — AC-5")
    func test_updatePolicy_detectsReauthorization() async throws {
        // Start with only "photo" authorized
        try await sut.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo"],
            policyVersion: 1
        ))

        // Re-authorize "note" — AC-5: 重新授权时不应清除 ExcludedAssets
        // (ExcludedAssets management is handled by ExcludedAssetsActor; PrivacyActor records the event)
        try await sut.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note"],
            policyVersion: 2
        ))

        let policy = await sut.getPolicy()
        #expect(policy.authorizedSourceTypes.contains("note"), "AC-5: note 应该已被重新授权")
        #expect(policy.policyVersion == 2)

        // AC-6: 应记录 .reauthorized 审计事件
        let reauthLogs = try await sut.fetchAuditLogs(eventType: .reauthorized)
        #expect(!reauthLogs.isEmpty, "AC-6: 重新授权应写入 .reauthorized 审计记录")

        // Restore defaults
        try await sut.updatePolicy(UserPolicy())
    }

    @Test("updatePolicy detects revoked source types — writes .permissionChanged audit")
    func test_updatePolicy_detectsRevocation() async throws {
        // Start with full authorization
        try await sut.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice"],
            policyVersion: 3
        ))

        // Revoke "voice"
        try await sut.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note"],
            policyVersion: 4
        ))

        let policy = await sut.getPolicy()
        #expect(!policy.authorizedSourceTypes.contains("voice"), "voice 应该已被撤销")
        #expect(policy.policyVersion == 4)

        let permLogs = try await sut.fetchAuditLogs(eventType: .permissionChanged)
        let voiceRevoked = permLogs.filter { $0.sourceType == "voice" }
        #expect(!voiceRevoked.isEmpty, "撤销 voice 授权应记录 .permissionChanged 审计事件")

        // Restore defaults
        try await sut.updatePolicy(UserPolicy())
    }

    @Test("recordReauthorization writes .reauthorized audit with excludedBatchRestored flag — AC-6")
    func test_recordReauthorization_withExcludedBatchRestored() async throws {
        let traceID = UUID().uuidString
        try await sut.recordReauthorization(
            sourceType: "photo",
            excludedBatchRestored: true,
            traceID: traceID
        )

        let logs = try await sut.fetchAuditLogs(eventType: .reauthorized)
        let entry = logs.first(where: { $0.traceID == traceID })
        #expect(entry != nil, "AC-6: recordReauthorization 应写入审计日志")
        #expect(entry?.sourceType == "photo")
        #expect(entry?.excludedWritten == true, "AC-6: excludedBatchRestored 应记录到审计日志")
    }

    @Test("recordPermissionChanged writes .permissionChanged audit — AC-6")
    func test_recordPermissionChanged() async throws {
        let traceID = UUID().uuidString
        try await sut.recordPermissionChanged(
            sourceType: "calendar",
            traceID: traceID
        )

        let logs = try await sut.fetchAuditLogs(eventType: .permissionChanged)
        let entry = logs.first(where: { $0.traceID == traceID })
        #expect(entry != nil, "AC-6: recordPermissionChanged 应写入审计日志")
        #expect(entry?.sourceType == "calendar")
        #expect(entry?.success == true)
    }

    // MARK: - PrivacyCheckpoint Model Tests

    @Test("PrivacyCheckpoint.isAllowed returns true when decision is allowed")
    func test_checkpoint_isAllowed_true() {
        let checkpoint = PrivacyCheckpoint(
            traceID: "test",
            operation: .search,
            decision: .allowed
        )
        #expect(checkpoint.isAllowed == true)
    }

    @Test("PrivacyCheckpoint.isAllowed returns false when decision is denied")
    func test_checkpoint_isAllowed_false() {
        let checkpoint = PrivacyCheckpoint(
            traceID: "test",
            operation: .search,
            decision: .denied
        )
        #expect(checkpoint.isAllowed == false)
    }

    @Test("PrivacyOperation is Codable round-trip")
    func test_privacyOperation_codable() throws {
        let ops: [PrivacyOperation] = [.search, .ingest, .sync, .delete, .awakening, .feedback]
        for op in ops {
            let data = try JSONEncoder().encode(op)
            let decoded = try JSONDecoder().decode(PrivacyOperation.self, from: data)
            #expect(decoded == op)
        }
    }

    // MARK: - AuditEvent & AuditLogEntry Model Tests

    @Test("AuditEvent all cases are Codable round-trip")
    func test_auditEvent_allCasesCodable() throws {
        let events: [AuditEvent] = [
            .dataSourceConnected,
            .permissionChanged,
            .reauthorized,
            .excludedBatchRestored,
            .memoryIngested,
            .memoryDeleted,
            .feedbackReceived,
        ]
        for event in events {
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(AuditEvent.self, from: data)
            #expect(decoded == event)
        }
    }

    @Test("AuditLogEntry fromRow returns nil for invalid row")
    func test_auditLogEntry_fromRow_invalid() {
        let invalidRow: [String: DBValue] = [:]
        let result = AuditLogEntry.fromRow(invalidRow)
        #expect(result == nil, "空行应返回 nil")
    }

    @Test("AuditLogEntry fromRow constructs valid entry")
    func test_auditLogEntry_fromRow_valid() {
        let row: [String: DBValue] = [
            "id": .int(1),
            "eventType": .text("reauthorized"),
            "timestamp": .double(Date().timeIntervalSince1970),
            "traceID": .text(UUID().uuidString),
            "policyVersion": .int(3),
            "success": .int(1),
            "sourceType": .text("photo"),
            "affectedCount": .int(10),
            "excludedWritten": .int(0),
            "sourceLanguage": .text("zh-Hans"),
            "elapsedMs": .int(200),
        ]
        let entry = AuditLogEntry.fromRow(row)
        #expect(entry != nil)
        #expect(entry?.eventType == .reauthorized)
        #expect(entry?.policyVersion == 3)
        #expect(entry?.sourceType == "photo")
    }
}
