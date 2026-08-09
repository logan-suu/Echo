// ==========================================
// 文件: DatabaseMigrationActor.swift
// 对应规格: docs/decisions/ADR-010-canonical-generation-lifecycle.md 决策-1/3
//            docs/01-spec/用户故事与验收标准规格书.md → US-ING-006, US-AWK-007
// 任务: 3F.4 - Canonical storage 与 generation 生命周期
// AC 覆盖: schema 演进 (MemoryFTS / translationCache / Memory 编辑字段 /
//          FeedbackStore.generationId / ActiveRouteSet.previousTextGeneration)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-09
// ==========================================

import Foundation

/// schema 迁移 Actor — 集中管理数据库表结构演进（3F.4）。
///
/// 迁移在 `DatabaseManager.open()` 的 `createAllTables()` 中以幂等方式执行
/// （`CREATE TABLE IF NOT EXISTS` + `PRAGMA table_info` 守卫的 `ALTER TABLE`）。
/// 本 Actor 提供显式的迁移编排入口，供启动流程与测试断言 schema 完整。
public actor DatabaseMigrationActor {

    public static let shared = DatabaseMigrationActor()

    private let db: DatabaseManager

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    /// 校验 v5 (3F.4) schema 的迁移是否已全部应用。
    ///
    /// - Returns: `true` 若所有 3F.4 引入的表/列存在
    public func isV5SchemaApplied() async throws -> Bool {
        let memoryColumns = try await db.columnNames(in: "Memory")
        guard memoryColumns.contains("originalTimestamp"),
              memoryColumns.contains("userEdited"),
              memoryColumns.contains("userLocked") else { return false }

        let feedbackColumns = try await db.columnNames(in: "FeedbackStore")
        guard feedbackColumns.contains("generationId") else { return false }

        let routeColumns = try await db.columnNames(in: "ActiveRouteSet")
        guard routeColumns.contains("previousTextGeneration") else { return false }

        let memoryFTSPresent = try await db.tableExists("MemoryFTS")
        let translationCachePresent = try await db.tableExists("translationCache")
        return memoryFTSPresent && translationCachePresent
    }
}

// MARK: - Table existence helper

extension DatabaseManager {
    /// 判断表是否存在（迁移断言用）。
    func tableExists(_ name: String) async throws -> Bool {
        let rows = try await executeQuery(
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            bindings: [.text(name)]
        )
        return !rows.isEmpty
    }
}
