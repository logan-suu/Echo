// ==========================================
// 文件: MemoryDeletionJournal.swift
// 对应规格: 自然语言照片检索交接计划 §7.8（D-005 可恢复删除契约）
// 任务: WP3 - 规范身份、删除、补偿与路由回滚（步骤 0b/3 系列）
// 架构约束: SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor 下值契约显式 nonisolated；
//           journal 先于副作用持久化，任一阶段失败保留 journal 写 PendingOperations，
//           启动恢复从已持久化 phase 重放幂等步骤（D-005）。
// AC 覆盖: D-005 persists deletion phase, representation vector IDs, and exclusion intent.
// 生成时间: 2026-08-25
// ==========================================

import Foundation

/// D-005 删除阶段机——严格顺序推进，失败停在当前阶段等待恢复重放。
public nonisolated enum MemoryDeletionPhase: String, Sendable, Codable, Equatable {
    case planned
    case cacheInvalidated
    case vectorsDeleted
    case auditPurged
    case canonicalDeleted
    case completed

    nonisolated var ordinal: Int {
        switch self {
        case .planned: 0
        case .cacheInvalidated: 1
        case .vectorsDeleted: 2
        case .auditPurged: 3
        case .canonicalDeleted: 4
        case .completed: 5
        }
    }
}

/// 单个 generation 内待删除的向量 ID 清单。
public nonisolated struct GenerationVectorIDs: Sendable, Codable, Equatable {
    public nonisolated let generationID: String
    public nonisolated let vectorIDs: [UUID]

    public nonisolated init(generationID: String, vectorIDs: [UUID]) {
        self.generationID = generationID
        self.vectorIDs = vectorIDs
    }
}

/// 可恢复删除日志——先于任何副作用持久化（.planned），
/// 逐阶段推进并在成功后于 .completed 时移除自身。
public nonisolated struct MemoryDeletionJournal: Sendable, Codable, Equatable {
    public nonisolated let operationID: String
    public nonisolated let memoryID: UUID
    public nonisolated let auditSubjectHash: String
    public nonisolated let traceID: String
    public nonisolated let phase: MemoryDeletionPhase
    public nonisolated let vectorIDsByGeneration: [GenerationVectorIDs]
    /// The original deletion intent must survive removal of the canonical row.
    public nonisolated let sourceLocator: String?
    public nonisolated let sourceType: String?
    public nonisolated let writeExcluded: Bool?

    public nonisolated init(
        operationID: String,
        memoryID: UUID,
        auditSubjectHash: String,
        traceID: String,
        phase: MemoryDeletionPhase,
        vectorIDsByGeneration: [GenerationVectorIDs],
        sourceLocator: String? = nil,
        sourceType: String? = nil,
        writeExcluded: Bool? = nil
    ) {
        self.operationID = operationID
        self.memoryID = memoryID
        self.auditSubjectHash = auditSubjectHash
        self.traceID = traceID
        self.phase = phase
        self.vectorIDsByGeneration = vectorIDsByGeneration
        self.sourceLocator = sourceLocator
        self.sourceType = sourceType
        self.writeExcluded = writeExcluded
    }
}
