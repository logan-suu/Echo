// ==========================================
// 文件: CanonicalMemoryRepositoryActor.swift
// 对应规格: docs/decisions/ADR-010-canonical-generation-lifecycle.md 决策-1/2/4/5/7
//            docs/01-spec/用户故事与验收标准规格书.md → US-ING-006, US-PRV-004/006/007,
//            US-AWK-007, US-FBK-001/002/003
//            AGENTS.md D-002/D-003/D-004/D-005, §5 存储契约
// 任务: 3F.4 - Canonical storage 与 generation 生命周期
// AC 覆盖: 确定性 ID (RFC 4122 派生), 事务 CRUD (canonical+vector+FTS 同事务/补偿),
//          崩溃点故障注入 (无 half-write), 全删除边界 (D-005), 级联删除 (US-PRV-007),
//          仅从 Echo 移除写 ExcludedAssets (US-PRV-004), 反馈 generation 身份
//          2026-08-09 PR#56 修复: F-1 deleteMemory 清理未加载 generation 的磁盘副本,
//          F-3 searchCanonical FTS5 语法转义 (token 化短语 AND)
//          2026-08-09 PR#56 二轮: CR-3 FTS 行与 representation 解耦 (每记忆一行),
//          CR-1 deleteMemory 缺参回退 memory 定位, Nitpick-1 故障注入 DEBUG-only
//          2026-08-11 3F.6: searchCanonical ORDER BY rank (DEF-56-006, FTS5 bm25 相关性排序)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007, R-008 (跨 Actor await)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-09
// PR#57 review fix: W-03 新增 DEBUG-only .deleteFail 故障点 + CanonicalRepositoryError.deleteInjected，
//                   供 SyncPipeline canonical 删除失败路径测试（D-005 不静默吞错）
// PR#57 CodeRabbit fix: CR-11 新增 memoryNotFound/invalidMemoryID 显式错误（deleteMemory false 与非法 UUID 不再静默）
// ==========================================

import Foundation
import CryptoKit

/// Canonical 存储仓库 Actor — 持有规范事实源与 generation 写入协调（ADR-010 决策-1）。
///
/// ## 事务语义 (US-ING-006 AC-1/2)
/// - Memory/Representation/FTS 写入在 SQLite `executeTransaction` 中原子提交；
/// - 向量写入 VectorStoreActor 在 SQLite 提交之后执行；任一失败触发补偿回滚
///   （删除已写向量 + 删除 canonical 行），保证不产生「向量存在但原文丢失」。
public actor CanonicalMemoryRepositoryActor {

    public static let shared = CanonicalMemoryRepositoryActor()

    private let db: DatabaseManager
    nonisolated let generationRegistry: GenerationRegistryActor
    private let excludedAssets: ExcludedAssetsActor
    private let privacyActor: PrivacyActor

    /// 故障注入点（测试用）— 模拟事务边界处的崩溃/失败。DEBUG only。
    #if DEBUG
    private var fault: FaultPoint?
    #endif

    public init(
        db: DatabaseManager = .shared,
        generationRegistry: GenerationRegistryActor = .shared,
        excludedAssets: ExcludedAssetsActor = .shared,
        privacyActor: PrivacyActor = .shared
    ) {
        self.db = db
        self.generationRegistry = generationRegistry
        self.excludedAssets = excludedAssets
        self.privacyActor = privacyActor
    }

    // MARK: - Deterministic ID

    /// 确定性记忆 ID — RFC 4122 派生（SHA-256 命名空间，版本 5 / 变体 8），不依赖输入顺序。
    ///
    /// 相同 `sourceLocator` + `sourceType` 恒产生相同 UUID，与摄入顺序无关
    /// （ADR-010 决策-1）。
    public nonisolated static func deterministicID(sourceLocator: String, sourceType: String) -> UUID {
        let namespace = "echo-memory-v1"
        let raw = Data("\(namespace)|\(sourceType)|\(sourceLocator)".utf8)
        let digest = SHA256.hash(data: raw)
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (
            b[0], b[1], b[2], b[3],
            b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11],
            b[12], b[13], b[14], b[15]
        ))
    }

    // MARK: - 确定性 representation ID 派生（WP3 步骤 1a-1f）

    /// 照片 representation ID 恒等于 canonical memory ID
    /// （vectorId == representationId == memoryId，交接计划 WP3 步骤 1a-1b2）。
    public nonisolated static func photoRepresentationID(memoryID: UUID) -> UUID {
        memoryID
    }

    /// 视频帧 representation ID：与既有帧向量 ID 公式完全一致
    /// （deterministicID(assetId|frameN, video_frame)），零语义漂移。
    public nonisolated static func videoFrameRepresentationID(sourceLocator: String, frameIndex: Int) -> UUID {
        deterministicID(
            sourceLocator: "\(sourceLocator)|frame\(frameIndex)",
            sourceType: "video_frame"
        )
    }

    /// 音频 representation ID：父 memory + 固定 「audio」 组件 key 的确定性派生
    /// （交接计划 WP3 步骤 1e-1f）。
    public nonisolated static func audioRepresentationID(memoryID: UUID) -> UUID {
        deterministicID(
            sourceLocator: "\(memoryID.uuidString.lowercased())|audio",
            sourceType: "video_audio"
        )
    }

    // MARK: - Fault Injection (DEBUG only — Nitpick-1: release 不暴露删数据钩子)

    #if DEBUG
    public enum FaultPoint: Sendable, Equatable {
        /// 在向量写入前注入失败（模拟向量存储故障）→ 触发补偿回滚
        case vectorWrite
        /// 在 canonical 提交后、向量写入前注入崩溃 → 补偿清理 canonical
        case afterCanonicalWrite
        /// 在 deleteMemory 向量清理前注入失败（模拟 DB 删除故障，3F.5 W-03）
        case deleteFail
        /// WP3 steps 3k-3t2: 删除管线阶段注入点
        case cacheInvalidation
        case vectorDeletePersist
        case auditPurge
        case canonicalTransaction
    }

    /// WP3 steps 3k-3t2：删除管线协作方（组合根 setter 注入，避免 init 连锁）。
    private var deletionCacheActor: SearchResultCacheActor?

    public func configureDeletionCollaborators(cache: SearchResultCacheActor) {
        deletionCacheActor = cache
    }

    public func setFault(_ fault: FaultPoint?) {
        self.fault = fault
    }
    #endif

    // MARK: - Transactional Commit (US-ING-006)

    /// 事务性写入一条 canonical 记忆 + 其表示 + FTS + 可选向量。
    ///
    /// - Parameters:
    ///   - memory: 规范记忆实体
    ///   - representations: 该记忆的表示通道
    ///   - vectorsByGeneration: generationId → 待写入向量条目
    ///   - traceID: 审计追踪 ID
    public func commit(
        memory: Memory,
        representations: [Representation],
        vectorsByGeneration: [String: [CanonicalVectorEntry]],
        traceID: String
    ) async throws {
        // Phase 1: SQLite 事务 — canonical + representation + FTS 原子提交
        try await writeCanonicalTransaction(memory: memory, representations: representations)

        #if DEBUG
        if fault == .afterCanonicalWrite {
            // 崩溃点：canonical 已提交但向量未写 → 补偿清理，保证无 half-write
            try await compensateCanonical(memoryId: memory.memoryId)
            try await writeTransactionAudit(traceID: traceID, rolledBack: true)
            throw CanonicalRepositoryError.crashAfterCanonicalWrite
        }

        // Phase 2: 向量写入（逐 generation）
        if fault == .vectorWrite {
            try await compensateCanonical(memoryId: memory.memoryId)
            try await writeTransactionAudit(traceID: traceID, rolledBack: true)
            throw CanonicalRepositoryError.vectorWriteInjected
        }
        #endif

        do {
            for (generationId, entries) in vectorsByGeneration {
                guard let store = await generationRegistry.vectorStore(for: generationId) else {
                    throw CanonicalRepositoryError.generationMissing(generationId: generationId)
                }
                for entry in entries {
                    try await store.ingest(vector: entry.vector, id: entry.id, metadata: entry.metadata)
                }
            }
            // CR-147 (CodeRabbit): 持久化受影响 generation 的 store，保证重启后向量不丢失
            // （canonical 行/FTS 已提交，若 .pxkt 磁盘副本无新向量，重启后语义检索失效）
            for generationId in vectorsByGeneration.keys {
                try await generationRegistry.persistStore(generationId: generationId)
            }
        } catch {
            // 补偿回滚：删除已写向量 + canonical 行
            for (generationId, entries) in vectorsByGeneration {
                guard let store = await generationRegistry.vectorStore(for: generationId) else { continue }
                for entry in entries {
                    _ = await store.delete(id: entry.id)
                }
            }
            try await compensateCanonical(memoryId: memory.memoryId)
            try await writeTransactionAudit(traceID: traceID, rolledBack: true)
            throw CanonicalRepositoryError.vectorWriteFailed(underlying: error)
        }

        try await writeTransactionAudit(traceID: traceID, rolledBack: false)
    }

    // MARK: - Reads

    public func loadMemory(memoryId: UUID) async throws -> Memory? {
        let rows = try await db.executeQuery(
            sql: "SELECT memoryId, sourceLocator, canonicalText, sourceType, createdAt, updatedAt, recoverability, originalTimestamp, userEdited, userLocked FROM Memory WHERE memoryId = ?",
            bindings: [.text(memoryId.uuidString)]
        )
        return rows.first.flatMap { Self.rowToMemory($0) }
    }

    /// 按 sourceLocator 定位全部关联记忆 ID（3F.5 生产同步路由）。
    ///
    /// 供 SyncPipeline 删除/替换路径查询；与摄入写入时的确定性 ID 语义一致
    /// （同一 sourceLocator + sourceType 恒映射同一记忆）。
    public func memoryIDs(forSourceLocator sourceLocator: String) async throws -> [String] {
        let rows = try await db.executeQuery(
            sql: "SELECT memoryId FROM Memory WHERE sourceLocator = ?",
            bindings: [.text(sourceLocator)]
        )
        return rows.compactMap { $0["memoryId"]?.stringValue }
    }

    public func loadRepresentations(memoryId: UUID) async throws -> [Representation] {
        let rows = try await db.executeQuery(
            sql: "SELECT representationId, memoryId, modality, preprocessVersion, contentHash FROM Representation WHERE memoryId = ? ORDER BY representationId",
            bindings: [.text(memoryId.uuidString)]
        )
        return rows.compactMap { Self.rowToRepresentation($0) }
    }

    /// FTS5 canonical 文本检索（US-ING-006 AC-3：FTS5 与主事务同步提交）。
    ///
    /// F-3: 用户查询中的 FTS5 语法字符（引号、`*`、括号、AND/OR 等）会导致
    /// MATCH 运行时错误或异常结果。查询按空白分词，每 token 作为短语（引号包裹 +
    /// 内嵌引号转义）以隐式 AND 组合，杜绝语法注入；空查询返回空数组。
    // MARK: - Vector→Memory Forward Mapping (WP1 步骤 3/4)

    /// WP1 步骤 3：单个向量 ID → canonical memory 的类型化映射。
    ///
    /// 经 Representation 表按 representationId 反查 memoryId；
    /// 查无即返回 `.missing`（是否 fail-closed 排除由调用方决定）。
    public func mapVectorID(_ vectorID: UUID, generationID: String) async throws -> CanonicalMappingResult {
        let rows = try await db.executeQuery(
            sql: "SELECT memoryId, modality FROM Representation WHERE representationId = ? LIMIT 1",
            bindings: [.text(vectorID.uuidString)]
        )
        guard let row = rows.first,
              let idString = row["memoryId"]?.stringValue,
              let memoryID = UUID(uuidString: idString),
              let modalityRaw = row["modality"]?.stringValue,
              let modality = Modality(rawValue: modalityRaw) else {
            return .missing(vectorID: vectorID, generationID: generationID)
        }
        // ADR-015 D-7: vectorId == representationId，一对一绑定
        return .mapped(CanonicalVectorBinding(
            vectorID: vectorID,
            representationID: vectorID,
            memoryID: memoryID,
            modality: modality,
            generationID: generationID
        ))
    }

    /// WP1 步骤 4：批量映射 —— 调用方单次仓库交互，结果按入参 ID 键控。
    public func mapVectorIDs(_ vectorIDs: [UUID], generationID: String) async throws -> [UUID: CanonicalMappingResult] {
        var results: [UUID: CanonicalMappingResult] = [:]
        for vectorID in vectorIDs {
            results[vectorID] = try await mapVectorID(vectorID, generationID: generationID)
        }
        return results
    }

    public func searchCanonical(matching query: String, limit: Int = 50) async throws -> [UUID] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map {
            "\"" + String($0).replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        guard !tokens.isEmpty else { return [] }
        let ftsQuery = tokens.joined(separator: " ")
        // DEF-56-006: FTS5 rank（bm25 负分）升序 = 最相关优先，排序先于 LIMIT 截断
        let rows = try await db.executeQuery(
            sql: "SELECT memoryId FROM MemoryFTS WHERE MemoryFTS MATCH ? ORDER BY rank LIMIT ?",
            bindings: [.text(ftsQuery), .int(Int64(limit))]
        )
        return rows.compactMap { row in
            row["memoryId"]?.stringValue.flatMap { UUID(uuidString: $0) }
        }
    }

    // MARK: - Deletion Boundary (D-005 / US-PRV-004/007)

    /// 删除一条记忆，事务性覆盖 canonical + 向量 + FTS + translationCache + 审计。
    ///
    /// - Parameter writeExcluded: 用户选择「仅从 Echo 移除」时为 true →
    ///   写入 ExcludedAssets (US-PRV-004 AC-2)；级联删除时为 false (US-PRV-007 AC-2)。
    /// - Returns: `true` 若记忆存在并被删除
    @discardableResult
    public func deleteMemory(
        memoryId: UUID,
        sourceLocator: String? = nil,
        sourceType: String? = nil,
        writeExcluded: Bool,
        traceID: String
    ) async throws -> Bool {
        let memory = try await loadMemory(memoryId: memoryId)
        guard memory != nil else { return false }

        // D-005 (WP3 steps 3i-3t2): journal 驱动的可恢复删除阶段机。
        // 固定 operationID ⇒ 故障重放幂等更新同一 journal 行。
        let operationID = "del-\(memoryId.uuidString.lowercased())"
        let subject = AuditSubject.memory(memoryId)

        func advance(_ phase: MemoryDeletionPhase,
                     vectors: [GenerationVectorIDs] = []) async throws {
            let j = MemoryDeletionJournal(
                operationID: operationID,
                memoryID: memoryId,
                auditSubjectHash: subject.subjectHash,
                traceID: traceID,
                phase: phase,
                vectorIDsByGeneration: vectors
            )
            try await db.upsertDeletionJournal(j)
        }

        // Phase: planned —— 先于一切副作用持久化
        let generations = try await generationRegistry.loadGenerations()
        try await advance(
            .planned,
            vectors: generations.map {
                GenerationVectorIDs(generationID: $0.generationId, vectorIDs: [memoryId])
            }
        )

        #if DEBUG
        if fault == .deleteFail {
            throw CanonicalRepositoryError.deleteInjected
        }
        #endif

        // Stage 1: cache 失效（协作方经 configureDeletionCollaborators 注入；
        // 未注入时跳过——单元夹具场景无 cache 可失效）
        if let cache = deletionCacheActor {
            _ = try await cache.invalidate(memoryID: memoryId)
            #if DEBUG
            if fault == .cacheInvalidation {
                throw CanonicalRepositoryError.deleteInjected
            }
            #endif
        }
        try await advance(.cacheInvalidated)

        // Stage 2: 全 generation 向量删除（内存实例 + 磁盘副本 F-1）
        var diskCleanupFailed = false
        for gen in generations {
            let generationId = gen.generationId
            if let store = await generationRegistry.vectorStore(for: generationId) {
                _ = await store.delete(id: memoryId)
                do {
                    try await generationRegistry.persistStore(generationId: generationId)
                } catch {
                    diskCleanupFailed = true
                }
            } else {
                let url = await generationRegistry.storeFileURL(for: generationId)
                guard FileManager.default.fileExists(atPath: url.path),
                      let diskStore = try? VectorStoreActor.load(from: url) else { continue }
                _ = await diskStore.delete(id: memoryId)
                do {
                    try await diskStore.save(to: url)
                } catch {
                    diskCleanupFailed = true
                }
            }
        }
        #if DEBUG
        if fault == .vectorDeletePersist {
            throw CanonicalRepositoryError.deleteInjected
        }
        #endif
        try await advance(.vectorsDeleted)

        // Stage 3: subject-linked audit purge（精确按 kind+subjectHash）
        _ = try await privacyActor.purgeAuditRecords(subject: subject, traceID: traceID)
        #if DEBUG
        if fault == .auditPurge {
            throw CanonicalRepositoryError.deleteInjected
        }
        #endif
        try await advance(.auditPurged)

        // Stage 4: canonical transaction（canonical + FTS + translationCache 原子清除）
        try await db.executeTransaction([
            .init(sql: "DELETE FROM MemoryFTS WHERE memoryId = ?", bindings: [.text(memoryId.uuidString)]),
            .init(sql: "DELETE FROM translationCache WHERE memoryId = ?", bindings: [.text(memoryId.uuidString)]),
            .init(sql: "DELETE FROM Memory WHERE memoryId = ?", bindings: [.text(memoryId.uuidString)]),
        ])
        #if DEBUG
        if fault == .canonicalTransaction {
            throw CanonicalRepositoryError.deleteInjected
        }
        #endif
        try await advance(.canonicalDeleted)

        // ExcludedAssets 契约 (US-PRV-004 AC-2 / US-PRV-007 AC-2; CR-1 PR#56)
        let effectiveLocator = sourceLocator ?? memory?.sourceLocator
        let effectiveType = sourceType ?? memory?.sourceType
        var excludedActuallyWritten = false
        if writeExcluded, let locator = effectiveLocator, let st = effectiveType {
            try await excludedAssets.add(assetId: locator, sourceType: st, traceID: traceID)
            excludedActuallyWritten = true
        }

        // 完成审计（不含 memory subject 明文；携带向量磁盘清理标记）
        let policy = await privacyActor.getPolicy()
        try? await privacyActor.writeAuditLog(
            eventType: .memoryDeleted,
            traceID: traceID,
            policyVersion: policy.policyVersion,
            success: true,
            sourceType: effectiveType,
            excludedWritten: excludedActuallyWritten,
            content: diskCleanupFailed ? "vectorDiskCleanupFailed=true" : nil
        )

        // Completed：journal 自移除（防 subject 经 journal 重引入）
        try await advance(.completed)
        try await db.deleteDeletionJournal(operationID: operationID)
        return true
    }

    /// WP3 steps 5a-5f：consent revoke 三接通组合入口——
    /// cache 全量失效 + AuditLog 全量 purge + deletion journal 清理。
    public func purgeEverythingForConsent() async throws {
        if let cache = deletionCacheActor {
            _ = try await cache.invalidateAll()
        }
        _ = try await privacyActor.purgeAllAuditRecords()
        try await db.deleteAllDeletionJournals()
    }

    /// 原始文件级联删除（US-PRV-007）— 不写 ExcludedAssets，清理无效排除记录。
    ///
    /// - Returns: 删除统计（内存删除数 + 是否清理了无效排除记录）
    public func cascadeDeleteFromOriginal(
        assetId: String,
        sourceType: String,
        traceID: String
    ) async throws -> CascadeDeleteResult {
        let rows = try await db.executeQuery(
            sql: "SELECT memoryId FROM Memory WHERE sourceLocator = ?",
            bindings: [.text(assetId)]
        )
        var deleted = 0
        for row in rows {
            guard let mid = row["memoryId"]?.stringValue.flatMap({ UUID(uuidString: $0) }) else { continue }
            if try await deleteMemory(memoryId: mid, sourceType: sourceType, writeExcluded: false, traceID: traceID) {
                deleted += 1
            }
        }

        // 清理 ExcludedAssets 无效记录（原始文件已消失，排除项无意义）
        var excludedAutoCleaned = false
        if try await excludedAssets.contains(assetId: assetId) {
            _ = try await excludedAssets.remove(assetId: assetId)
            excludedAutoCleaned = true
        }

        let policy = await privacyActor.getPolicy()
        try? await privacyActor.writeAuditLog(
            eventType: .cascadeDeleteFromOriginal,
            traceID: traceID,
            policyVersion: policy.policyVersion,
            success: true,
            sourceType: sourceType,
            affectedCount: deleted,
            excludedWritten: false,
            content: excludedAutoCleaned ? "excludedAutoCleaned=true|userNotified=true" : nil
        )
        return CascadeDeleteResult(deletedCount: deleted, excludedAutoCleaned: excludedAutoCleaned)
    }

    // MARK: - Internal Transaction Helpers

    private func writeCanonicalTransaction(memory: Memory, representations: [Representation]) async throws {
        var writes: [DatabaseManager.DBWrite] = [
            .init(
                sql: """
                INSERT OR REPLACE INTO Memory (memoryId, sourceLocator, canonicalText, sourceType, createdAt, updatedAt, recoverability, originalTimestamp, userEdited, userLocked)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(memory.memoryId.uuidString),
                    .text(memory.sourceLocator),
                    memory.canonicalText.map(DBBinding.text) ?? .null,
                    .text(memory.sourceType),
                    .double(memory.createdAt.timeIntervalSince1970),
                    .double(memory.updatedAt.timeIntervalSince1970),
                    .text(memory.recoverability.rawValue),
                    memory.originalTimestamp.map { .double($0.timeIntervalSince1970) } ?? .null,
                    .int(memory.userEdited ? 1 : 0),
                    .int(memory.userLocked ? 1 : 0),
                ]
            ),
            .init(
                sql: "DELETE FROM Representation WHERE memoryId = ?",
                bindings: [.text(memory.memoryId.uuidString)]
            ),
            .init(
                sql: "DELETE FROM MemoryFTS WHERE memoryId = ?",
                bindings: [.text(memory.memoryId.uuidString)]
            ),
            // CR-3 (PR#56 review): 每记忆恰好一行 FTS，与 representation 数量解耦
            .init(
                sql: "INSERT INTO MemoryFTS (memoryId, canonicalText, sourceType) VALUES (?, ?, ?)",
                bindings: [
                    .text(memory.memoryId.uuidString),
                    memory.canonicalText.map(DBBinding.text) ?? .null,
                    .text(memory.sourceType),
                ]
            ),
        ]
        for rep in representations {
            writes.append(.init(
                sql: """
                INSERT OR REPLACE INTO Representation (representationId, memoryId, modality, preprocessVersion, contentHash)
                VALUES (?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(rep.representationId.uuidString),
                    .text(rep.memoryId.uuidString),
                    .text(rep.modality.rawValue),
                    .text(rep.preprocessVersion),
                    .text(rep.contentHash),
                ]
            ))
        }
        try await db.executeTransaction(writes)
    }

    private func compensateCanonical(memoryId: UUID) async throws {
        try await db.executeTransaction([
            .init(sql: "DELETE FROM MemoryFTS WHERE memoryId = ?", bindings: [.text(memoryId.uuidString)]),
            .init(sql: "DELETE FROM Memory WHERE memoryId = ?", bindings: [.text(memoryId.uuidString)]),
        ])
    }

    private func writeTransactionAudit(traceID: String, rolledBack: Bool) async throws {
        let policy = await privacyActor.getPolicy()
        try? await privacyActor.writeAuditLog(
            eventType: .ingestTransaction,
            traceID: traceID,
            policyVersion: policy.policyVersion,
            success: !rolledBack,
            affectedCount: 1,
            content: rolledBack ? "rolledBack=true" : "rolledBack=false"
        )
    }

    // MARK: - Row Mapping

    private static func rowToMemory(_ row: [String: DBValue]) -> Memory? {
        guard let memoryId = row["memoryId"]?.stringValue.flatMap({ UUID(uuidString: $0) }),
              let sourceLocator = row["sourceLocator"]?.stringValue,
              let sourceType = row["sourceType"]?.stringValue else { return nil }
        return Memory(
            memoryId: memoryId,
            sourceLocator: sourceLocator,
            canonicalText: row["canonicalText"]?.stringValue,
            sourceType: sourceType,
            createdAt: Date(timeIntervalSince1970: row["createdAt"]?.doubleValue ?? 0),
            updatedAt: Date(timeIntervalSince1970: row["updatedAt"]?.doubleValue ?? 0),
            recoverability: Recoverability(rawValue: row["recoverability"]?.stringValue ?? "full") ?? .full,
            originalTimestamp: row["originalTimestamp"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            userEdited: (row["userEdited"]?.intValue ?? 0) == 1,
            userLocked: (row["userLocked"]?.intValue ?? 0) == 1
        )
    }

    private static func rowToRepresentation(_ row: [String: DBValue]) -> Representation? {
        guard let repId = row["representationId"]?.stringValue.flatMap({ UUID(uuidString: $0) }),
              let mid = row["memoryId"]?.stringValue.flatMap({ UUID(uuidString: $0) }),
              let modalityRaw = row["modality"]?.stringValue,
              let modality = Modality(rawValue: modalityRaw) else { return nil }
        return Representation(
            representationId: repId,
            memoryId: mid,
            modality: modality,
            preprocessVersion: row["preprocessVersion"]?.stringValue ?? "",
            contentHash: row["contentHash"]?.stringValue ?? ""
        )
    }
}

// MARK: - Supporting Types

/// 待写入 generation 向量存储的条目。
public struct CanonicalVectorEntry: Sendable {
    public nonisolated let id: UUID
    public nonisolated let vector: [Float]
    public nonisolated let metadata: Data?

    public nonisolated init(id: UUID, vector: [Float], metadata: Data? = nil) {
        self.id = id
        self.vector = vector
        self.metadata = metadata
    }
}

/// 级联删除结果（US-PRV-007）。
public struct CascadeDeleteResult: Sendable, Equatable {
    public nonisolated let deletedCount: Int
    public nonisolated let excludedAutoCleaned: Bool

    public nonisolated init(deletedCount: Int, excludedAutoCleaned: Bool) {
        self.deletedCount = deletedCount
        self.excludedAutoCleaned = excludedAutoCleaned
    }
}

// MARK: - Error Types

public enum CanonicalRepositoryError: Error, LocalizedError, Sendable {
    case crashAfterCanonicalWrite
    case vectorWriteInjected
    case deleteInjected
    case generationMissing(generationId: String)
    case vectorWriteFailed(underlying: Error)
    /// deleteMemory 未找到对应记忆（CR-11：false 结果显式化为错误，不再静默跳过）
    case memoryNotFound(memoryId: String)
    /// 记忆 ID 字符串无法解析为 UUID（CR-11：不再回退随机 UUID 静默跳过删除）
    case invalidMemoryID(memoryId: String)

    public var errorDescription: String? {
        switch self {
        case .crashAfterCanonicalWrite:
            return "Injected crash after canonical write (test fault)"
        case .vectorWriteInjected:
            return "Injected vector write failure (test fault)"
        case .deleteInjected:
            return "Injected canonical delete failure (test fault)"
        case .generationMissing(let generationId):
            return "Generation vector store missing: \(generationId)"
        case .vectorWriteFailed(let error):
            return "Vector write failed: \(error.localizedDescription)"
        case .memoryNotFound(let memoryId):
            return "Canonical memory not found: \(memoryId)"
        case .invalidMemoryID(let memoryId):
            return "Invalid memory UUID: \(memoryId)"
        }
    }
}
