// ==========================================
// 文件: GenerationRegistryActor.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-A.3 (IndexGeneration) + R-A.4 (ActiveRouteSet)
//            调研报告 §15.1 (数据模型: IndexGeneration / ActiveRouteSet) §16 (迁移与回滚)
//            docs/decisions/ADR-010-canonical-generation-lifecycle.md 决策-2/3
// 任务: R-A.3/R-A.4 - 分代索引管理 + 原子服务路由
//      3F.4 - generation 生命周期（shadow build / 原子发布 / 回滚 / 重启恢复 / 持久化）
// AC 覆盖: registerGeneration, setState, loadGenerations, buildItem CRUD,
//          publishRoute, loadActiveRoute, validateRoute, fallback (回退最近有效 route)
//          3F.4: finishShadowBuild, activateGeneration, rollbackToPrevious,
//          restoreActiveRoute, persistStore, reloadStoreFromDisk, removeStoreFile
//          2026-08-09 PR#56 修复: F-2 activateGeneration/rollbackToPrevious
//          状态迁移+路由发布合并单事务 (原子发布, 无跨挂起点窗口)
//          2026-08-09 PR#56 二轮: CR-6 lifecycleBusy in-flight 守卫 (并发竞争),
//          CR-7 restoreActiveRoute 恢复 previousTextGeneration store + rollback 前恢复,
//          Nitpick-2 indexRestoreFailed 审计留痕
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007/R-008,
//           AGENTS.md §4.5 (断点续传), §4.3 (长任务串行)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-31 | 更新: 2026-08-09 (3F.4 生命周期)
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
    /// 每代索引文件的持久化目录（3F.4：重启恢复）
    private let storeDirectory: URL
    /// 路由生命周期操作 in-flight 守卫（CR-6: 读-算-写窗口内禁止并发 activate/rollback）
    private var lifecycleInFlight = false

    // MARK: - Initialization

    init(db: DatabaseManager = .shared, storeDirectory: URL? = nil) {
        self.db = db
        if let storeDirectory {
            self.storeDirectory = storeDirectory
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            let echoDir = appSupport.appendingPathComponent("Echo", isDirectory: true)
            self.storeDirectory = echoDir.appendingPathComponent("generations", isDirectory: true)
        }
    }

    /// 单个 generation 索引文件的 URL（`<dir>/<generationId>.pxkt`，ID 中的 `/` 替换为 `_`）。
    public func storeFileURL(for generationId: String) -> URL {
        let safeName = generationId.replacingOccurrences(of: "/", with: "_")
        return storeDirectory.appendingPathComponent("\(safeName).pxkt")
    }

    /// 持久化指定 generation 的向量存储到磁盘（3F.4 重启恢复）。
    public func persistStore(generationId: String) async throws {
        guard let store = storeInstances[generationId] else { return }
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try await store.save(to: storeFileURL(for: generationId))
    }

    /// Replaces the active in-memory store with the last durable checkpoint.
    /// Used when a post-commit cleanup cannot persist, so obsolete vectors remain available
    /// until the pending cleanup is retried.
    public func reloadStoreFromDisk(generationId: String) async throws {
        let url = storeFileURL(for: generationId)
        let restored = try VectorStoreActor.load(from: url)
        guard let generation = try await loadGeneration(generationId),
              restored.dimension == generation.dimension else {
            throw GenerationError.routeValidationFailed(reason: "Invalid durable store for \(generationId)")
        }
        storeInstances[generationId] = restored
    }

    /// 删除指定 generation 的持久化索引文件（测试/清理用）。
    public func removeStoreFile(generationId: String) async throws {
        try? FileManager.default.removeItem(at: storeFileURL(for: generationId))
    }

    // MARK: - R-A.3: IndexGeneration Management

    /// 注册一个分代（幂等：已存在则忽略）。
    ///
    /// - Parameter generation: 分代元数据（含 dimension）
    public func registerGeneration(_ generation: IndexGeneration) async throws {
        // W-6 → 3F.4 修复：若存在持久化 .pxkt 文件，用 load(from:) 恢复内存实例，
        // 否则新建空索引。维度不匹配时视为损坏，重建空索引（不可混代服务）。
        if storeInstances[generation.generationId] == nil {
            let url = storeFileURL(for: generation.generationId)
            if FileManager.default.fileExists(atPath: url.path),
               let restored = try? VectorStoreActor.load(from: url),
               restored.dimension == generation.dimension {
                storeInstances[generation.generationId] = restored
            } else {
                // Nitpick-2: 恢复失败重建空索引，发审计事件留痕（hash-only，不含原文）
                let policy = await PrivacyActor.shared.getPolicy()
                try? await PrivacyActor.shared.writeAuditLog(
                    eventType: .indexRestoreFailed,
                    traceID: "generation-register",
                    policyVersion: policy.policyVersion,
                    success: false,
                    sourceType: generation.indexType,
                    content: "generationId=\(generation.generationId)|dimension=\(generation.dimension)|rebuiltEmpty=true"
                )
                storeInstances[generation.generationId] = VectorStoreActor(dimension: generation.dimension)
            }
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
    ///
    /// 3F.11 fix: 内存未物化时从磁盘 `.pxkt` 恢复（新进程重启后路由在 DB 而 store 仅存磁盘
    /// ——否则摄入 commit 抛 `generationMissing`）。恢复失败返回 nil（调用方降级）。
    public func vectorStore(for generationId: String) async -> VectorStoreActor? {
        if storeInstances[generationId] != nil {
            return storeInstances[generationId]
        }
        guard (try? await restoreStoreIfNeeded(generationId)) == true else {
            return nil
        }
        return storeInstances[generationId]
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
        _ = try await db.executeTransaction([routeUpsertWrite(route)])
    }

    /// 构建 ActiveRouteSet 的路由 upsert 写（INSERT OR REPLACE id=1）。
    ///
    /// F-2: 供 `activateGeneration` / `rollbackToPrevious` 与状态迁移合并进
    /// 同一 SQLite 事务，保证「状态变更 + 路由发布」原子提交（无跨挂起点窗口）。
    private func routeUpsertWrite(_ route: ActiveRouteSet) -> DatabaseManager.DBWrite {
        DatabaseManager.DBWrite(
            sql: """
            INSERT OR REPLACE INTO ActiveRouteSet (
                id, textGeneration, ocrGeneration, visionGeneration, lexicalGeneration, version, updatedAt, previousTextGeneration
            ) VALUES (1, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(route.textGeneration),
                route.ocrGeneration.map(DBBinding.text) ?? .null,
                route.visionGeneration.map(DBBinding.text) ?? .null,
                route.lexicalGeneration.map(DBBinding.text) ?? .null,
                .int(Int64(route.version)),
                .double(route.updatedAt.timeIntervalSince1970),
                route.previousTextGeneration.map(DBBinding.text) ?? .null,
            ]
        )
    }

    // MARK: - 3F.4: Generation Lifecycle (ADR-010 决策-2/3)

    /// 完成 shadow build：将 generation 置为 `.ready`（ADR-010 决策-2）。
    @discardableResult
    public func finishShadowBuild(
        _ generationId: String,
        counts: Int,
        validationDigest: String?
    ) async throws -> Bool {
        try await setGenerationState(generationId, state: .ready, counts: counts, validationDigest: validationDigest)
    }

    /// 原子发布：将指定 generation 提升为 active 并发布路由。
    ///
    /// - 旧 active 降级为 `.ready`（保留为回滚目标），新 generation 置 `.active`
    /// - 路由版本递增，`previousTextGeneration` 记录旧 active
    /// - 发布前校验 generation 存在且非 `.building`（禁止混代 route）
    /// - Returns: 发布后的活跃路由
    @discardableResult
    public func activateGeneration(_ generationId: String) async throws -> ActiveRouteSet {
        guard !lifecycleInFlight else {
            throw GenerationError.lifecycleBusy(operation: "activateGeneration")
        }
        lifecycleInFlight = true
        defer { lifecycleInFlight = false }

        guard let generation = try await loadGeneration(generationId) else {
            throw GenerationError.routeValidationFailed(reason: "generation missing: \(generationId)")
        }
        guard generation.state != .building else {
            throw GenerationError.routeValidationFailed(reason: "generation still building: \(generationId)")
        }

        let previous = try await loadActiveRoute()
        var writes: [DatabaseManager.DBWrite] = []
        if let previous, previous.textGeneration != generationId {
            // 旧 active 降级 .ready（保留为回滚目标），校验迁移合法
            if let prevGen = try await loadGeneration(previous.textGeneration) {
                guard GenerationState.ready.isLegalTransition(from: prevGen.state) else {
                    throw GenerationError.illegalStateTransition(from: prevGen.state, to: .ready)
                }
                writes.append(.init(
                    sql: "UPDATE IndexGeneration SET state = ? WHERE generationId = ?",
                    bindings: [.text(GenerationState.ready.rawValue), .text(previous.textGeneration)]
                ))
            }
        }
        // 新 generation 置 .active，校验迁移合法（禁止 building 直接激活已在守卫处拒绝）
        guard GenerationState.active.isLegalTransition(from: generation.state) else {
            throw GenerationError.illegalStateTransition(from: generation.state, to: .active)
        }
        writes.append(.init(
            sql: "UPDATE IndexGeneration SET state = ? WHERE generationId = ?",
            bindings: [.text(GenerationState.active.rawValue), .text(generationId)]
        ))

        let route = ActiveRouteSet(
            textGeneration: generationId,
            version: (previous?.version ?? 0) + 1,
            previousTextGeneration: previous?.textGeneration
        )
        writes.append(routeUpsertWrite(route))

        // 数据流:522 (CodeRabbit): 先持久化 store 再发布路由 — 若持久化失败则抛错，
        // 路由不发布，避免「active route 指向无 durable store 的 generation」（重启后检索失效）
        try await persistStore(generationId: generationId)

        // F-2: 状态迁移 + 路由发布合并为单个 SQLite 事务，原子提交（无跨挂起点窗口）
        _ = try await db.executeTransaction(writes)
        return route
    }

    /// 回滚到前一活跃 generation（ADR-010 决策-3：旧代可回滚）。
    ///
    /// - 当前 active 降级为 `.ready`，`previousTextGeneration` 指向的旧代置 `.active`
    /// - 无 previous 时返回 nil（无可回滚目标）
    /// - Returns: 回滚后的活跃路由，或 nil
    @discardableResult
    public func rollbackToPrevious() async throws -> ActiveRouteSet? {
        guard !lifecycleInFlight else {
            throw GenerationError.lifecycleBusy(operation: "rollbackToPrevious")
        }
        lifecycleInFlight = true
        defer { lifecycleInFlight = false }

        guard let current = try await loadActiveRoute(),
              let previousId = current.previousTextGeneration,
              let previous = try await loadGeneration(previousId),
              previous.state != .building else {
            return nil
        }

        var writes: [DatabaseManager.DBWrite] = []
        // 当前 active 降级 .ready，校验迁移合法
        if let currentGen = try await loadGeneration(current.textGeneration) {
            guard GenerationState.ready.isLegalTransition(from: currentGen.state) else {
                throw GenerationError.illegalStateTransition(from: currentGen.state, to: .ready)
            }
            writes.append(.init(
                sql: "UPDATE IndexGeneration SET state = ? WHERE generationId = ?",
                bindings: [.text(GenerationState.ready.rawValue), .text(current.textGeneration)]
            ))
        }
        // previous 置 .active，校验迁移合法
        guard GenerationState.active.isLegalTransition(from: previous.state) else {
            throw GenerationError.illegalStateTransition(from: previous.state, to: .active)
        }
        writes.append(.init(
            sql: "UPDATE IndexGeneration SET state = ? WHERE generationId = ?",
            bindings: [.text(GenerationState.active.rawValue), .text(previousId)]
        ))

        let route = ActiveRouteSet(
            textGeneration: previousId,
            version: current.version + 1,
            previousTextGeneration: current.textGeneration
        )
        writes.append(routeUpsertWrite(route))

        // CR-7 + 数据流:522: 回滚目标 store 若未加载（如重启后仅 restoreActiveRoute 恢复 active 代），
        // 先恢复内存实例，并在发布路由前持久化 — 持久化失败则路由不发布，
        // 避免「回滚后路由指向无 durable store 的 generation」
        guard try await restoreStoreIfNeeded(previousId) else {
            throw GenerationError.routeValidationFailed(reason: "rollback target generation missing: \(previousId)")
        }
        try await persistStore(generationId: previousId)

        // F-2: 状态迁移 + 路由发布合并为单个 SQLite 事务，原子提交（无跨挂起点窗口）
        _ = try await db.executeTransaction(writes)
        return route
    }

    /// 重启恢复：加载持久化 active route，并为路由引用 + 回滚目标 generation 恢复内存存储实例。
    ///
    /// - 存储实例优先从磁盘 `.pxkt` 恢复；维度不匹配或文件缺失时重建空索引
    /// - CR-7 (PR#56 review): 同时恢复 `previousTextGeneration` 的 store，
    ///   否则重启后 `rollbackToPrevious` 无向量可检索
    /// - 路由引用的 generation 缺失 → 返回 nil（调用方走降级/重建）
    /// - Returns: 恢复的活跃路由，或 nil
    public func restoreActiveRoute() async throws -> ActiveRouteSet? {
        guard let route = try await loadActiveRoute() else { return nil }
        var ids = route.allGenerationIDs
        if let previous = route.previousTextGeneration, !ids.contains(previous) {
            ids.append(previous)
        }
        for generationId in ids {
            guard try await restoreStoreIfNeeded(generationId) else { return nil }
        }
        return route
    }

    /// 若指定 generation 的 store 未在内存，则从磁盘 `.pxkt` 恢复（失败时重建空索引）。
    /// - Returns: `false` 若 generation 在 DB 中不存在（调用方应降级）
    private func restoreStoreIfNeeded(_ generationId: String) async throws -> Bool {
        if storeInstances[generationId] != nil { return true }
        guard let generation = try await loadGeneration(generationId) else {
            return false
        }
        let url = storeFileURL(for: generationId)
        if FileManager.default.fileExists(atPath: url.path),
           let restored = try? VectorStoreActor.load(from: url),
           restored.dimension == generation.dimension {
            storeInstances[generationId] = restored
        } else {
            // Nitpick-2: 恢复失败重建空索引，发审计事件留痕（hash-only，不含原文）
            let policy = await PrivacyActor.shared.getPolicy()
            try? await PrivacyActor.shared.writeAuditLog(
                eventType: .indexRestoreFailed,
                traceID: "generation-restore",
                policyVersion: policy.policyVersion,
                success: false,
                sourceType: generation.indexType,
                content: "generationId=\(generationId)|dimension=\(generation.dimension)|rebuiltEmpty=true"
            )
            storeInstances[generationId] = VectorStoreActor(dimension: generation.dimension)
        }
        return true
    }

    /// 生产初始 generation 引导（3F.11 fix：照片/文本摄入与检索依赖活跃路由，ADR-010）。
    ///
    /// 幂等：已有活跃路由时直接返回。创建 text_dense（E5 384d）+ vision_dense（SigLIP2 768d）
    /// 两代并发布含 vision 的活跃路由（与 3F.5 测试 seed 一致）。生产路径此前从未引导初始
    /// 代——`loadActiveRoute()` 返回 nil 导致所有生产摄入抛 `productionRouteUnavailable`。
    public func ensureInitialGenerations() async throws {
        // 模式匹配避开 MainActor 隔离的 Equatable（ActiveRouteSet/IndexGeneration）
        guard case nil = try await loadActiveRoute() else { return }

        let textId = "text_dense/e5-v1"
        let visionId = "vision_dense/siglip2-v1"

        if case nil = try await loadGeneration(textId) {
            try await registerGeneration(
                IndexGeneration(generationId: textId, indexType: "text_dense", dimension: 384)
            )
        }
        if let gen = try await loadGeneration(textId), gen.state == .building {
            _ = try await finishShadowBuild(textId, counts: 0, validationDigest: nil)
        }

        if case nil = try await loadGeneration(visionId) {
            try await registerGeneration(
                IndexGeneration(generationId: visionId, indexType: "vision_dense", dimension: 768)
            )
        }
        if let gen = try await loadGeneration(visionId), gen.state == .building {
            _ = try await finishShadowBuild(visionId, counts: 0, validationDigest: nil)
        }

        let route = try await activateGeneration(textId)
        try await publishRoute(ActiveRouteSet(
            textGeneration: textId,
            visionGeneration: visionId,
            version: route.version
        ))
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
            updatedAt: Date(timeIntervalSince1970: row["updatedAt"]?.doubleValue ?? 0),
            previousTextGeneration: row["previousTextGeneration"]?.stringValue
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
    /// 路由生命周期操作已在执行（CR-6 并发守卫）
    case lifecycleBusy(operation: String)

    public var errorDescription: String? {
        switch self {
        case .routeValidationFailed(let reason):
            return "Route validation failed: \(reason)"
        case .illegalStateTransition(let from, let to):
            return "Illegal generation state transition: \(from.rawValue) → \(to.rawValue)"
        case .lifecycleBusy(let operation):
            return "Generation lifecycle operation already in flight: \(operation)"
        }
    }
}
