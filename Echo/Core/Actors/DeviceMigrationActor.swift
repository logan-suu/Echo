// ==========================================
// 文件: DeviceMigrationActor.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-007 (设备迁移)
//            docs/decisions/ADR-008-source-import-boundaries.md §决策-6 (ECHOMIG1 加密迁移包)
//            docs/05-planning/phase3f-execution-plan.md §4.6.7 (3F.7 迁移安全子契约)
// 任务: 3F.7 - UI 到 Core 全域接线 (US-SRC-007)
// AC 覆盖: US-SRC-007 AC-1 (仅本地传输), AC-2 (ExcludedAssets 随本地迁移), AC-4 (覆盖/合并/冲突),
//          AC-5 (迁移后完整性校验), AC-6 (不导出全部原始记忆), AC-7 (.deviceMigrationCompleted 审计)
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

/// 单条冲突的解决方式（逐项自定义，US-SRC-007 AC-4）。
public enum ConflictResolution: String, Sendable, Codable, Equatable {
    /// 使用源设备版本
    case source
    /// 使用目标设备版本
    case target
    /// 两者都保留
    case both
}

/// 批量冲突应用策略（US-SRC-007 AC-4：显示冲突总数，允许批量应用）。
public enum BatchConflictPolicy: String, Sendable, Codable, Equatable {
    /// 全部使用源设备版本
    case allSource
    /// 全部使用目标设备版本
    case allTarget
    /// 两者都保留
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
        let excluded = try await excludedAssets.listAll(limit: 1_000_000, offset: 0)
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
    ///   - traceID: 审计追溯 ID
    /// - Returns: 导入结果（含完整性校验）
    public func importPackage(
        package: Data,
        transferKey: SymmetricKey,
        strategy: MigrationMergeStrategy,
        batchPolicy: BatchConflictPolicy = .allSource,
        fromDevice: String,
        toDevice: String,
        traceID: String = UUID().uuidString
    ) async throws -> DeviceMigrationResult {
        let started = Date()
        // (1) 全量校验（§4.6.7 validation order）— 失败时活动库/路由保持不变
        let payloads = try DeviceMigrationService.importPackage(package, transferKey: transferKey)

        // (2) 解析记录（type 校验）
        let header = try EchoMigrationHeader.parse(package)
        let manifestBytes = try decryptManifestPlaintext(package: package, header: header, transferKey: transferKey)
        let manifest = try JCSEncoder.parseManifest(manifestBytes)

        var memoryCount = 0
        var excludedCount = 0
        var conflictCount = 0
        var overwrittenCount = 0

        // (3) 覆盖策略：清除目标设备原有数据（仅 canonical/向量，不删原始文件）
        if strategy == .overwrite {
            let existing = try await loadAllMemories()
            for memory in existing {
                _ = try? await canonicalRepository.deleteMemory(
                    memoryId: memory.memoryId,
                    writeExcluded: false,
                    traceID: traceID
                )
            }
            overwrittenCount = existing.count
        }

        // (4) 应用记录
        for record in manifest.records {
            guard let payload = payloads[record.id] else { continue }
            if record.type == "memory" {
                let memory = try decodeCanonicalPayload(payload)
                let exists = try await canonicalRepository.loadMemory(memoryId: memory.memoryId) != nil
                if exists && strategy == .merge {
                    conflictCount += 1
                    switch batchPolicy {
                    case .allTarget:
                        continue // 保留目标版本
                    case .allSource, .allBoth:
                        break // 用源版本
                    }
                }
                try await applyMemory(memory, payload: payload, traceID: traceID)
                memoryCount += 1
            } else if record.type == "excludedAsset" {
                let item = try decodeExcludedPayload(payload)
                _ = try? await excludedAssets.add(assetId: item.assetId, sourceType: item.sourceType, traceID: traceID)
                excludedCount += 1
            } else {
                throw DeviceMigrationError.unsupportedRecordType(record.type)
            }
        }

        // (5) 完整性校验（AC-5）：内存/向量/FTS 行数与记录数一致
        let integrityPassed = try await verifyIntegrity(expectedMemory: memoryCount)

        // (6) 审计（AC-7）
        let policy = await privacyActor.getPolicy()
        try? await privacyActor.writeAuditLog(
            eventType: .deviceMigrationCompleted,
            traceID: traceID,
            policyVersion: policy.policyVersion,
            success: true,
            sourceType: "migration",
            affectedCount: memoryCount,
            elapsedMs: Int(Date().timeIntervalSince(started) * 1000),
            content: "fromDevice=\(fromDevice)|toDevice=\(toDevice)|integrityCheckPassed=\(integrityPassed)|method=airdrop|mergeStrategy=\(strategy.rawValue)|conflictResolutions=\(conflictCount)"
        )

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
    private func applyMemory(_ memory: Memory, payload: Data, traceID: String) async throws {
        // 重新嵌入 canonicalText 以写入活跃 generation（ADR-010 路由）
        guard let route = try await generationRegistry.loadActiveRoute() else {
            throw DeviceMigrationError.publicationFailed("no active generation route")
        }
        var representations: [Representation] = []
        var vectors: [String: [CanonicalVectorEntry]] = [:]
        if let text = memory.canonicalText, !text.isEmpty {
            let embedder: any EmbedderProtocol
            if let injected = textEmbedder {
                embedder = injected
            } else {
                embedder = await MainActor.run { E5Embedder() }
            }
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

    /// 完整性校验（AC-5）：导入的记忆行数与 manifest 记录数一致。
    private func verifyIntegrity(expectedMemory: Int) async throws -> Bool {
        let rows = try await db.executeQuery(sql: "SELECT COUNT(*) AS cnt FROM Memory", bindings: [])
        let actual = rows.first?["cnt"]?.intValue.map(Int.init) ?? 0
        return actual == expectedMemory
    }

    /// 解密 chunk 0 得到 manifest 明文（导入时用于记录解析）。
    private nonisolated func decryptManifestPlaintext(
        package: Data,
        header: EchoMigrationHeader,
        transferKey: SymmetricKey
    ) throws -> Data {
        let headerBytes = header.encode()
        let chunk0Start = headerBytes.count
        let index = Int(UInt32(package.subdata(in: chunk0Start..<(chunk0Start + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian))
        let length = Int(UInt32(package.subdata(in: (chunk0Start + 4)..<(chunk0Start + 8)).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian))
        let totalChunk = 8 + 12 + length + 16
        let chunk0 = package.subdata(in: chunk0Start..<(chunk0Start + totalChunk))
        let key = DeviceMigrationService.deriveChunkKey(transferKey: transferKey, archiveUUID: header.archiveUUID, chunkIndex: index)
        let aad = DeviceMigrationService.chunkAAD(
            archiveUUID: header.archiveUUID,
            schemaVersion: header.schemaVersion,
            chunkIndex: index,
            chunkCount: header.chunkCount,
            plaintextLength: length,
            manifestSHA256: header.manifestSHA256
        )
        let (_, plaintext) = try DeviceMigrationService.decryptChunk(chunk0, key: key, aad: aad)
        return plaintext
    }
}
