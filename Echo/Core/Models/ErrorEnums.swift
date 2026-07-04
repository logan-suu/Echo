// ==========================================
// 文件: ErrorEnums.swift
// 对应规格: docs/02-architecture/架构设计文档.md §5 (统一错误处理矩阵)
//            docs/01-spec/用户故事与验收标准规格书.md §US-FBK-001~003
// 任务: 1.4 - 集成 SQLite，创建 ExcludedAssets, Feedback, TaskProgress, PendingOperations 表
// 架构约束: 遵循 AGENTS.md §4.4 (L1~L4 错误分级), R-007 (禁止 @unchecked Sendable)
// 重要: 所有 struct stored/computed properties 必须 nonisolated（项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor）
// 生成时间: 2026-07-04
// ==========================================

import Foundation

// MARK: - Database Error

public enum DatabaseError: Error, LocalizedError, Sendable {
    case connectionFailed(underlying: Error)
    case tableCreationFailed(table: String, underlying: Error)
    case writeFailed(operation: String, underlying: Error)
    case readFailed(operation: String, underlying: Error)
    case notFound(id: String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let error):
            return "Database connection failed: \(error.localizedDescription)"
        case .tableCreationFailed(let table, let error):
            return "Failed to create table '\(table)': \(error.localizedDescription)"
        case .writeFailed(let op, let error):
            return "Write operation '\(op)' failed: \(error.localizedDescription)"
        case .readFailed(let op, let error):
            return "Read operation '\(op)' failed: \(error.localizedDescription)"
        case .notFound(let id):
            return "Record not found: \(id)"
        }
    }
}

// MARK: - Task Type

public enum TaskType: String, Sendable, Codable {
    case fullIndex
    case dataSourceSync
    case modelLoad
}

// MARK: - Feedback Models

public enum FeedbackSentiment: String, Sendable, Codable {
    case like
    case dislike
}

public struct FeedbackEntry: Sendable, Codable {
    public nonisolated let id: UUID
    public nonisolated let memoryId: UUID
    public nonisolated let queryText: String
    public nonisolated let sentiment: FeedbackSentiment
    public nonisolated let cosineSimilarity: Double
    public nonisolated let createdAt: Date
    public nonisolated let isBadCase: Bool
    public nonisolated let badCaseReason: String?

    public nonisolated init(
        id: UUID = UUID(),
        memoryId: UUID,
        queryText: String,
        sentiment: FeedbackSentiment,
        cosineSimilarity: Double,
        createdAt: Date = Date(),
        isBadCase: Bool = false,
        badCaseReason: String? = nil
    ) {
        self.id = id
        self.memoryId = memoryId
        self.queryText = queryText
        self.sentiment = sentiment
        self.cosineSimilarity = cosineSimilarity
        self.createdAt = createdAt
        self.isBadCase = isBadCase
        self.badCaseReason = badCaseReason
    }
}

public struct FeedbackAdjustment: Sendable {
    public nonisolated let adjustment: Double
    public nonisolated let feedbackCount: Int

    public nonisolated init(adjustment: Double, feedbackCount: Int) {
        self.adjustment = adjustment
        self.feedbackCount = feedbackCount
    }
}

// MARK: - Task Progress Model

public struct TaskProgress: Sendable, Codable {
    public nonisolated let taskId: String
    public nonisolated let taskType: TaskType
    public nonisolated var lastProcessedIndex: Int
    public nonisolated var totalCount: Int
    public nonisolated var lastProcessedId: String?
    public nonisolated var resumeData: Data?
    public nonisolated var updatedAt: Date
    public nonisolated let createdAt: Date

    public nonisolated init(
        taskId: String = UUID().uuidString,
        taskType: TaskType,
        lastProcessedIndex: Int = 0,
        totalCount: Int = 0,
        lastProcessedId: String? = nil,
        resumeData: Data? = nil,
        updatedAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.taskId = taskId
        self.taskType = taskType
        self.lastProcessedIndex = lastProcessedIndex
        self.totalCount = totalCount
        self.lastProcessedId = lastProcessedId
        self.resumeData = resumeData
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }
}

// MARK: - Pending Operation Model

public struct PendingOperation: Sendable, Codable {
    public nonisolated let operationId: String
    public nonisolated let operationType: String
    public nonisolated var retryCount: Int
    public nonisolated let parameters: Data
    public nonisolated let createdAt: Date
    public nonisolated var lastError: String?

    public nonisolated init(
        operationId: String = UUID().uuidString,
        operationType: String,
        retryCount: Int = 0,
        parameters: Data,
        createdAt: Date = Date(),
        lastError: String? = nil
    ) {
        self.operationId = operationId
        self.operationType = operationType
        self.retryCount = retryCount
        self.parameters = parameters
        self.createdAt = createdAt
        self.lastError = lastError
    }
}
