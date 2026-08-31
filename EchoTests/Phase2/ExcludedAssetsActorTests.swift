// ==========================================
// 文件: ExcludedAssetsActorTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-008
// 任务: 2.2 - ExcludedAssetsActor 实现（含恢复、一键恢复、变更监测）
// AC 覆盖: US-SRC-008 AC-3~8
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007/R-008, AGENTS.md §5.2
// 注意: restore()/checkForChanges() 的 PHAsset 边界场景在 Phase 4 集成测试覆盖。
//       此处验证 Actor 的核心 SQL + 审计逻辑。
// 生成时间: 2026-07-08
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Test Suite: ExcludedAssetsActor

@Suite("ExcludedAssetsActor Phase 2", .serialized)
struct ExcludedAssetsActorPhase2Tests {

    let sut: ExcludedAssetsActor
    let db: DatabaseManager
    let privacyActor: PrivacyActor

    init() async throws {
        db = DatabaseManager.shared
        try await db.open()
        // Clean state
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")

        privacyActor = PrivacyActor.shared
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice"],
            policyVersion: 1
        ))

        sut = ExcludedAssetsActor(db: db, privacyActor: privacyActor)
    }

    // MARK: - AC-3: Add / Contains / Count

    @Test("add writes to ExcludedAssets table — AC-3")
    func test_add_writesToTable() async throws {
        try await sut.add(assetId: "asset-001", sourceType: "photo")

        let exists = try await sut.contains(assetId: "asset-001")
        #expect(exists)
    }

    @Test("add records .excluded audit event — AC-8")
    func test_add_recordsExcludedAudit() async throws {
        try await sut.add(assetId: "asset-001", sourceType: "photo", traceID: "trace-add-1")

        let logs = try await privacyActor.fetchAuditLogs(eventType: .excluded)
        #expect(logs.count >= 1)
        let log = logs.first!
        #expect(log.eventType == .excluded)
        #expect(log.traceID == "trace-add-1")
        #expect(log.sourceType == "photo")
        #expect(log.excludedWritten == true)
        #expect(log.affectedCount == 1)
        #expect(log.success == true)
    }

    @Test("count reflects added items")
    func test_count_afterAdd() async throws {
        try await sut.add(assetId: "asset-001", sourceType: "photo")
        try await sut.add(assetId: "asset-002", sourceType: "photo")

        let total = try await sut.count()
        #expect(total == 2)
    }

    @Test("countForSource filters by source type")
    func test_countForSource_filtered() async throws {
        try await sut.add(assetId: "asset-001", sourceType: "photo")
        try await sut.add(assetId: "asset-002", sourceType: "photo")
        try await sut.add(assetId: "asset-003", sourceType: "note")

        #expect(try await sut.countForSource("photo") == 2)
        #expect(try await sut.countForSource("note") == 1)
        #expect(try await sut.countForSource("voice") == 0)
    }

    @Test("contains returns false for unknown asset")
    func test_contains_unknown() async throws {
        let exists = try await sut.contains(assetId: "unknown-id")
        #expect(exists == false)
    }

    // MARK: - Remove

    @Test("remove deletes from table")
    func test_remove_deletesFromTable() async throws {
        try await sut.add(assetId: "asset-001", sourceType: "photo")
        #expect(try await sut.contains(assetId: "asset-001"))

        let removed = try await sut.remove(assetId: "asset-001")
        #expect(removed)
        #expect(try await sut.contains(assetId: "asset-001") == false)
    }

    @Test("remove returns false for non-existent asset")
    func test_remove_returnsFalseForMissing() async throws {
        let removed = try await sut.remove(assetId: "nonexistent")
        #expect(removed == false)
    }

    // MARK: - listAll Pagination (AC-7)

    @Test("listAll returns items ordered by excludedAt DESC")
    func test_listAll_orderedByExcludedAt() async throws {
        try await sut.add(assetId: "asset-001", sourceType: "photo")
        try await Task.sleep(for: .seconds(1))
        try await sut.add(assetId: "asset-002", sourceType: "photo")

        let items = try await sut.listAll(limit: 50, offset: 0)
        #expect(items.count == 2)
        #expect(items[0].assetId == "asset-002")
        #expect(items[1].assetId == "asset-001")
    }

    @Test("listAll respects limit and offset")
    func test_listAll_pagination() async throws {
        for i in 1...5 {
            try await sut.add(assetId: "asset-\(String(format: "%03d", i))", sourceType: "photo")
            try await Task.sleep(for: .milliseconds(10))
        }

        let page1 = try await sut.listAll(limit: 2, offset: 0)
        #expect(page1.count == 2)

        let page2 = try await sut.listAll(limit: 2, offset: 2)
        #expect(page2.count == 2)

        let page3 = try await sut.listAll(limit: 2, offset: 4)
        #expect(page3.count == 1)
    }

    @Test("listAll returns empty for empty table")
    func test_listAll_emptyTable() async throws {
        let items = try await sut.listAll()
        #expect(items.isEmpty)
    }

    // MARK: - AC-6: Batch Restore

    @Test("batchRestore removes all items for source type — AC-6")
    func test_batchRestore_removesAll() async throws {
        try await sut.add(assetId: "p-001", sourceType: "photo")
        try await sut.add(assetId: "p-002", sourceType: "photo")
        try await sut.add(assetId: "n-001", sourceType: "note")

        let count = try await sut.batchRestore(sourceType: "photo", traceID: "trace-batch-1")
        #expect(count == 2)
        #expect(try await sut.contains(assetId: "p-001") == false)
        #expect(try await sut.contains(assetId: "p-002") == false)
        #expect(try await sut.contains(assetId: "n-001") == true)
    }

    @Test("batchRestore returns 0 for source type with no items")
    func test_batchRestore_emptySource() async throws {
        let count = try await sut.batchRestore(sourceType: "voice", traceID: "trace-batch-2")
        #expect(count == 0)
    }

    @Test("batchRestore records .excludedBatchRestored audit — AC-8")
    func test_batchRestore_audit() async throws {
        try await sut.add(assetId: "p-001", sourceType: "photo")
        try await sut.add(assetId: "p-002", sourceType: "photo")

        try await sut.batchRestore(sourceType: "photo", traceID: "trace-batch-audit")

        let logs = try await privacyActor.fetchAuditLogs(eventType: .excludedBatchRestored)
        #expect(logs.contains { $0.traceID == "trace-batch-audit" && $0.affectedCount == 2 })
    }

    @Test("batchRestore is idempotent - second call returns 0")
    func test_batchRestore_idempotent() async throws {
        try await sut.add(assetId: "p-001", sourceType: "photo")
        try await sut.batchRestore(sourceType: "photo")
        let secondCount = try await sut.batchRestore(sourceType: "photo")
        #expect(secondCount == 0)
    }

    // MARK: - Cleanup (US-PRV-007)

    @Test("cleanupInvalidRecord removes from table and audits .excludedAutoCleaned — AC-8")
    func test_cleanupInvalidRecord() async throws {
        try await sut.add(assetId: "asset-001", sourceType: "photo")
        #expect(try await sut.contains(assetId: "asset-001"))

        try await sut.cleanupInvalidRecord(assetId: "asset-001", traceID: "trace-cleanup-1")
        #expect(try await sut.contains(assetId: "asset-001") == false)

        let logs = try await privacyActor.fetchAuditLogs(eventType: .excludedAutoCleaned)
        #expect(logs.contains { $0.traceID == "trace-cleanup-1" && $0.affectedCount == 1 })
    }

    @Test("cleanupInvalidRecord is no-op if asset not in table")
    func test_cleanupInvalidRecord_noop() async throws {
        try await sut.cleanupInvalidRecord(assetId: "nonexistent")
        // Should not throw
    }

    // MARK: - Edge Cases

    @Test("add duplicate assetId is idempotent (INSERT OR REPLACE)")
    func test_add_duplicate() async throws {
        try await sut.add(assetId: "asset-001", sourceType: "photo")
        try await sut.add(assetId: "asset-001", sourceType: "note")

        #expect(try await sut.count() == 1)
        let items = try await sut.listAll(limit: 1, offset: 0)
        #expect(items.first?.sourceType == "note")
    }
}
