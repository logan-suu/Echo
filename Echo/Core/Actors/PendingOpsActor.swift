// ==========================================
// 文件: PendingOpsActor.swift
// 对应规格: docs/02-architecture/架构设计文档.md §5 (L2 可恢复错误处理)
// 任务: 1.4 - 集成 SQLite，创建 ExcludedAssets, Feedback, TaskProgress, PendingOperations 表
// 架构约束: AGENTS.md §4.4 (L1~L4 错误分级), AGENTS.md §4.2 (Actor 隔离)
// 生成时间: 2026-07-04
// ==========================================

import Foundation

public actor PendingOpsActor {

    public static let shared = PendingOpsActor()
    private let db: DatabaseManager

    private init(db: DatabaseManager = .shared) {
        self.db = db
    }

    /// L2 失败操作入队
    public func add(operation: PendingOperation) async throws {
        try await db.executeWrite(
            sql: "INSERT INTO PendingOperations (operationId, operationType, retryCount, parameters, createdAt, lastError) VALUES (?, ?, ?, ?, ?, ?)",
            bindings: [
                .text(operation.operationId),
                .text(operation.operationType),
                .int(Int64(operation.retryCount)),
                .blob(operation.parameters),
                .double(operation.createdAt.timeIntervalSince1970),
                operation.lastError.map { .text($0) } ?? .null,
            ]
        )
    }

    /// 加载指定操作
    public func load(operationId: String) async throws -> PendingOperation? {
        let rows = try await db.executeQuery(
            sql: "SELECT operationId, operationType, retryCount, parameters, createdAt, lastError FROM PendingOperations WHERE operationId = ?",
            bindings: [.text(operationId)]
        )
        guard let row = rows.first,
              let id = row["operationId"]?.stringValue else { return nil }
        return PendingOperation(
            operationId: id,
            operationType: row["operationType"]?.stringValue ?? "",
            retryCount: row["retryCount"]?.intValue.map(Int.init) ?? 0,
            parameters: row["parameters"]?.blobValue ?? Data(),
            createdAt: row["createdAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            lastError: row["lastError"]?.stringValue
        )
    }

    /// 更新重试计数
    public func updateRetry(operationId: String, lastError: String?) async throws {
        try await db.executeWrite(
            sql: "UPDATE PendingOperations SET retryCount = retryCount + 1, lastError = ? WHERE operationId = ?",
            bindings: [lastError.map { .text($0) } ?? .null, .text(operationId)]
        )
    }

    /// 删除已完成的操作
    @discardableResult
    public func remove(operationId: String) async throws -> Bool {
        let changes = try await db.executeWrite(
            sql: "DELETE FROM PendingOperations WHERE operationId = ?",
            bindings: [.text(operationId)]
        )
        return changes > 0
    }

    /// 获取所有待重试操作
    public func listAll() async throws -> [PendingOperation] {
        let rows = try await db.executeQuery(
            sql: "SELECT operationId, operationType, retryCount, parameters, createdAt, lastError FROM PendingOperations ORDER BY createdAt DESC",
            bindings: []
        )
        return rows.compactMap { row in
            guard let id = row["operationId"]?.stringValue else { return nil }
            return PendingOperation(
                operationId: id,
                operationType: row["operationType"]?.stringValue ?? "",
                retryCount: row["retryCount"]?.intValue.map(Int.init) ?? 0,
                parameters: row["parameters"]?.blobValue ?? Data(),
                createdAt: row["createdAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) } ?? Date(),
                lastError: row["lastError"]?.stringValue
            )
        }
    }

    /// 待重试数量
    public func count() async throws -> Int {
        let rows = try await db.executeQuery(sql: "SELECT COUNT(*) AS cnt FROM PendingOperations", bindings: [])
        return rows.first?["cnt"]?.intValue.map(Int.init) ?? 0
    }

    /// 清理所有
    public func cleanup() async throws {
        try await db.execute(sql: "DELETE FROM PendingOperations")
    }
}
