// ==========================================
// 文件: FeedbackActor.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-FBK-001/002/003
//            docs/02-architecture/架构设计文档.md §8 (反馈学习与重排集成)
// 任务: 1.4 - 集成 SQLite，创建 ExcludedAssets, Feedback, TaskProgress, PendingOperations 表
// AC: US-FBK-002 AC-1 (阈值≥0.80), AC-2 (时间衰减 90d/180d), AC-3 (截断±0.5)
// 架构约束: AGENTS.md §5.3 (反馈存储契约)
// 生成时间: 2026-07-04
// ==========================================

import Foundation

public actor FeedbackActor {

    // MARK: - Constants

    public static let similarityThreshold: Double = 0.80
    public static let adjustmentUpperBound: Double = 0.5
    public static let adjustmentLowerBound: Double = -0.5
    public static let decayRecent: Double = 1.0
    public static let decayMedium: Double = 0.5
    public static let archiveAgeDays: Int = 180

    public static let shared = FeedbackActor()
    private let db: DatabaseManager

    private init(db: DatabaseManager = .shared) {
        self.db = db
    }

    /// 记录一条用户反馈
    public func recordFeedback(_ entry: FeedbackEntry) async throws {
        try await db.executeWrite(
            sql: "INSERT INTO FeedbackStore (feedbackId, memoryId, queryText, sentiment, cosineSimilarity, createdAt, isBadCase, badCaseReason) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            bindings: [
                .text(entry.id.uuidString),
                .text(entry.memoryId.uuidString),
                .text(entry.queryText),
                .text(entry.sentiment.rawValue),
                .double(entry.cosineSimilarity),
                .double(entry.createdAt.timeIntervalSince1970),
                .int(entry.isBadCase ? 1 : 0),
                entry.badCaseReason.map { .text($0) } ?? .null,
            ]
        )
    }

    /// 计算反馈重排调整值（US-FBK-002 AC-1~3）
    public func computeAdjustment(for memoryId: UUID, queryText: String) async throws -> FeedbackAdjustment {
        let entries = try await fetchEntries(for: memoryId)
        guard !entries.isEmpty else {
            return FeedbackAdjustment(adjustment: 0, feedbackCount: 0)
        }

        let now = Date()
        let calendar = Calendar.current
        var rawAdjustment: Double = 0
        var appliedCount = 0

        for entry in entries {
            guard entry.cosineSimilarity >= FeedbackActor.similarityThreshold else { continue }
            let daysSince = calendar.dateComponents([.day], from: entry.createdAt, to: now).day ?? 0
            let decayFactor: Double
            if daysSince <= 90 {
                decayFactor = FeedbackActor.decayRecent
            } else if daysSince <= 180 {
                decayFactor = FeedbackActor.decayMedium
            } else {
                continue
            }
            let sentimentWeight: Double = (entry.sentiment == .like) ? 1.0 : -1.0
            rawAdjustment += sentimentWeight * decayFactor
            appliedCount += 1
        }

        let clamped = max(FeedbackActor.adjustmentLowerBound, min(FeedbackActor.adjustmentUpperBound, rawAdjustment))
        return FeedbackAdjustment(adjustment: clamped, feedbackCount: appliedCount)
    }

    /// 批量计算多个记忆的反馈调整值
    public func computeBatchAdjustments(for memoryIds: [UUID], queryText: String) async throws -> [UUID: FeedbackAdjustment] {
        var results: [UUID: FeedbackAdjustment] = [:]
        for id in memoryIds {
            results[id] = try await computeAdjustment(for: id, queryText: queryText)
        }
        return results
    }

    /// 获取指定记忆的所有反馈记录
    public func fetchEntries(for memoryId: UUID) async throws -> [FeedbackEntry] {
        let rows = try await db.executeQuery(
            sql: "SELECT feedbackId, memoryId, queryText, sentiment, cosineSimilarity, createdAt, isBadCase, badCaseReason FROM FeedbackStore WHERE memoryId = ? ORDER BY createdAt DESC",
            bindings: [.text(memoryId.uuidString)]
        )
        return rows.compactMap { row in
            guard let fidStr = row["feedbackId"]?.stringValue,
                  let fid = UUID(uuidString: fidStr),
                  let midStr = row["memoryId"]?.stringValue,
                  let mid = UUID(uuidString: midStr),
                  let sStr = row["sentiment"]?.stringValue,
                  let sentiment = FeedbackSentiment(rawValue: sStr) else { return nil }
            return FeedbackEntry(
                id: fid, memoryId: mid,
                queryText: row["queryText"]?.stringValue ?? "",
                sentiment: sentiment,
                cosineSimilarity: row["cosineSimilarity"]?.doubleValue ?? 0,
                createdAt: row["createdAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) } ?? Date(),
                isBadCase: (row["isBadCase"]?.intValue ?? 0) == 1,
                badCaseReason: row["badCaseReason"]?.stringValue
            )
        }
    }

    /// 获取所有 Bad Case
    public func fetchBadCases() async throws -> [FeedbackEntry] {
        let rows = try await db.executeQuery(
            sql: "SELECT feedbackId, memoryId, queryText, sentiment, cosineSimilarity, createdAt, isBadCase, badCaseReason FROM FeedbackStore WHERE isBadCase = 1 ORDER BY createdAt DESC",
            bindings: []
        )
        return rows.compactMap { row in
            guard let fidStr = row["feedbackId"]?.stringValue,
                  let fid = UUID(uuidString: fidStr),
                  let midStr = row["memoryId"]?.stringValue,
                  let mid = UUID(uuidString: midStr),
                  let sStr = row["sentiment"]?.stringValue,
                  let sentiment = FeedbackSentiment(rawValue: sStr) else { return nil }
            return FeedbackEntry(
                id: fid, memoryId: mid,
                queryText: row["queryText"]?.stringValue ?? "",
                sentiment: sentiment,
                cosineSimilarity: row["cosineSimilarity"]?.doubleValue ?? 0,
                createdAt: row["createdAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) } ?? Date(),
                isBadCase: true,
                badCaseReason: row["badCaseReason"]?.stringValue
            )
        }
    }

    /// 反馈总数
    public func count() async throws -> Int {
        let rows = try await db.executeQuery(sql: "SELECT COUNT(*) AS cnt FROM FeedbackStore", bindings: [])
        return rows.first?["cnt"]?.intValue.map(Int.init) ?? 0
    }

    /// 清空所有反馈（US-FBK-001）
    public func reset() async throws {
        try await db.execute(sql: "DELETE FROM FeedbackStore")
    }

    /// 撤销单条反馈（US-FBK-003）
    @discardableResult
    public func revoke(feedbackId: UUID) async throws -> Bool {
        let changes = try await db.executeWrite(
            sql: "DELETE FROM FeedbackStore WHERE feedbackId = ?",
            bindings: [.text(feedbackId.uuidString)]
        )
        return changes > 0
    }
}
