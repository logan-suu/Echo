// ==========================================
// 文件: PhotoSearchMigrationState.swift
// 对应规格: 交接计划 §WP6 产出的接口（可恢复迁移计划）
// 任务: WP6 - 迁移、重建索引、原子发布与回滚
// 架构约束: nonisolated Sendable 值契约（AGENTS.md §4.2 仅值类型传递）
// 生成时间: 2026-08-25
// ==========================================

import Foundation

/// 照片搜索迁移阶段（WP6 迁移状态机）
public enum PhotoSearchMigrationPhase: String, Sendable, Codable, Equatable {
    case idle
    case shadowBuilding
    case shadowReady
    case publishing
    case published
    case failed
}

/// 可恢复迁移计划状态——冻结源路由、目标 shadow generation 与进度。
public struct PhotoSearchMigrationState: Sendable, Codable, Equatable {
    public nonisolated let phase: PhotoSearchMigrationPhase
    /// 冻结的活跃路由快照 ID（迁移源）
    public nonisolated let sourceSnapshotID: String?
    /// 目标 shadow generation ID
    public nonisolated let shadowGenerationID: String?
    public nonisolated let processedCount: Int
    public nonisolated let totalCount: Int
    public nonisolated let lastProcessedLocator: String?

    public nonisolated init(
        phase: PhotoSearchMigrationPhase,
        sourceSnapshotID: String? = nil,
        shadowGenerationID: String? = nil,
        processedCount: Int = 0,
        totalCount: Int = 0,
        lastProcessedLocator: String? = nil
    ) {
        self.phase = phase
        self.sourceSnapshotID = sourceSnapshotID
        self.shadowGenerationID = shadowGenerationID
        self.processedCount = processedCount
        self.totalCount = totalCount
        self.lastProcessedLocator = lastProcessedLocator
    }
}