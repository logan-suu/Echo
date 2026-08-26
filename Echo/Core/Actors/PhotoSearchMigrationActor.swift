// ==========================================
// 文件: PhotoSearchMigrationActor.swift
// 对应规格: 交接计划 §WP6 迁移算法 A.1-A.2 / D（shadow 与原子路由发布）
// 任务: WP6 - 迁移、重建索引、原子发布与回滚
// 架构约束: Actor 隔离（AGENTS.md §4.2）；shadow build 绝不发布路由（验收清单第 3 条）
// 生成时间: 2026-08-25
// ==========================================

import Foundation

/// 照片搜索迁移错误（WP6 专用，L2 可恢复 / L3 阻断语义由调用方映射）。
public enum PhotoSearchMigrationError: Error, LocalizedError, Sendable, Equatable {
    case routeUnavailable

    public var errorDescription: String? {
        switch self {
        case .routeUnavailable:
            return "No active route available to freeze as migration source"
        }
    }
}

/// 照片搜索迁移编排 Actor——shadow generation 重建、验证、原子发布与回滚。
///
/// 迁移不变量（验收清单 L1769-1776）：
/// - 活跃路由绝不指向 building/invalid generation
/// - shadow build 启动/取消/失败均保持活跃路由逐字节不变
public actor PhotoSearchMigrationActor {
    private let generationRegistry: GenerationRegistryActor
    private let canonicalRepository: CanonicalMemoryRepositoryActor?
    private var state: PhotoSearchMigrationState

    public init(
        generationRegistry: GenerationRegistryActor,
        canonicalRepository: CanonicalMemoryRepositoryActor? = nil
    ) {
        self.generationRegistry = generationRegistry
        self.canonicalRepository = canonicalRepository
        self.state = PhotoSearchMigrationState(phase: .idle)
    }

    /// 当前迁移状态快照。
    public func currentState() -> PhotoSearchMigrationState { state }

    /// 启动照片 shadow build（WP6 迁移算法 A.1-A.2）：
    /// 冻结活跃路由快照作为迁移源，创建 building 态 shadow generation，
    /// 绝不发布路由——活跃路由保持逐字节不变（验收清单第 3/5 条）。
    public func startPhotoShadowBuild(traceID: String) async throws -> PhotoSearchMigrationState {
        guard let active = try await generationRegistry.loadActiveRoute() else {
            throw PhotoSearchMigrationError.routeUnavailable
        }
        let snapshotID = "active-v\(active.version)-\(active.textGeneration)"
        let shadowID = "vision_dense/siglip2-v1-shadow-\(UUID().uuidString.prefix(8))"
        try await generationRegistry.registerGeneration(IndexGeneration(
            generationId: shadowID,
            indexType: "vision_dense",
            dimension: 768
        ))
        state = PhotoSearchMigrationState(
            phase: .shadowBuilding,
            sourceSnapshotID: snapshotID,
            shadowGenerationID: shadowID
        )
        return state
    }
}