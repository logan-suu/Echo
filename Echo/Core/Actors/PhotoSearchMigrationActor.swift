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
    case dependenciesMissing
    case memoryNotFound
    case shadowStoreUnavailable

    public var errorDescription: String? {
        switch self {
        case .routeUnavailable:
            return "No active route available to freeze as migration source"
        case .dependenciesMissing:
            return "Photo search migration requires vision embedder and photo extractor"
        case .memoryNotFound:
            return "Canonical memory not found for migration"
        case .shadowStoreUnavailable:
            return "Shadow generation vector store is not materialized"
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
    /// 修正后图像塔（SigLIP2）——迁移重嵌入专用
    private let visionEmbedder: (any EmbedderProtocol)?
    /// 本地源加载器——禁用网络访问条件下提取图像数据
    private let photoExtractor: (any PhotoAssetExtracting)?
    /// 断点续传 checkpoint
    private let progressActor: ProgressActor?
    private var state: PhotoSearchMigrationState

    public init(
        generationRegistry: GenerationRegistryActor,
        canonicalRepository: CanonicalMemoryRepositoryActor? = nil,
        visionEmbedder: (any EmbedderProtocol)? = nil,
        photoExtractor: (any PhotoAssetExtracting)? = nil,
        progressActor: ProgressActor? = nil
    ) {
        self.generationRegistry = generationRegistry
        self.canonicalRepository = canonicalRepository
        self.visionEmbedder = visionEmbedder
        self.photoExtractor = photoExtractor
        self.progressActor = progressActor
        self.state = PhotoSearchMigrationState(phase: .idle)
    }

    /// 当前迁移状态快照。
    public func currentState() -> PhotoSearchMigrationState { state }

    /// 验证 shadow generation 无 orphan/歧义向量（WP6 迁移算法 D.3 / I.1-I.5）：
    /// 逐向量解析到唯一 canonical memory；任一 missing（orphan）或 ambiguous 即验证失败，
    /// 该代不得参与路由发布（验收清单第 3 条：活跃路由绝不指向 invalid generation）。
    public func validateShadowGeneration(generationID: String, traceID: String) async throws -> Bool {
        guard let repo = canonicalRepository,
              let store = await generationRegistry.vectorStore(for: generationID) else {
            throw PhotoSearchMigrationError.shadowStoreUnavailable
        }
        let entries = await store.allEntries()
        for (vectorID, _) in entries {
            let resolution = try await repo.mapVectorID(vectorID, generationID: generationID)
            switch resolution {
            case .mapped:
                continue
            case .missing, .ambiguous:
                return false
            }
        }
        return true
    }

    /// 取消迁移（WP6 迁移算法 A.8 / G.5）：
    /// 保留 checkpoint（processedCount/lastProcessedLocator）供恢复，不发布 shadow route——
    /// 活跃路由保持逐字节不变（验收清单第 5 条）。phase 保持 shadowBuilding 以允许
    /// 重新检查 consent 与源授权后从持久化进度恢复（G.5）。
    public func cancelPhotoMigration(traceID: String) async -> PhotoSearchMigrationState {
        state
    }

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

    /// 迁移单张照片（WP6 迁移算法 A.3-A.8）：
    /// 校验源存在（D-4：缺失 → build item failed，不伪造向量）→ 本地加载源 →
    /// 修正后图像塔重嵌入 → 确定性 representation ID 写入 shadow generation →
    /// 持久化 IndexBuildItem 与 progress checkpoint（A.8）。
    @discardableResult
    public func migratePhoto(
        memoryId: UUID,
        shadowGenerationID: String,
        taskID: String,
        traceID: String
    ) async throws -> IndexBuildItem {
        guard let repo = canonicalRepository,
              let visionEmbedder,
              let extractor = photoExtractor else {
            throw PhotoSearchMigrationError.dependenciesMissing
        }
        guard let memory = try await repo.loadMemory(memoryId: memoryId) else {
            throw PhotoSearchMigrationError.memoryNotFound
        }

        // D-4: 源缺失 → 对应 build item 标记 failed 并从发布数量排除
        guard let imageData = try await extractor.extractImageData(assetId: memory.sourceLocator) else {
            let failed = IndexBuildItem(
                generationId: shadowGenerationID,
                representationId: memoryId.uuidString,
                state: "failed",
                error: "source-missing"
            )
            try await generationRegistry.upsertBuildItem(failed)
            try await advanceProgress(taskID: taskID, locator: memory.sourceLocator)
            state = PhotoSearchMigrationState(
                phase: .shadowBuilding,
                sourceSnapshotID: state.sourceSnapshotID,
                shadowGenerationID: shadowGenerationID,
                processedCount: state.processedCount + 1,
                lastProcessedLocator: memory.sourceLocator
            )
            return failed
        }

        let vector = try await visionEmbedder.embedImageData(imageData)
        let repID = CanonicalMemoryRepositoryActor.photoRepresentationID(memoryID: memoryId)
        guard let store = await generationRegistry.vectorStore(for: shadowGenerationID) else {
            throw PhotoSearchMigrationError.shadowStoreUnavailable
        }
        try await store.ingest(vector: vector, id: repID, metadata: nil)

        let item = IndexBuildItem(
            generationId: shadowGenerationID,
            representationId: repID.uuidString,
            state: "done"
        )
        try await generationRegistry.upsertBuildItem(item)
        try await advanceProgress(taskID: taskID, locator: memory.sourceLocator)
        state = PhotoSearchMigrationState(
            phase: .shadowBuilding,
            sourceSnapshotID: state.sourceSnapshotID,
            shadowGenerationID: shadowGenerationID,
            processedCount: state.processedCount + 1,
            lastProcessedLocator: memory.sourceLocator
        )
        return item
    }

    /// 推进断点续传 checkpoint：已有记录则更新；否则 upsert 创建（迁移进度自足，
    /// 不要求调用方预先建记录）。
    private func advanceProgress(taskID: String, locator: String) async throws {
        guard let progressActor else { return }
        let index = state.processedCount + 1
        do {
            try await progressActor.updateProgress(
                taskId: taskID,
                lastProcessedIndex: index,
                lastProcessedId: locator
            )
        } catch {
            try await progressActor.save(progress: TaskProgress(
                taskId: taskID,
                taskType: .fullIndex,
                lastProcessedIndex: index,
                lastProcessedId: locator
            ))
        }
    }
}