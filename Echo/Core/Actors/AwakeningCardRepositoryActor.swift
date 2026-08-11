// ==========================================
// 文件: AwakeningCardRepositoryActor.swift
// 对应规格: docs/decisions/ADR-012-awakening-system-boundary.md 决策-5 (卡片持久化/去重)
//            docs/01-spec/用户故事与验收标准规格书.md → US-AWK-005 (交互式回忆卡片)
// 任务: 3F.8 - Awakening 与 system adapters
// AC 覆盖: ADR-012 决策-5 ✅ (AwakeningCardRepositoryActor 持久化卡片 + 重启去重)
// 架构约束: AGENTS.md §4.2 (Actor 隔离 — 所有 SQLite 写操作封装在 Actor 中),
//           R-007 (禁止 Combine / 不安全 Sendable 标注), D-005 (删除事务性)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
//       卡片以 JSON 编码持久化到 SQLite（经 DatabaseManager 单例，串行执行避免竞争）；
//       cardId 为主键去重 — 重启后相同卡片不重复写入
// 生成时间: 2026-08-11
// ==========================================

import Foundation

// MARK: - Awakening Card Repository

/// 唤醒卡片持久化存储 Actor（ADR-012 决策-5）。
///
/// - 持久化：卡片以 JSON 编码存储于 SQLite `AwakeningCard` 表（经 DatabaseManager 集中管理）
/// - 去重：`cardId` 唯一主键，重复写入自动替换（重启后相同卡片不重复生成）
/// - 读取：按 `createdAt` 降序返回最近卡片（US-AWK-005 交互卡片列表）
public actor AwakeningCardRepositoryActor {

    // MARK: - Properties

    private let db: DatabaseManager
    /// 惰性建表守卫：首次写/读前执行一次 ensureSchema（CREATE TABLE IF NOT EXISTS 幂等）
    private var schemaReady = false

    // MARK: - Init

    public init(db: DatabaseManager = .shared) {
        self.db = db
    }

    // MARK: - Schema (idempotent)

    /// 建表（幂等：CREATE TABLE IF NOT EXISTS）。
    public func ensureSchema() async throws {
        guard !schemaReady else { return }
        try await db.execute(sql: """
            CREATE TABLE IF NOT EXISTS AwakeningCard (
                cardId TEXT PRIMARY KEY,
                memoryIds TEXT NOT NULL,
                triggerType TEXT NOT NULL,
                regionId TEXT NOT NULL,
                createdAt REAL NOT NULL
            )
            """)
        schemaReady = true
    }

    // MARK: - Public API

    /// 保存一张唤醒卡片（cardId 去重 — 重复写入自动替换）。
    public func save(_ card: AwakeningCard) async throws {
        try await ensureSchema()
        let memoryIDsJSON = try card.encodeMemoryIDs()
        try await db.executeWrite(
            sql: """
                INSERT INTO AwakeningCard (cardId, memoryIds, triggerType, regionId, createdAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(cardId) DO UPDATE SET
                    memoryIds = excluded.memoryIds,
                    triggerType = excluded.triggerType,
                    regionId = excluded.regionId,
                    createdAt = excluded.createdAt
                """,
            bindings: [
                .text(card.cardId.uuidString),
                .text(memoryIDsJSON),
                .text(card.triggerType),
                .text(card.regionId),
                .double(card.createdAt.timeIntervalSince1970)
            ]
        )
    }

    /// 查询最近 N 张卡片（按 createdAt 降序）。
    public func fetchRecent(limit: Int) async throws -> [AwakeningCard] {
        try await ensureSchema()
        let rows = try await db.executeQuery(
            sql: """
                SELECT cardId, memoryIds, triggerType, regionId, createdAt
                FROM AwakeningCard
                ORDER BY createdAt DESC
                LIMIT ?
                """,
            bindings: [.int(Int64(limit))]
        )
        return rows.compactMap(Self.rowToCard)
    }

    /// 查询全部卡片（按 createdAt 降序）。
    public func fetchAll() async throws -> [AwakeningCard] {
        try await ensureSchema()
        let rows = try await db.executeQuery(
            sql: """
                SELECT cardId, memoryIds, triggerType, regionId, createdAt
                FROM AwakeningCard
                ORDER BY createdAt DESC
                """,
            bindings: []
        )
        return rows.compactMap(Self.rowToCard)
    }

    /// 删除单张卡片（D-005: 单条删除，事务原子）。
    public func remove(cardId: UUID) async throws {
        try await ensureSchema()
        try await db.executeWrite(
            sql: "DELETE FROM AwakeningCard WHERE cardId = ?",
            bindings: [.text(cardId.uuidString)]
        )
    }

    /// 清空全部卡片。
    public func clearAll() async throws {
        try await ensureSchema()
        try await db.execute(sql: "DELETE FROM AwakeningCard")
    }

    // MARK: - Row Mapping

    private nonisolated static func rowToCard(_ row: [String: DBValue]) -> AwakeningCard? {
        guard let cardIDString = row["cardId"]?.stringValue,
              let cardID = UUID(uuidString: cardIDString),
              let memoryIDsString = row["memoryIds"]?.stringValue,
              let memoryIDs = AwakeningCard.decodeMemoryIDs(from: memoryIDsString),
              let triggerType = row["triggerType"]?.stringValue,
              let regionId = row["regionId"]?.stringValue,
              let createdAt = row["createdAt"]?.doubleValue else { return nil }
        return AwakeningCard(
            cardId: cardID,
            memoryIds: memoryIDs,
            triggerType: triggerType,
            regionId: regionId,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}

// MARK: - Awakening Card Persistence Helpers

extension AwakeningCard {
    /// 编码 memoryIds 为 JSON 数组字符串（使用 JSONSerialization 避免 Codable 的 MainActor 隔离）。
    public nonisolated func encodeMemoryIDs() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: memoryIds.map(\.uuidString))
        guard let string = String(data: data, encoding: .utf8) else {
            throw AwakeningError.auditLogFailed(underlying: CocoaError(.coderInvalidValue))
        }
        return string
    }

    /// 从 JSON 数组字符串解码 memoryIds。
    public nonisolated static func decodeMemoryIDs(from jsonString: String) -> [UUID]? {
        guard let data = jsonString.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return array.compactMap(UUID.init)
    }
}
