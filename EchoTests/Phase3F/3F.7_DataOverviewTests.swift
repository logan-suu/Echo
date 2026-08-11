// ==========================================
// 文件: 3F.7_DataOverviewTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-009 (数据处理可视化, 合并入 US-SYS-001)
//            docs/05-planning/phase3f-execution-plan.md §4.6.7 (3F.7 数据概览合同)
// 任务: 3F.7 - UI 到 Core 全域接线 (US-SRC-009 数据概览)
// AC 覆盖: US-SRC-009 AC-1 (各数据源条目数/存储占用/向量维度), AC-2 (模型状态),
//          AC-3 (≤5s 实时更新), AC-4 (JSON 导出), AC-5 (.dataOverviewAccessed 审计)
// 架构约束: AGENTS.md §4.2, §5.4 (hash-only 审计), §9.4 (串行执行)
// 重要: TDD — DataOverviewService 已实现，套件验证实时统计 + 导出 + 审计。
// 生成时间: 2026-08-11
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Suite: Data Overview (US-SRC-009)

@Suite("DataOverviewTests", .serialized)
@MainActor
struct DataOverviewTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await DataOverviewTests.wipeOverviewTables()
    }

    private static func wipeOverviewTables() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        try await db.execute(sql: "DELETE FROM MemoryFTS")
        try await db.execute(sql: "DELETE FROM translationCache")
        try await db.execute(sql: "DELETE FROM Representation")
        try await db.execute(sql: "DELETE FROM Memory")
        try await db.execute(sql: "DELETE FROM AuditLog")
    }

    private func makeService() -> DataOverviewService {
        DataOverviewService(db: db)
    }

    private func seedMemory(locator: String, sourceType: String, text: String?) async throws {
        try await db.executeWrite(
            sql: """
            INSERT OR REPLACE INTO Memory (memoryId, sourceLocator, canonicalText, sourceType, createdAt, updatedAt, recoverability, originalTimestamp, userEdited, userLocked)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(UUID().uuidString),
                .text(locator),
                text.map(DBBinding.text) ?? .null,
                .text(sourceType),
                .double(Date().timeIntervalSince1970),
                .double(Date().timeIntervalSince1970),
                .text("full"),
                .null,
                .int(0),
                .int(0),
            ]
        )
    }

    // MARK: - US-SRC-009 AC-1: 条目数 / 存储 / 向量维度

    @Test("SRC-009 AC-1: counts per source type and total memory count")
    func test_AC1_CountsBySourceType() async throws {
        try await seedMemory(locator: "photo-1", sourceType: "photo", text: nil)
        try await seedMemory(locator: "photo-2", sourceType: "photo", text: nil)
        try await seedMemory(locator: "note-1", sourceType: "note", text: "note")
        try await seedMemory(locator: "voice-1", sourceType: "voice", text: "voice")

        let snap = try await makeService().snapshot()
        #expect(snap.countsBySourceType["photo"] == 2)
        #expect(snap.countsBySourceType["note"] == 1)
        #expect(snap.countsBySourceType["voice"] == 1)
        #expect(snap.memoryCount == 4)
        #expect(snap.databaseBytes > 0)
    }

    @Test("SRC-009 AC-1: translationCache exposes byte size (US-SET-003 cache row)")
    func test_AC1_CacheByteSize() async throws {
        try await db.executeWrite(
            sql: "INSERT OR REPLACE INTO translationCache (memoryId, languagePair, translatedText, createdAt) VALUES (?, ?, ?, ?)",
            bindings: [.text("m-1"), .text("zh-Hans-en-US"), .text("Hello world"), .double(Date().timeIntervalSince1970)]
        )
        let snap = try await makeService().snapshot()
        #expect(snap.translationCacheCount == 1)
        #expect(snap.translationCacheBytes == Int64("Hello world".utf8.count))
    }

    @Test("SRC-009 AC-1: snapshot exposes model totals")
    func test_AC1_ModelTotals() async throws {
        let snap = try await makeService().snapshot()
        // ModelLoaderActor overallStatus reports total model count (not fabricated)
        #expect(snap.modelTotalCount == ModelLoaderActor.ModelType.allCases.count)
        #expect(snap.modelLoadedCount + snap.modelFailedCount + snap.modelNotLoadedCount == snap.modelTotalCount)
    }

    // MARK: - US-SRC-009 AC-3: ≤5s 实时更新

    @Test("SRC-009 AC-3: snapshot reflects live row changes within refresh window")
    func test_AC3_LiveRefresh() async throws {
        let service = makeService()
        let before = try await service.snapshot()
        #expect(before.memoryCount == 0)

        try await seedMemory(locator: "note-live", sourceType: "note", text: "live")

        let after = try await service.snapshot()
        #expect(after.memoryCount == 1, "snapshot must reflect live DB state (≤5s refresh)")
        #expect(after.updatedAt >= before.updatedAt)
    }

    // MARK: - US-SRC-009 AC-4: JSON 导出

    @Test("SRC-009 AC-4: JSON export contains all stats and is parseable")
    func test_AC4_JSONExport() async throws {
        try await seedMemory(locator: "note-export", sourceType: "note", text: "export")
        let json = try await makeService().exportJSON()
        #expect(json.contains("memoryCount"))
        #expect(json.contains("countsBySourceType"))
        #expect(json.contains("vectorDimensions"))
        #expect(json.contains("modelStatus"))

        let data = Data(json.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed != nil)
        #expect((parsed?["memoryCount"] as? NSNumber)?.intValue == 1)
    }

    // MARK: - US-SRC-009 AC-5: 审计

    @Test("SRC-009 AC-5: snapshot writes dataOverviewAccessed audit")
    func test_AC5_AuditEvent() async throws {
        let traceID = "overview-\(UUID().uuidString)"
        _ = try await makeService().snapshot(traceID: traceID)
        let entries = try await PrivacyActor.shared.fetchAuditLogs(limit: 50, eventType: .dataOverviewAccessed)
        let match = entries.first { $0.traceID == traceID }
        #expect(match != nil)
        #expect(match?.success == true)
    }

    @Test("SRC-009 AC-5: JSON export also writes audit")
    func test_AC5_ExportWritesAudit() async throws {
        let traceID = "overview-export-\(UUID().uuidString)"
        _ = try await makeService().exportJSON(traceID: traceID)
        let entries = try await PrivacyActor.shared.fetchAuditLogs(limit: 50, eventType: .dataOverviewAccessed)
        let match = entries.first { $0.traceID == traceID }
        #expect(match != nil)
    }
}
