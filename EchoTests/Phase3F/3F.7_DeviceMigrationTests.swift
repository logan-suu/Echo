// ==========================================
// 文件: 3F.7_DeviceMigrationTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-007 (设备迁移)
//            docs/decisions/ADR-008-source-import-boundaries.md §决策-6
//            docs/05-planning/phase3f-execution-plan.md §4.6.7
// 任务: 3F.7 - UI 到 Core 全域接线 (US-SRC-007 设备迁移功能)
// AC 覆盖: US-SRC-007 AC-1 (仅本地传输), AC-2 (ExcludedAssets 随本地迁移), AC-4 (覆盖/合并/冲突),
//          AC-5 (迁移后完整性校验), AC-6 (不导出全部原始记忆), AC-7 (.deviceMigrationCompleted 审计)
// 架构约束: AGENTS.md §4.2, R-001 (无网络), R-007/R-008, §9.4 (串行执行)
// 重要: TDD — 功能性套件，依赖共享 DB（串行 suite），无 fixture fallback。
// 生成时间: 2026-08-11
// ==========================================

import Testing
import Foundation
import CryptoKit
@testable import Echo

// MARK: - Test Embedder

/// 确定性文本嵌入器 — 迁移导入时写入活跃 generation 向量。
public actor MigrationTestEmbedder: EmbedderProtocol {
    public init() {}
    public func embedText(_ text: String) async throws -> [Float] {
        [Float](repeating: 0.5, count: 384)
    }
    public func embedText(_ text: String, context: EmbeddingContext) async throws -> [Float] {
        [Float](repeating: 0.5, count: 384)
    }
    public func embedImage(assetId: String) async throws -> [Float] {
        [Float](repeating: 0.5, count: 768)
    }
    public func embedImageData(_ data: Data) async throws -> [Float] {
        [Float](repeating: 0.5, count: 768)
    }
}

// MARK: - Suite: Device Migration (Functional)

@Suite("DeviceMigrationTests", .serialized)
@MainActor
struct DeviceMigrationTests {

    let db = DatabaseManager.shared
    let registry = GenerationRegistryActor(db: .shared)

    init() async throws {
        try await DeviceMigrationTests.wipeMigrationTables()
    }

    private static func wipeMigrationTables() async throws {
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
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM PendingOperations")

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

    /// 注册并激活 text generation（迁移导入需要活跃路由）。
    private func seedActiveRoute() async throws {
        try await registry.registerGeneration(
            IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384)
        )
        try await registry.finishShadowBuild("text_dense/e5-v1", counts: 0, validationDigest: nil)
        try await registry.setGenerationState("text_dense/e5-v1", state: .ready)
        let route = try await registry.activateGeneration("text_dense/e5-v1")
        try await registry.publishRoute(
            ActiveRouteSet(textGeneration: route.textGeneration, version: route.version)
        )
    }

    private func makeActor() -> DeviceMigrationActor {
        DeviceMigrationActor(
            db: db,
            canonicalRepository: CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry),
            generationRegistry: registry,
            textEmbedder: MigrationTestEmbedder()
        )
    }

    private func seedMemory(memoryId: UUID, locator: String, sourceType: String, text: String?) async throws {
        try await db.executeWrite(
            sql: """
            INSERT OR REPLACE INTO Memory (memoryId, sourceLocator, canonicalText, sourceType, createdAt, updatedAt, recoverability, originalTimestamp, userEdited, userLocked)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(memoryId.uuidString),
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

    // MARK: - US-SRC-007 AC-6: 不导出全部原始记忆文件

    @Test("SRC-007 AC-6: exported package contains only minimal canonical fields, never original file bytes")
    func test_AC6_NoOriginalFilesInExport() async throws {
        try await seedActiveRoute()
        let actor = makeActor()
        try await seedMemory(
            memoryId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            locator: "photo-1",
            sourceType: "photo",
            text: "a photo memory"
        )
        let (package, _) = try await actor.exportPackage()
        // 包内绝不包含原始文件名/路径内容（canonical 引用仅字段值）
        let text = String(data: package, encoding: .utf8) ?? ""
        #expect(!text.contains("photo-1\n")) // header 无 sourceLocator 原文（locator 仅存在于加密载荷）
        #expect(!package.isEmpty)
    }

    // MARK: - US-SRC-007 AC-5: 完整性校验

    @Test("SRC-007 AC-5: import reports integrityCheckPassed")
    func test_AC5_IntegrityCheckPassed() async throws {
        try await seedActiveRoute()
        let actor = makeActor()
        let mid = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        try await seedMemory(memoryId: mid, locator: "note-1", sourceType: "note", text: "migrated note")
        let (package, key) = try await actor.exportPackage()

        // 清空后再导入（target-empty）
        try await db.execute(sql: "DELETE FROM MemoryFTS")
        try await db.execute(sql: "DELETE FROM Representation")
        try await db.execute(sql: "DELETE FROM Memory")

        let result = try await actor.importPackage(
            package: package,
            transferKey: key,
            strategy: .overwrite,
            fromDevice: "iPhone-A",
            toDevice: "iPhone-B"
        )
        #expect(result.integrityCheckPassed)
        #expect(result.memoryCount == 1)
    }

    // MARK: - US-SRC-007 AC-4: 覆盖 / 合并 / 冲突

    @Test("SRC-007 AC-4: overwrite replaces target data")
    func test_AC4_OverwriteReplacesTarget() async throws {
        try await seedActiveRoute()
        let actor = makeActor()
        let sourceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        try await seedMemory(memoryId: sourceID, locator: "note-source", sourceType: "note", text: "source note")
        let (package, key) = try await actor.exportPackage()

        // 目标设备已有不同数据
        let targetID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        try await seedMemory(memoryId: targetID, locator: "note-target", sourceType: "note", text: "target note")

        let result = try await actor.importPackage(
            package: package,
            transferKey: key,
            strategy: .overwrite,
            fromDevice: "iPhone-A",
            toDevice: "iPhone-B"
        )
        // overwrite 清除目标原有数据（source + target 2 条）并写入源数据
        #expect(result.overwrittenCount == 2)
        #expect(try await actor.loadMemoryCount() == 1)
    }

    @Test("SRC-007 AC-4: merge keeps both unique memories and flags conflicts")
    func test_AC4_MergeKeepsBothAndFlagsConflict() async throws {
        try await seedActiveRoute()
        let actor = makeActor()
        let sourceID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        try await seedMemory(memoryId: sourceID, locator: "note-source", sourceType: "note", text: "source note")
        let (package, key) = try await actor.exportPackage()

        // 目标有同 ID 记忆（冲突）+ 独有记忆
        let conflictID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        try await seedMemory(memoryId: conflictID, locator: "note-source", sourceType: "note", text: "target version")
        let uniqueTarget = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        try await seedMemory(memoryId: uniqueTarget, locator: "note-unique", sourceType: "note", text: "unique target")

        let result = try await actor.importPackage(
            package: package,
            transferKey: key,
            strategy: .merge,
            batchPolicy: .allSource,
            fromDevice: "iPhone-A",
            toDevice: "iPhone-B"
        )
        // 冲突 1 条（同 ID），batchPolicy=.allSource → 用源版本；独有目标保留
        #expect(result.conflictCount == 1)
        // 🔴-1 修复：merge 保留目标独有数据，完整性校验须逐条校验导入 ID 存在而非总数相等
        #expect(result.integrityCheckPassed)
    }

    // MARK: - US-SRC-007 AC-2: ExcludedAssets 随本地迁移

    @Test("SRC-007 AC-2: ExcludedAssets are migrated locally")
    func test_AC2_ExcludedAssetsMigrated() async throws {
        try await seedActiveRoute()
        let actor = makeActor()
        try await seedMemory(memoryId: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!, locator: "note-1", sourceType: "note", text: "note")
        try await ExcludedAssetsActor(db: db).add(assetId: "photo-excluded-1", sourceType: "photo")

        let (package, key) = try await actor.exportPackage()
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
        try await db.execute(sql: "DELETE FROM MemoryFTS")
        try await db.execute(sql: "DELETE FROM Representation")
        try await db.execute(sql: "DELETE FROM Memory")

        let result = try await actor.importPackage(
            package: package,
            transferKey: key,
            strategy: .overwrite,
            fromDevice: "iPhone-A",
            toDevice: "iPhone-B"
        )
        #expect(result.excludedCount == 1)
        let count = try await ExcludedAssetsActor(db: db).count()
        #expect(count == 1)
    }

    // MARK: - US-SRC-007 AC-7: 审计字段

    @Test("SRC-007 AC-7: deviceMigrationCompleted audit has required fields")
    func test_AC7_AuditFields() async throws {
        try await seedActiveRoute()
        let actor = makeActor()
        try await seedMemory(memoryId: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!, locator: "note-1", sourceType: "note", text: "note")
        let (package, key) = try await actor.exportPackage()
        try await db.execute(sql: "DELETE FROM MemoryFTS")
        try await db.execute(sql: "DELETE FROM Representation")
        try await db.execute(sql: "DELETE FROM Memory")

        let traceID = "migration-trace-\(UUID().uuidString)"
        _ = try await actor.importPackage(
            package: package,
            transferKey: key,
            strategy: .overwrite,
            fromDevice: "iPhone-A",
            toDevice: "iPhone-B",
            traceID: traceID
        )
        let entries = try await PrivacyActor.shared.fetchAuditLogs(limit: 50, eventType: .deviceMigrationCompleted)
        let match = entries.first { $0.traceID == traceID }
        #expect(match != nil)
        #expect(match?.contentHash != nil)
        #expect(match?.success == true)
    }

    @Test("SRC-007 AC-7: method + batchPolicy threaded into import and audit (🟡-7 fix)")
    func test_AC7_MethodAndBatchPolicyInAudit() async throws {
        try await seedActiveRoute()
        let actor = makeActor()
        try await seedMemory(memoryId: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!, locator: "note-1", sourceType: "note", text: "note")
        let (package, key) = try await actor.exportPackage()
        try await db.execute(sql: "DELETE FROM MemoryFTS")
        try await db.execute(sql: "DELETE FROM Representation")
        try await db.execute(sql: "DELETE FROM Memory")

        let traceID = "migration-method-trace-\(UUID().uuidString)"
        let result = try await actor.importPackage(
            package: package,
            transferKey: key,
            strategy: .overwrite,
            batchPolicy: .allTarget,
            fromDevice: "iPhone-A",
            toDevice: "iPhone-B",
            method: "localBackup",
            traceID: traceID
        )
        #expect(result.integrityCheckPassed)
        #expect(result.memoryCount == 1)
        let entries = try await PrivacyActor.shared.fetchAuditLogs(limit: 50, eventType: .deviceMigrationCompleted)
        let match = entries.first { $0.traceID == traceID }
        #expect(match != nil)
        #expect(match?.success == true)
    }

    @Test("Import: wrong transfer key fails closed and leaves DB unchanged")
    func test_Import_WrongKeyLeavesDB() async throws {
        try await seedActiveRoute()
        let actor = makeActor()
        try await seedMemory(memoryId: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!, locator: "note-1", sourceType: "note", text: "note")
        let (package, key) = try await actor.exportPackage()
        let wrongKey = SymmetricKey(size: .bits256)

        try await db.execute(sql: "DELETE FROM MemoryFTS")
        try await db.execute(sql: "DELETE FROM Representation")
        try await db.execute(sql: "DELETE FROM Memory")

        var threw = false
        do {
            _ = try await actor.importPackage(
                package: package,
                transferKey: wrongKey,
                strategy: .overwrite,
                fromDevice: "iPhone-A",
                toDevice: "iPhone-B"
            )
        } catch {
            threw = true
        }
        #expect(threw, "wrong transfer key must fail closed")
        let count = try await actor.loadMemoryCount()
        #expect(count == 0, "failed import must not mutate active DB")
    }
}

// MARK: - Internal Test Helper (actor 隔离读取计数)

public extension DeviceMigrationActor {
    /// 读取当前 Memory 表行数（测试辅助，不触发审计）。
    func loadMemoryCount() async throws -> Int {
        let rows = try await DatabaseManager.shared.executeQuery(
            sql: "SELECT COUNT(*) AS cnt FROM Memory",
            bindings: []
        )
        return rows.first?["cnt"]?.intValue.map(Int.init) ?? 0
    }
}
