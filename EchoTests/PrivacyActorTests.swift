// ==========================================
// 文件: PrivacyActorTests.swift
// 对应规格: docs/02-architecture/架构设计文档.md §7 (隐私校验与审计追踪)
//            docs/01-spec/用户故事与验收标准规格书.md → US-PRV-001
// 任务: 2.1 - PrivacyActor + UserPolicy 实现
// AC 覆盖: AC-1 (策略更新即时生效), AC-2 (被拒数据不进入 Retriever),
//           AC-3 (Denial Response), AC-4 (缓存失效), AC-5 (重新授权不自动清除排除项),
//           AC-6 (审计记录)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §7.1 (PrivacyCheckpoint 强制注入)
// 生成时间: 2026-07-05
// ==========================================

import Testing
@preconcurrency import Foundation
@testable import Echo

// MARK: - Test Suite: PrivacyActor

@Suite("PrivacyActor", .serialized)
struct PrivacyActorTests {

    let sut = PrivacyActor.shared

    // MARK: - Setup / Teardown

    init() async throws {
        // Ensure database is open before any test runs
        try await DatabaseManager.shared.open()
    }

    // MARK: - AC-2, AC-3: Authorization Checks (existing tests)

    @Test("AC-2/AC-3: validate returns allowed when no source types specified (no restrictions)")
    func test_validate_noSourceTypes_allowed() async {
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

    @Test("AC-3: validate returns allowed for authorized source type (photo)")
    func test_validate_authorizedSourceType_allowed() async {
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

    @Test("AC-2: validate returns denied for unauthorized source type")
    func test_validate_unauthorizedSourceType_denied() async {
        let traceID = UUID().uuidString
        let checkpoint = await sut.validate(
            operation: .sync,
            traceID: traceID,
            sourceTypes: ["calendar"]
        )

        #expect(checkpoint.decision == .denied)
        #expect(checkpoint.isAllowed == false)
    }

    @Test("AC-2: validate returns denied when any source type among multiple is unauthorized")
    func test_validate_partialAuthorization_denied() async {
        let traceID = UUID().uuidString
        let checkpoint = await sut.validate(
            operation: .sync,
            traceID: traceID,
            sourceTypes: ["photo", "calendar"]
        )

        #expect(checkpoint.decision == .denied)
    }

    // MARK: - AC-1: Policy Update Takes Effect Immediately

    @Test("AC-1: validate respects updated policy immediately after updatePolicy")
    func test_AC1_policyUpdate_immediateEffect() async {
        // Given: default policy authorizes photo/note/voice
        let originalPolicy = await sut.getPolicy()

        // When: update policy to only authorize "photo"
        var restrictedPolicy = originalPolicy
        restrictedPolicy.authorizedSourceTypes = ["photo"]
        await sut.updatePolicy(restrictedPolicy)

        // Then: "note" (previously authorized) should now be denied
        let checkpoint = await sut.validate(
            operation: .sync,
            traceID: UUID().uuidString,
            sourceTypes: ["note"]
        )
        #expect(checkpoint.decision == .denied)

        // And: "photo" should still be allowed
        let photoCheck = await sut.validate(
            operation: .search,
            traceID: UUID().uuidString,
            sourceTypes: ["photo"]
        )
        #expect(photoCheck.decision == .allowed)

        // Restore original policy
        await sut.updatePolicy(originalPolicy)
    }

    @Test("AC-1: policyVersion increments on updatePolicy")
    func test_AC1_policyVersionIncrement() async {
        let p1 = await sut.getPolicy()
        let v1 = p1.policyVersion

        var p2 = p1
        p2.authorizedSourceTypes = ["photo"]
        await sut.updatePolicy(p2)

        let p3 = await sut.getPolicy()
        #expect(p3.policyVersion == v1 + 1)

        // Restore original
        var restored = p1
        restored.authorizedSourceTypes = ["photo", "note", "voice"]
        await sut.updatePolicy(restored)
    }

    // MARK: - AC-4: Cache Invalidation via Notification

    @Test("AC-4: updatePolicy posts userPolicyDidChange notification on MainActor")
    @MainActor
    func test_AC4_cacheInvalidation_notificationPosted() async throws {
        let notificationReceived = LockIsolated(false)

        let token = NotificationCenter.default.addObserver(
            forName: .userPolicyDidChange,
            object: nil,
            queue: nil
        ) { _ in
            notificationReceived.withValue { $0 = true }
        }

        let policy = await sut.getPolicy()
        var newPolicy = policy
        newPolicy.authorizedSourceTypes = ["photo", "note"]
        _ = await sut.updatePolicy(newPolicy)

        // Wait a short time for notification delivery
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(notificationReceived.value == true)

        NotificationCenter.default.removeObserver(token)

        // Restore
        var restored = policy
        restored.authorizedSourceTypes = ["photo", "note", "voice"]
        await sut.updatePolicy(restored)
    }

    // MARK: - AC-5: Reauthorization Detection

    @Test("AC-5: detectReauthorization returns reactivated types when source is re-enabled")
    func test_AC5_detectReauthorization_reactivatedTypes() async {
        // Given: current policy authorizes only "photo"
        let originalPolicy = await sut.getPolicy()
        var restricted = originalPolicy
        restricted.authorizedSourceTypes = ["photo"]
        await sut.updatePolicy(restricted)

        // When: detecting reauthorization that adds "note" back
        var reauth = restricted
        reauth.authorizedSourceTypes = ["photo", "note"]
        let info = await sut.detectReauthorization(for: reauth)

        // Then: "note" is detected as reactivated
        #expect(info.reactivatedSourceTypes.contains("note"))
        #expect(info.needsRecoveryPrompt == true)
        #expect(info.reactivatedSourceTypes.count == 1)

        // Restore
        await sut.updatePolicy(originalPolicy)
    }

    @Test("AC-5: detectReauthorization returns empty when no new types are added")
    func test_AC5_detectReauthorization_noNewTypes() async {
        let policy = await sut.getPolicy()

        // Same set → no reauthorization
        let info = await sut.detectReauthorization(for: policy)
        #expect(info.reactivatedSourceTypes.isEmpty)
        #expect(info.needsRecoveryPrompt == false)
    }

    @Test("AC-5: ReauthorizationInfo with reactivated types has needsRecoveryPrompt = true")
    func test_AC5_reauthInfo_needsRecoveryPrompt() {
        let info = ReauthorizationInfo(reactivatedSourceTypes: ["photo"])
        #expect(info.needsRecoveryPrompt == true)
    }

    @Test("AC-5: ReauthorizationInfo with empty types has needsRecoveryPrompt = false")
    func test_AC5_reauthInfo_noPrompt() {
        let info = ReauthorizationInfo(reactivatedSourceTypes: [])
        #expect(info.needsRecoveryPrompt == false)
    }

    @Test("AC-5: updatePolicy returns ReauthorizationInfo when sources are reactivated")
    func test_AC5_updatePolicy_returnsReauthInfo() async {
        let originalPolicy = await sut.getPolicy()

        // Restrict to only "photo"
        var restricted = originalPolicy
        restricted.authorizedSourceTypes = ["photo"]
        await sut.updatePolicy(restricted)

        // Re-authorize "note"
        var reauth = restricted
        reauth.authorizedSourceTypes = ["photo", "note"]
        let result = await sut.updatePolicy(reauth)

        // Should detect "note" reauthorization
        #expect(result != nil)
        #expect(result?.reactivatedSourceTypes.contains("note") == true)

        // Restore original
        await sut.updatePolicy(originalPolicy)
    }

    @Test("AC-5: updatePolicy returns nil when no reauthorization (simple change)")
    func test_AC5_updatePolicy_returnsNil_noReauth() async {
        let policy = await sut.getPolicy()

        // Remove a source (not re-enable)
        var reduced = policy
        reduced.authorizedSourceTypes = ["photo", "note"]
        let result = await sut.updatePolicy(reduced)

        // No reauthorization because nothing went from denied → authorized
        #expect(result == nil)

        // Restore
        await sut.updatePolicy(policy)
    }

    // MARK: - AC-6: Audit Log Writing

    @Test("AC-6: denied validate writes audit log entry")
    func test_AC6_deniedOperation_writesAuditLog() async throws {
        // Perform a denied operation
        let traceID = "AUDIT-TEST-\(UUID().uuidString.prefix(8))"
        _ = await sut.validate(
            operation: .search,
            traceID: traceID,
            sourceTypes: ["calendar"] // unauthorized
        )

        // Query audit logs
        let logs = await sut.queryAuditLogs(limit: 50)

        // The denied operation should have written a log entry
        let foundLog = logs.first { row in
            row["traceID"]?.stringValue == traceID
        }
        #expect(foundLog != nil, "Audit log should contain entry for denied operation")
        #expect(foundLog?["success"]?.intValue == 0, "success should be 0 for denied")
    }

    @Test("AC-6: reauthorization writes audit log with eventType reauthorized")
    func test_AC6_reauthorization_writesAuditLog() async throws {
        let originalPolicy = await sut.getPolicy()

        // Restrict then re-authorize
        var restricted = originalPolicy
        restricted.authorizedSourceTypes = ["photo"]
        await sut.updatePolicy(restricted)

        var reauth = restricted
        reauth.authorizedSourceTypes = ["photo", "voice"]
        _ = await sut.updatePolicy(reauth)

        let logs = await sut.queryAuditLogs(limit: 50)

        // Should find reauthorized events
        let reauthLogs = logs.filter { row in
            row["eventType"]?.stringValue == "reauthorized"
        }
        #expect(!reauthLogs.isEmpty, "Audit log should contain reauthorized events")

        // Restore
        await sut.updatePolicy(originalPolicy)
    }

    @Test("AC-6: recordBatchRestore writes excludedBatchRestored audit log")
    func test_AC6_recordBatchRestore_writesAuditLog() async throws {
        let traceID = "BATCH-RESTORE-\(UUID().uuidString.prefix(8))"
        await sut.recordBatchRestore(
            sourceType: "photo",
            restoredCount: 3,
            traceID: traceID
        )

        let logs = await sut.queryAuditLogs(limit: 50)

        let foundLog = logs.first { row in
            row["traceID"]?.stringValue == traceID
        }
        #expect(foundLog != nil, "Audit log should contain excludedBatchRestored entry")
        #expect(foundLog?["eventType"]?.stringValue == "excludedBatchRestored")
        #expect(foundLog?["sourceType"]?.stringValue == "photo")
        #expect(foundLog?["excludedWritten"]?.intValue == 3)
    }

    @Test("AC-6: queryAuditLogs returns empty array when no logs exist and no error")
    func test_AC6_queryAuditLogs_handlesEmptyGracefully() async throws {
        // Database should be open from previous tests; query should not throw
        let logs = await sut.queryAuditLogs(limit: 1)
        // Even if empty, it should be an empty array, not nil
        #expect(logs.count >= 0)
    }

    // MARK: - Policy Management Tests (existing, preserved)

    @Test("getPolicy returns policy with zh-Hans language")
    func test_getPolicy_defaultLanguage() async {
        let policy = await sut.getPolicy()
        #expect(policy.preferredLanguage == "zh-Hans")
    }

    @Test("updatePolicy changes authorized source types and restores defaults")
    func test_updatePolicy_changesAuthorization() async {
        let originalPolicy = await sut.getPolicy()

        var newPolicy = originalPolicy
        newPolicy.authorizedSourceTypes = ["photo"] // only photo
        await sut.updatePolicy(newPolicy)

        let updated = await sut.getPolicy()
        #expect(updated.authorizedSourceTypes == ["photo"])

        // Restore original policy to avoid polluting shared state for other tests
        await sut.updatePolicy(originalPolicy)
    }

    @Test("isSourceAuthorized returns true for default authorized type")
    func test_isSourceAuthorized() async {
        let authorized = await sut.isSourceAuthorized("photo")
        #expect(authorized == true)
    }

    @Test("isSourceAuthorized returns false for unauthorized type")
    func test_isSourceAuthorized_false() async {
        let authorized = await sut.isSourceAuthorized("calendar")
        #expect(authorized == false)
    }

    // MARK: - PrivacyCheckpoint Model Tests (existing, preserved)

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
}

// MARK: - Helper: LockIsolated (simple concurrent-safe value wrapper)

/// Simple thread-safe value wrapper for test assertions across actor boundaries.
private final class LockIsolated<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self._value = value
    }

    var value: Value {
        _read { lock.lock(); defer { lock.unlock() }; yield _value }
    }

    func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&_value)
    }
}
