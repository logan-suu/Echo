// ==========================================
// 文件: GenerationRegistryActor.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-A.3 (IndexGeneration) + R-A.4 (ActiveRouteSet)
//            调研报告 §15.1 (数据模型: IndexGeneration / ActiveRouteSet) §16 (迁移与回滚)
// 任务: R-A.3/R-A.4 - 分代索引管理 + 原子服务路由
// AC 覆盖: registerGeneration, setState, loadGenerations, buildItem CRUD,
//          publishRoute, loadActiveRoute, validateRoute, fallback (回退最近有效 route)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007/R-008,
//           AGENTS.md §4.5 (断点续传), §4.3 (长任务串行)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-31
// ==========================================

import Foundation

/// 分代索引注册 Actor — 管理 `index_generation` / `index_build_item` /
/// `active_route_set` 表，并持有每个 generation 的 VectorStoreActor 实例（R-A.3 + R-A.4）。
///
/// ## Actor 隔离（AGENTS.md §4.2）
/// - 可变状态（generation → VectorStoreActor 实例字典）封装在 Actor 中
/// - 所有持久化通过 DatabaseManager 串行化
/// - 跨 Actor 调用必须 await（R-008）
///
/// ## 设计决策
/// - 每个 generation 一个独立 VectorStoreActor（独立 HNSW 文件）
/// - `legacy-512-v1` 迁移：注册时将现有单一索引登记为该 generation，标记已知不对齐风险
/// - ActiveRouteSet 发布：先逐项校验（generation 存在 + 非 building + 维度匹配），再单条
///   INSERT OR REPLACE 原子写入。校验与写入之间存在 await 挂起点，非严格事务（W-2 已记录）；
///   如需强事务需扩展 DatabaseManager 提供 executeTransaction。
public actor GenerationRegistryActor {

    // MARK: - Singleton

    public static let shared = GenerationRegistryActor()

    // MARK: - Properties

    private let db: DatabaseManager
    /// generationId → VectorStoreActor 实例（内存态，构建时注册）
    private var storeInstances: [String: VectorStoreActor] = [:]

    // MARK: - Initialization

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    // MARK: - R-A.3: IndexGeneration Management

    /// 注册一个分代（幂等：已存在则忽略）。
    ///
    /// - Parameter generation: 分代元数据（含 dimension）
    public func registerGeneration(_ generation: IndexGeneration) async throws {
        // W-6: 内存实例生命周期 — App 重启后 storeInstances 为空。
        // 若该 generation 已有持久化 .pxkt 文件，应改用 VectorStoreActor.load(from:)
        // 恢复而非重建空索引。磁盘路径约定与恢复逻辑在 Phase R-3 分代持久化落地时实现。
        if storeInstances[generation.generationId] == nil {
            storeInstances[generation.generationId] = VectorStoreActor(dimension: generation.dimension)
        }
        _ = try await db.executeWrite(
            sql: """
            INSERT OR IGNORE INTO IndexGeneration (
                generationId, indexType, manifestId, dimension, state, counts, validationDigest
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(generation.generationId),
                .text(generation.indexType),
                generation.manifestId.map(DBBinding.text) ?? .null,
                .int(Int64(generation.dimension)),
                .text(generation.state.rawValue),
                .int(Int64(generation.counts)),
                generation.validationDigest.map(DBBinding.text) ?? .null,
            ]
        )
    }

    /// 更新分代状态（building → ready → active → retired，遵循状态机校验）。
    ///
    /// - Throws: `GenerationError.illegalStateTransition` 若迁移非法（如 building → retired 直接跳转）
    @discardableResult
    public func setGenerationState(
        _ generationId: String,
        state: GenerationState,
        counts: Int? = nil,
        validationDigest: String? = nil
    ) async throws -> Bool {
        // W-3: 状态机校验 — 读取当前状态并拒绝非法迁移
        if let current = try await loadGeneration(generationId) {
            guard state.isLegalTransition(from: current.state) else {
                throw GenerationError.illegalStateTransition(
                    from: current.state,
                    to: state
                )
            }
        }
        var setClauses = ["state = ?"]
        var bindings: [DBBinding] = [.text(state.rawValue)]
        if let counts {
            setClauses.append("counts = ?")
            bindings.append(.int(Int64(counts)))
        }
        if let validationDigest {
            setClauses.append("validationDigest = ?")
            bindings.append(.text(validationDigest))
        }
        bindings.append(.text(generationId))
        let changes = try await db.executeWrite(
            sql: "UPDATE IndexGeneration SET \(setClauses.joined(separator: ", ")) WHERE generationId = ?",
            bindings: bindings
        )
        return changes > 0
    }

    /// 加载全部分代。
    public func loadGenerations() async throws -> [IndexGeneration] {
        let rows = try await db.executeQuery(
            sql: "SELECT * FROM IndexGeneration ORDER BY generationId",
            bindings: []
        )
        return rows.compactMap { Self.rowToGeneration($0) }
    }

    /// 按 generationId 加载。
    public func loadGeneration(_ generationId: String) async throws -> IndexGeneration? {
        let rows = try await db.executeQuery(
            sql: "SELECT * FROM IndexGeneration WHERE generationId = ?",
            bindings: [.text(generationId)]
        )
        return rows.first.flatMap { Self.rowToGeneration($0) }
    }

    /// 获取指定分代的 VectorStoreActor 实例。
    public func vectorStore(for generationId: String) -> VectorStoreActor? {
        storeInstances[generationId]
    }

    /// 删除一个分代及其构建项（级联）。
    @discardableResult
    public func removeGeneration(_ generationId: String) async throws -> Bool {
        storeInstances.removeValue(forKey: generationId)
        _ = try await db.executeWrite(
            sql: "DELETE FROM IndexBuildItem WHERE generationId = ?",
            bindings: [.text(generationId)]
        )
        let changes = try await db.executeWrite(
            sql: "DELETE FROM IndexGeneration WHERE generationId = ?",
            bindings: [.text(generationId)]
        )
        return changes > 0
    }

    // MARK: - R-A.3: IndexBuildItem Management

    /// 记录一个构建项（幂等 upsert）。
    public func upsertBuildItem(_ item: IndexBuildItem) async throws {
        _ = try await db.executeWrite(
            sql: """
            INSERT OR REPLACE INTO IndexBuildItem (
                generationId, representationId, state, error, retryCount
            ) VALUES (?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(item.generationId),
                .text(item.representationId),
                .text(item.state),
                item.error.map(DBBinding.text) ?? .null,
                .int(Int64(item.retryCount)),
            ]
        )
    }

    /// 更新构建项状态。
    @discardableResult
    public func updateBuildItem(
        generationId: String,
        representationId: String,
        state: String,
        error: String? = nil,
        retryIncrement: Bool = false
    ) async throws -> Bool {
        var setClauses = ["state = ?"]
        var bindings: [DBBinding] = [.text(state)]
        if let error {
            setClauses.append("error = ?")
            bindings.append(.text(error))
        }
        if retryIncrement {
            setClauses.append("retryCount = retryCount + 1")
        }
        bindings.append(.text(generationId))
        bindings.append(.text(representationId))
        let changes = try await db.executeWrite(
            sql: "UPDATE IndexBuildItem SET \(setClauses.joined(separator: ", ")) WHERE generationId = ? AND representationId = ?",
            bindings: bindings
        )
        return changes > 0
    }

    /// 查询某分代的构建项。
    public func loadBuildItems(generationId: String) async throws -> [IndexBuildItem] {
        let rows = try await db.executeQuery(
            sql: "SELECT * FROM IndexBuildItem WHERE generationId = ? ORDER BY representationId",
            bindings: [.text(generationId)]
        )
        return rows.compactMap { Self.rowToBuildItem($0) }
    }

    /// 获取分代的已完成构建数。
    public func completedCount(for generationId: String) async throws -> Int {
        let rows = try await db.executeQuery(
            sql: "SELECT COUNT(*) AS c FROM IndexBuildItem WHERE generationId = ? AND state = 'done'",
            bindings: [.text(generationId)]
        )
        return rows.first?["c"]?.intValue.map { Int($0) } ?? 0
    }

    // MARK: - R-A.4: ActiveRouteSet Management

    /// 发布新的活跃路由（原子：单条 UPDATE）。
    ///
    /// 发布前验证所有引用的 generation 存在且状态为 ready/active。
    /// - Throws: `GenerationError.routeValidationFailed` 若任一 generation 缺失或不可激活
    public func publishRoute(_ route: ActiveRouteSet) async throws {
        // Validate all referenced generations exist and are not building
        for generationId in route.allGenerationIDs {
            guard let generation = try await loadGeneration(generationId) else {
                throw GenerationError.routeValidationFailed(reason: "generation missing: \(generationId)")
            }
            if generation.state == .building {
                throw GenerationError.routeValidationFailed(reason: "generation still building: \(generationId)")
            }
        }
        _ = try await db.executeWrite(
            sql: """
            INSERT OR REPLACE INTO ActiveRouteSet (
                id, textGeneration, ocrGeneration, visionGeneration, lexicalGeneration, version, updatedAt
            ) VALUES (1, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(route.textGeneration),
                route.ocrGeneration.map(DBBinding.text) ?? .null,
                route.visionGeneration.map(DBBinding.text) ?? .null,
                route.lexicalGeneration.map(DBBinding.text) ?? .null,
                .int(Int64(route.version)),
                .double(route.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    /// 加载当前活跃路由。
    public func loadActiveRoute() async throws -> ActiveRouteSet? {
        let rows = try await db.executeQuery(
            sql: "SELECT * FROM ActiveRouteSet WHERE id = 1",
            bindings: []
        )
        return rows.first.flatMap { Self.rowToRoute($0) }
    }

    /// 校验路由的有效性（generation 存在、state 非 building、manifest 维度匹配）。
    /// - Returns: `true` 若路由有效；`false` 若任一验证失败（调用方应回退）
    public func validateRoute(_ route: ActiveRouteSet) async throws -> Bool {
        for generationId in route.allGenerationIDs {
            guard let generation = try await loadGeneration(generationId) else {
                return false
            }
            if generation.state == .building {
                return false
            }
            // W-1: manifest 维度必须与分代索引维度一致（不一致会导致查询向量错位）
            if let manifestId = generation.manifestId {
                guard let manifest = try await ModelManifestActor.shared.load(modelId: manifestId) else {
                    return false
                }
                if manifest.dimension != generation.dimension {
                    return false
                }
            }
        }
        return true
    }

    /// 重建 text-only 降级路由（当前路由无效时）。
    ///
    /// 查找状态为 active 的 text_dense generation 重建最小路由；
    /// 丢失 ocr/vision/lexical 通道（降级语义，非完整历史路由回退）。
    /// 若都不可用返回 nil。
    public func fallbackRoute() async throws -> ActiveRouteSet? {
        let generations = try await loadGenerations()
        let active = generations.filter { $0.state == .active }
        guard let textGen = active.first(where: { $0.indexType == "text_dense" }) ?? active.first else {
            return nil
        }
        let route = ActiveRouteSet(
            textGeneration: textGen.generationId,
            version: (try await loadActiveRoute()?.version ?? 0) + 1
        )
        return try await validateRoute(route) ? route : nil
    }

    // MARK: - Row Mapping

    private static func rowToGeneration(_ row: [String: DBValue]) -> IndexGeneration? {
        guard let generationId = row["generationId"]?.stringValue,
              let indexType = row["indexType"]?.stringValue,
              let stateRaw = row["state"]?.stringValue,
              let state = GenerationState(rawValue: stateRaw) else {
            return nil
        }
        return IndexGeneration(
            generationId: generationId,
            indexType: indexType,
            manifestId: row["manifestId"]?.stringValue,
            dimension: Int(row["dimension"]?.intValue ?? 512),
            state: state,
            counts: Int(row["counts"]?.intValue ?? 0),
            validationDigest: row["validationDigest"]?.stringValue
        )
    }

    private static func rowToBuildItem(_ row: [String: DBValue]) -> IndexBuildItem? {
        guard let generationId = row["generationId"]?.stringValue,
              let representationId = row["representationId"]?.stringValue,
              let state = row["state"]?.stringValue else {
            return nil
        }
        return IndexBuildItem(
            generationId: generationId,
            representationId: representationId,
            state: state,
            error: row["error"]?.stringValue,
            retryCount: Int(row["retryCount"]?.intValue ?? 0)
        )
    }

    private static func rowToRoute(_ row: [String: DBValue]) -> ActiveRouteSet? {
        guard let textGeneration = row["textGeneration"]?.stringValue else {
            return nil
        }
        return ActiveRouteSet(
            textGeneration: textGeneration,
            ocrGeneration: row["ocrGeneration"]?.stringValue,
            visionGeneration: row["visionGeneration"]?.stringValue,
            lexicalGeneration: row["lexicalGeneration"]?.stringValue,
            version: Int(row["version"]?.intValue ?? 1),
            updatedAt: Date(timeIntervalSince1970: row["updatedAt"]?.doubleValue ?? 0)
        )
    }
}

// MARK: - Extension: Route referenced generations

extension ActiveRouteSet {
    /// 路由引用的全部分代 ID（去重，text 必填）。
    nonisolated var allGenerationIDs: [String] {
        var ids = [textGeneration]
        if let ocrGeneration, ocrGeneration != textGeneration { ids.append(ocrGeneration) }
        if let visionGeneration, visionGeneration != textGeneration { ids.append(visionGeneration) }
        if let lexicalGeneration, lexicalGeneration != textGeneration { ids.append(lexicalGeneration) }
        return ids
    }
}

// MARK: - Error Types

/// GenerationRegistryActor 统一错误类型
public enum GenerationError: Error, LocalizedError, Sendable {
    /// 路由验证失败（generation 缺失或仍在构建）
    case routeValidationFailed(reason: String)
    /// 非法状态迁移（违反 building → ready → active → retired 状态机）
    case illegalStateTransition(from: GenerationState, to: GenerationState)

    public var errorDescription: String? {
        switch self {
        case .routeValidationFailed(let reason):
            return "Route validation failed: \(reason)"
        case .illegalStateTransition(let from, let to):
            return "Illegal generation state transition: \(from.rawValue) → \(to.rawValue)"
        }
    }
}
