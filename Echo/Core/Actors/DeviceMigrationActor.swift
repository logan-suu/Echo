// ==========================================
// 文件: DeviceMigrationActor.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-007 (设备迁移)
//            docs/decisions/ADR-008-source-import-boundaries.md §决策-6 (ECHOMIG1 加密迁移包)
//            docs/05-planning/phase3f-execution-plan.md §4.6.7 (3F.7 迁移安全子契约)
// 任务: 3F.7 - UI 到 Core 全域接线 (US-SRC-007)
// AC 覆盖: US-SRC-007 AC-1 (仅本地传输), AC-2 (ExcludedAssets 随本地迁移), AC-4 (覆盖/合并/冲突),
//          AC-5 (迁移后完整性校验), AC-6 (不导出全部原始记忆), AC-7 (.deviceMigrationCompleted 审计)
//          PR#59 修复: 🔴-1 AC-5 完整性校验按策略语义 — overwrite 总数 / merge 逐条 ID 存在性
//                      (向量/FTS 行级校验见 DEF-59-003); 🟡-7 审计 method/batchPolicy 参数化
//          PR#59 CR 修复: CR-1 allBoth 派生确定性 ID 保留两版本; CR-3 复用 importPackage 返回的 manifest;
//                         CR-4 传播 deleteMemory/excludedAssets.add 错误; CR-5 audit success=integrityPassed
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §5.4 (hash-only 审计), R-001 (无网络), R-007/R-008
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-11
// ==========================================

import Foundation
import CryptoKit

// MARK: - Merge Strategy (US-SRC-007 AC-4)

/// 目标设备已有数据时的合并策略。
public enum MigrationMergeStrategy: String, Sendable, Codable, Equatable {
    /// 覆盖：删除目标设备原有数据，替换为源设备数据
    case overwrite
    /// 合并：保留两边独有的记忆；相同记忆 ID 冲突项需逐项/批量解决
    case merge
}

/// 批量冲突应用策略（US-SRC-007 AC-4：显示冲突总数，允许批量应用）。
///
/// 注：AC-4 的「逐项自定义」冲突解析属迁移 UI surface（per-record resolution），
/// 无 UI 接线时不存在消费方，因此不在此声明 per-record 枚举（见 PR#59 CR-1 处置）。
public enum BatchConflictPolicy: String, Sendable, Codable, Equatable {
    /// 全部使用源设备版本
    case allSource
    /// 全部使用目标设备版本
    case allTarget
    /// 两者都保留 — 目标版本保留原 ID，源版本以派生确定性 ID 导入副本（两版本共存）
    case allBoth
}

// MARK: - Migration Result

/// 迁移导入结果。
public struct DeviceMigrationResult: Sendable, Equatable {
    public nonisolated let memoryCount: Int
    public nonisolated let excludedCount: Int
    public nonisolated let conflictCount: Int
    public nonisolated let overwrittenCount: Int
    public nonisolated let integrityCheckPassed: Bool

    public nonisolated init(
        memoryCount: Int,
        excludedCount: Int,
        conflictCount: Int,
        overwrittenCount: Int,
        integrityCheckPassed: Bool
    ) {
        self.memoryCount = memoryCount
        self.excludedCount = excludedCount
        self.conflictCount = conflictCount
        self.overwrittenCount = overwrittenCount
        self.integrityCheckPassed = integrityCheckPassed
    }
}

// MARK: - Device Migration Actor

/// 设备迁移 Actor — ECHOMIG1 加密包的导出/导入编排（US-SRC-007）。
///
/// ## 边界（ADR-008 §决策-6）
/// - 仅本地 AirDrop / 系统分享 / Finder-iTunes 加密备份恢复；无 CloudKit、无网络（US-SRC-007 AC-1）
/// - 导出仅包含记忆的最小规范字段（canonical 引用），**不导出全部原始记忆文件**（AC-6）
/// - K_transfer 由调用方单独展示（base64url），本 Actor 不落盘、不记录
/// - 导入校验全部通过后才原子发布（§4.6.7 validation order）
public actor DeviceMigrationActor {

    // MARK: - Dependencies

    private let db: DatabaseManager
    private let canonicalRepository: CanonicalMemoryRepositoryActor
    private let excludedAssets: ExcludedAssetsActor
    private let privacyActor: PrivacyActor
    private let generationRegistry: GenerationRegistryActor
    private let textEmbedder: (any EmbedderProtocol)?

    // MARK: - Initialization

    public init(
        db: DatabaseManager = .shared,
        canonicalRepository: CanonicalMemoryRepositoryActor? = nil,
        excludedAssets: ExcludedAssetsActor = .shared,
        privacyActor: PrivacyActor = .shared,
        generationRegistry: GenerationRegistryActor = .shared,
        textEmbedder: (any EmbedderProtocol)? = nil
    ) {
        self.db = db
        self.canonicalRepository = canonicalRepository
            ?? CanonicalMemoryRepositoryActor(db: db, generationRegistry: generationRegistry)
        self.excludedAssets = excludedAssets
        self.privacyActor = privacyActor
        self.generationRegistry = generationRegistry
        self.textEmbedder = textEmbedder
    }
    // MARK: - Export (US-SRC-007 AC-1/AC-6)

    /// 导出 ECHOMIG1 加密包。
    ///
    /// - Parameter traceID: 审计追溯 ID
    /// - Returns: 包字节 + 一次性传输密钥（调用方以 base64url/QR 单独展示，绝不嵌入包内）
    public func exportPackage(traceID: String = UUID().uuidString) async throws -> (package: Data, transferKey: SymmetricKey) {
        // R-006 PrivacyCheckpoint at entry (DEF-59-004, 3F.10 DECISION-2): deny-by-default
        // consent gate + audit before reading canonical/ExcludedAssets. Fail-closed on denial.
        let checkpoint = await privacyActor.validate(operation: .migration, traceID: traceID, sourceTypes: [])
        guard checkpoint.isAllowed else {
            throw DeviceMigrationError.publicationFailed("privacy checkpoint denied")
        }

        // 读取全部 canonical 记忆的最小字段（不含原始文件，AC-6）
        let memories = try await loadAllMemories()
        var records: [DeviceMigrationRecord] = []
        var payloads: [String: Data] = [:]

        for memory in memories {
            let payload = try canonicalPayload(for: memory)
            let digest = SHA256.hash(data: payload).hexString
            let record = DeviceMigrationRecord(
                type: "memory",
                id: memory.memoryId.uuidString.lowercased(),
                byteLength: payload.count,
                sha256: digest
            )
            records.append(record)
            payloads[record.id] = payload
        }

        // ExcludedAssets 随本地迁移（AC-2）
        // 一次全量读取，上限与 §4.6.7 的 maxRecordCount 对齐（排除项表通常远小于该上限）
        let excluded = try await excludedAssets.listAll(limit: EchoMigrationFormat.maxRecordCount, offset: 0)
        for item in excluded {
            let payload = excludedPayload(assetId: item.assetId, sourceType: item.sourceType, excludedAt: item.excludedAt)
            let digest = SHA256.hash(data: payload).hexString
            let record = DeviceMigrationRecord(
                type: "excludedAsset",
                id: item.assetId,
                byteLength: payload.count,
                sha256: digest
            )
            records.append(record)
            payloads[record.id] = payload
        }

        guard !records.isEmpty else {
            // 空库仍导出合法包（chunk 0 manifest + 无数据块的 manifest-only 会被导入拒绝，
            // 因此至少需要一个记录；空库返回空导出）。
            throw DeviceMigrationError.publicationFailed("no data to export")
        }

        let transferKey = SymmetricKey(size: .bits256)
        let package = try DeviceMigrationService.exportPackage(
            records: records,
            payloads: payloads,
            transferKey: transferKey
        )
        return (package, transferKey)
    }

    /// 将传输密钥编码为 base64url（一次性展示，不落盘、不入剪贴板）。
    public nonisolated static func encodeTransferKey(_ key: SymmetricKey) -> String {
        let data = key.withUnsafeBytes { Data($0) }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 从 base64url 解析传输密钥。
    public nonisolated static func decodeTransferKey(_ base64url: String) throws -> SymmetricKey {
        var s = base64url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        guard let data = Data(base64Encoded: s), data.count == 32 else {
            throw DeviceMigrationError.tamperDetected("invalid transfer key")
        }
        return SymmetricKey(data: data)
    }

    // MARK: - Import (US-SRC-007 AC-4/AC-5)

    /// 导入并应用 ECHOMIG1 加密包。
    ///
    /// - Parameters:
    ///   - package: 包字节
    ///   - transferKey: 用户输入的传输密钥
    ///   - strategy: 覆盖或合并（AC-4）
    ///   - batchPolicy: 批量冲突策略（AC-4，merge 时使用）
    ///   - fromDevice: 源设备标识
    ///   - toDevice: 目标设备标识（当前设备）
    ///   - method: 迁移方式（AC-7: "airdrop" / "localBackup"）
    ///   - traceID: 审计追溯 ID
    /// - Returns: 导入结果（含完整性校验）
    public func importPackage(
        package: Data,
        transferKey: SymmetricKey,
        strategy: MigrationMergeStrategy,
        batchPolicy: BatchConflictPolicy = .allSource,
        fromDevice: String,
        toDevice: String,
        method: String = "airdrop",
        traceID: String = UUID().uuidString
    ) async throws -> DeviceMigrationResult {
        // R-006 PrivacyCheckpoint at entry (DEF-59-004 acceptance evidence, 3F.10 DECISION-2).
        let checkpoint = await privacyActor.validate(operation: .migration, traceID: traceID, sourceTypes: [])
        guard checkpoint.isAllowed else {
            throw DeviceMigrationError.publicationFailed("privacy checkpoint denied")
        }

        let started = Date()
        // (1) 全量校验（§4.6.7 validation order）— 失败时活动库/路由保持不变。
        //     importPackage 返回解析好的 manifest，避免重复解析包（CR-3）。
        let (manifest, payloads) = try DeviceMigrationService.importPackage(package, transferKey: transferKey)

        var memoryCount = 0
        var excludedCount = 0
        var conflictCount = 0
        var overwrittenCount = 0
        var importedMemoryIDs: [UUID] = []

        // (2) 覆盖策略：清除目标设备原有数据（仅 canonical/向量，不删原始文件）。
        //     删除失败必须传播（CR-4），不得静默继续。
        if strategy == .overwrite {
            let existing = try await loadAllMemories()
            for memory in existing {
                try Task.checkCancellation()
                _ = try await canonicalRepository.deleteMemory(
                    memoryId: memory.memoryId,
                    writeExcluded: false,
                    traceID: traceID
                )
            }
            overwrittenCount = existing.count
        }

        // (3) 应用记录前解析一次活跃路由 + 文本嵌入器（避免每记录重复解析，Nitpick）
        let hasMemories = manifest.records.contains { $0.type == "memory" }
        var activeRoute: ActiveRouteSet?
        var embedder: (any EmbedderProtocol)?
        if hasMemories {
            guard let route = try await generationRegistry.loadActiveRoute() else {
                throw DeviceMigrationError.publicationFailed("no active generation route")
            }
            activeRoute = route
            if let injected = textEmbedder {
                embedder = injected
            } else {
                embedder = await MainActor.run { E5Embedder() }
            }
        }

        // (4) 应用记录
        for record in manifest.records {
            try Task.checkCancellation()
            guard let payload = payloads[record.id] else { continue }
            if record.type == "memory" {
                let memory = try decodeCanonicalPayload(payload)
                let exists = try await canonicalRepository.loadMemory(memoryId: memory.memoryId) != nil
                if exists && strategy == .merge {
                    conflictCount += 1
                    switch batchPolicy {
                    case .allTarget:
                        continue
                    case .allSource:
                        break
                    case .allBoth:
                        // 两者都保留：目标版本保留原 ID，源版本以派生确定性 ID 导入副本（CR-1）
                        let bothCopy = Memory(
                            memoryId: Self.derivedMemoryID(from: memory.memoryId),
                            sourceLocator: memory.sourceLocator,
                            canonicalText: memory.canonicalText,
                            sourceType: memory.sourceType,
                            createdAt: memory.createdAt,
                            updatedAt: memory.updatedAt,
                            recoverability: memory.recoverability,
                            originalTimestamp: memory.originalTimestamp,
                            userEdited: memory.userEdited,
                            userLocked: memory.userLocked
                        )
                        guard let route = activeRoute, let embedder else {
                            throw DeviceMigrationError.publicationFailed("no active generation route")
                        }
                        try await applyMemory(bothCopy, payload: payload, traceID: traceID, route: route, embedder: embedder)
                        importedMemoryIDs.append(bothCopy.memoryId)
                        memoryCount += 1
                        continue
                    }
                }
                guard let route = activeRoute, let embedder else {
                    throw DeviceMigrationError.publicationFailed("no active generation route")
                }
                try await applyMemory(memory, payload: payload, traceID: traceID, route: route, embedder: embedder)
                importedMemoryIDs.append(memory.memoryId)
                memoryCount += 1
            } else if record.type == "excludedAsset" {
                let item = try decodeExcludedPayload(payload)
                // 写入错误传播（CR-4）；excludedCount 仅在成功后自增
                try await excludedAssets.add(assetId: item.assetId, sourceType: item.sourceType, traceID: traceID)
                excludedCount += 1
            } else {
                throw DeviceMigrationError.unsupportedRecordType(record.type)
            }
        }

        // (5) 完整性校验（AC-5）：导入结果与实际库一致
        // - overwrite: 覆盖后仅保留导入数据 → Memory 表总数应等于导入数
        // - merge: 目标独有数据保留，总数校验不适用 → 逐条校验每个导入记忆 ID 均存在
        let integrityPassed = try await verifyIntegrity(
            strategy: strategy,
            importedMemoryIDs: importedMemoryIDs,
            expectedMemory: memoryCount
        )

        // (6) 审计（AC-7）— success 反映 integrityCheckPassed（CR-5），失败迁移可被审计查询
        let policy = await privacyActor.getPolicy()
        try? await privacyActor.writeAuditLog(
            eventType: .deviceMigrationCompleted,
            traceID: traceID,
            policyVersion: policy.policyVersion,
            success: integrityPassed,
            sourceType: "migration",
            affectedCount: memoryCount,
            elapsedMs: Int(Date().timeIntervalSince(started) * 1000),
            content: "fromDevice=\(fromDevice)|toDevice=\(toDevice)|integrityCheckPassed=\(integrityPassed)|method=\(method)|mergeStrategy=\(strategy.rawValue)|batchPolicy=\(batchPolicy.rawValue)|conflictResolutions=\(conflictCount)"
        )

        // WP6 7c/7d: 目标迁移为每个导入 memory 写入新的 subject-linked hash-only 审计
        // （跨设备不复制源 AuditLog，仅记录新迁移操作的 subject 身份）
        if integrityPassed {
            for memoryID in importedMemoryIDs {
                let subject = AuditSubject.memory(memoryID)
                try? await privacyActor.writeAuditLog(
                    eventType: .deviceMigrationCompleted,
                    traceID: traceID,
                    policyVersion: policy.policyVersion,
                    success: true,
                    sourceType: "migration",
                    subjectKind: subject.kind,
                    subjectHash: subject.subjectHash
                )
            }
        }

        return DeviceMigrationResult(
            memoryCount: memoryCount,
            excludedCount: excludedCount,
            conflictCount: conflictCount,
            overwrittenCount: overwrittenCount,
            integrityCheckPassed: integrityPassed
        )
    }

    // MARK: - Private Helpers

    private func loadAllMemories() async throws -> [Memory] {
        let rows = try await db.executeQuery(
            sql: "SELECT memoryId, sourceLocator, canonicalText, sourceType, createdAt, updatedAt, recoverability, originalTimestamp, userEdited, userLocked FROM Memory ORDER BY memoryId",
            bindings: []
        )
        return rows.compactMap { row in
            guard let mid = row["memoryId"]?.stringValue.flatMap({ UUID(uuidString: $0) }),
                  let locator = row["sourceLocator"]?.stringValue,
                  let sourceType = row["sourceType"]?.stringValue else { return nil }
            return Memory(
                memoryId: mid,
                sourceLocator: locator,
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
    }

    /// 记忆最小字段载荷（JSON，不含原始文件，AC-6）。
    private nonisolated func canonicalPayload(for memory: Memory) throws -> Data {
        let dict: [String: Any] = [
            "memoryId": memory.memoryId.uuidString.lowercased(),
            "sourceLocator": memory.sourceLocator,
            "canonicalText": memory.canonicalText ?? NSNull(),
            "sourceType": memory.sourceType,
            "createdAt": memory.createdAt.timeIntervalSince1970,
            "updatedAt": memory.updatedAt.timeIntervalSince1970,
            "recoverability": memory.recoverability.rawValue,
            "originalTimestamp": memory.originalTimestamp?.timeIntervalSince1970 ?? NSNull(),
            "userEdited": memory.userEdited,
            "userLocked": memory.userLocked,
        ]
        return try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    private nonisolated func decodeCanonicalPayload(_ data: Data) throws -> Memory {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mid = (dict["memoryId"] as? String).flatMap({ UUID(uuidString: $0) }),
              let locator = dict["sourceLocator"] as? String,
              let sourceType = dict["sourceType"] as? String else {
            throw DeviceMigrationError.invalidManifest("corrupt memory payload")
        }
        return Memory(
            memoryId: mid,
            sourceLocator: locator,
            canonicalText: dict["canonicalText"] as? String,
            sourceType: sourceType,
            createdAt: Date(timeIntervalSince1970: (dict["createdAt"] as? TimeInterval) ?? 0),
            updatedAt: Date(timeIntervalSince1970: (dict["updatedAt"] as? TimeInterval) ?? 0),
            recoverability: Recoverability(rawValue: (dict["recoverability"] as? String) ?? "full") ?? .full,
            originalTimestamp: (dict["originalTimestamp"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) },
            userEdited: (dict["userEdited"] as? Bool) ?? false,
            userLocked: (dict["userLocked"] as? Bool) ?? false
        )
    }

    private nonisolated func excludedPayload(assetId: String, sourceType: String, excludedAt: Date) -> Data {
        let dict: [String: Any] = [
            "assetId": assetId,
            "sourceType": sourceType,
            "excludedAt": excludedAt.timeIntervalSince1970,
        ]
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }

    private nonisolated func decodeExcludedPayload(_ data: Data) throws -> (assetId: String, sourceType: String, excludedAt: Date) {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assetId = dict["assetId"] as? String,
              let sourceType = dict["sourceType"] as? String else {
            throw DeviceMigrationError.invalidManifest("corrupt excluded payload")
        }
        return (
            assetId,
            sourceType,
            Date(timeIntervalSince1970: (dict["excludedAt"] as? TimeInterval) ?? 0)
        )
    }

    /// 应用单条记忆（commit 到 canonical + 活跃 generation 向量）。
    /// route/embedder 由 importPackage 预先解析一次传入（Nitpick：避免每记录重复解析）。
    private func applyMemory(
        _ memory: Memory,
        payload: Data,
        traceID: String,
        route: ActiveRouteSet,
        embedder: any EmbedderProtocol
    ) async throws {
        var representations: [Representation] = []
        var vectors: [String: [CanonicalVectorEntry]] = [:]
        if let text = memory.canonicalText, !text.isEmpty {
            let embedding = try await embedder.embedText(text)
            let textGen = route.textGeneration
            representations.append(Representation(
                memoryId: memory.memoryId,
                modality: .textDense,
                preprocessVersion: "e5-v1",
                contentHash: SHA256.hash(data: payload).hexString
            ))
            vectors[textGen] = [CanonicalVectorEntry(id: memory.memoryId, vector: embedding)]
        }
        try await canonicalRepository.commit(
            memory: memory,
            representations: representations,
            vectorsByGeneration: vectors,
            traceID: traceID
        )
    }

    /// 完整性校验（AC-5）：导入结果与实际库一致。
    /// - overwrite: 覆盖后仅保留导入数据 → Memory 表总数应等于导入数。
    /// - merge: 目标独有数据保留，总数校验不适用 → 逐条校验每个导入记忆 ID 均存在。
    /// 仅校验 Memory 表（canonical 行）语义；向量/FTS 逐行校验见 DEF-59-03（延后追踪）。
    private func verifyIntegrity(
        strategy: MigrationMergeStrategy,
        importedMemoryIDs: [UUID],
        expectedMemory: Int
    ) async throws -> Bool {
        switch strategy {
        case .overwrite:
            let rows = try await db.executeQuery(sql: "SELECT COUNT(*) AS cnt FROM Memory", bindings: [])
            let actual = rows.first?["cnt"]?.intValue.map(Int.init) ?? 0
            return actual == expectedMemory
        case .merge:
            for id in importedMemoryIDs {
                guard try await canonicalRepository.loadMemory(memoryId: id) != nil else { return false }
            }
            return true
        }
    }

    /// 为「两者都保留」冲突导入副本派生确定性不冲突的 memoryId（CR-1）。
    /// SHA-256(源 memoryId 小写字符串 + 域盐) 取 16 字节 → UUID v5 风格，确定且防碰撞。
    public nonisolated static func derivedMemoryID(from sourceID: UUID) -> UUID {
        var data = Data()
        data.append(sourceID.uuidString.lowercased().data(using: .utf8)!)
        data.append("|echo-migration-keep-both".data(using: .utf8)!)
        let digest = SHA256.hash(data: data)
        var uuidBytes = Array(digest.prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
        var uuid = UUID()
        withUnsafeMutableBytes(of: &uuid) { $0.copyBytes(from: Data(uuidBytes)) }
        return uuid
    }
}
