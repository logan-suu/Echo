// ==========================================
// 文件: ExcludedAssetsActor.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-PRV-001/004/007, US-SRC-008
//            docs/02-architecture/架构设计文档.md §2.2 (Actor 隔离服务)
// 任务: 1.4 - 集成 SQLite，创建 ExcludedAssets, Feedback, TaskProgress, PendingOperations 表
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007/R-008, AGENTS.md §5.2 (ExcludedAssets 写入条件)
// 生成时间: 2026-07-04
// ==========================================

import Foundation

// MARK: - ExcludedAssets Actor

/// 用户排除资产 Actor — 管理 ExcludedAssets SQLite 表。
///
/// ## ExcludedAssets 写入条件（仅有三种）- AGENTS.md §5.2
/// 1. 用户选择"仅从 Echo 移除" → 写入 (US-PRV-004)
/// 2. 重新授权时用户选择"一键恢复排除项" → 批量移除 (US-PRV-001)
/// 3. 用户从已排除项目界面手动恢复 → 移除 (US-SRC-008)
public actor ExcludedAssetsActor {

    public static let shared = ExcludedAssetsActor()
    private let db: DatabaseManager

    private init(db: DatabaseManager = .shared) {
        self.db = db
    }

    /// 检查指定 Asset ID 是否在排除列表中
    public func contains(assetId: String) async throws -> Bool {
        let rows = try await db.executeQuery(
            sql: "SELECT 1 FROM ExcludedAssets WHERE assetId = ? LIMIT 1",
            bindings: [.text(assetId)]
        )
        return !rows.isEmpty
    }

    /// 将资产加入排除列表（条件 1：用户主动"仅从 Echo 移除"）
    public func add(assetId: String, sourceType: String) async throws {
        try await db.executeWrite(
            sql: "INSERT OR REPLACE INTO ExcludedAssets (assetId, sourceType, excludedAt) VALUES (?, ?, ?)",
            bindings: [.text(assetId), .text(sourceType), .int(Int64(Date().timeIntervalSince1970))]
        )
    }

    /// 从排除列表移除单个资产（条件 3：用户手动恢复）
    @discardableResult
    public func remove(assetId: String) async throws -> Bool {
        let exists = try await contains(assetId: assetId)
        guard exists else { return false }
        try await db.executeWrite(
            sql: "DELETE FROM ExcludedAssets WHERE assetId = ?",
            bindings: [.text(assetId)]
        )
        return true
    }

    /// 一键恢复指定数据源的所有排除项（条件 2：重新授权）
    public func batchRestore(sourceType: String) async throws {
        try await db.executeWrite(
            sql: "DELETE FROM ExcludedAssets WHERE sourceType = ?",
            bindings: [.text(sourceType)]
        )
    }

    /// 清理无效排除记录（级联删除时调用，US-PRV-007 AC-2）
    public func cleanupInvalidRecord(assetId: String) async throws {
        try await db.executeWrite(
            sql: "DELETE FROM ExcludedAssets WHERE assetId = ?",
            bindings: [.text(assetId)]
        )
    }

    /// 获取排除列表总数
    public func count() async throws -> Int {
        let rows = try await db.executeQuery(
            sql: "SELECT COUNT(*) AS cnt FROM ExcludedAssets",
            bindings: []
        )
        return rows.first?["cnt"]?.intValue.map(Int.init) ?? 0
    }

    /// 分页列出排除资产
    public func listAll(limit: Int = 50, offset: Int = 0) async throws -> [(assetId: String, sourceType: String, excludedAt: Date)] {
        let rows = try await db.executeQuery(
            sql: "SELECT assetId, sourceType, excludedAt FROM ExcludedAssets ORDER BY excludedAt DESC LIMIT ? OFFSET ?",
            bindings: [.int(Int64(limit)), .int(Int64(offset))]
        )
        return rows.compactMap { row in
            guard let id = row["assetId"]?.stringValue,
                  let source = row["sourceType"]?.stringValue,
                  let ts = row["excludedAt"]?.intValue else { return nil }
            return (id, source, Date(timeIntervalSince1970: TimeInterval(ts)))
        }
    }
}
