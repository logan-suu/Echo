// ==========================================
// 文件: ModelManifestActor.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-A.2 (ModelManifest)
//            调研报告 §15.1 (数据模型: ModelManifest)
// 任务: R-A.2 - ModelManifestActor 模型身份与许可登记
// AC 覆盖: register/loadAll/load/updateAll/remove (model_manifest 表 CRUD)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007/R-008
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-31
// ==========================================

import Foundation

/// 模型身份与许可登记 Actor — 管理 `model_manifest` 表的 CRUD（R-A.2）。
///
/// ## Actor 隔离（AGENTS.md §4.2）
/// - 无自身可变状态，所有持久化通过 DatabaseManager 串行化
/// - 跨 Actor 调用必须 await（R-008）
public actor ModelManifestActor {

    // MARK: - Singleton

    public static let shared = ModelManifestActor()

    // MARK: - Properties

    private let db: DatabaseManager

    // MARK: - Initialization

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    // MARK: - Register

    /// 注册一个模型 manifest（幂等：modelId 已存在则更新）。
    public func register(_ manifest: ModelManifest) async throws {
        _ = try await db.executeWrite(
            sql: """
            INSERT OR REPLACE INTO ModelManifest (
                modelId, revision, artifactHash, licenseId, runtime,
                tokenizer, promptTemplate, pooling, normalization, dimension, quantization
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(manifest.modelId),
                .text(manifest.revision),
                .text(manifest.artifactHash),
                .text(manifest.licenseId),
                .text(manifest.runtime.rawValue),
                manifest.tokenizer.map(DBBinding.text) ?? .null,
                manifest.promptTemplate.map(DBBinding.text) ?? .null,
                .text(manifest.pooling.rawValue),
                .text(manifest.normalization.rawValue),
                .int(Int64(manifest.dimension)),
                manifest.quantization.map(DBBinding.text) ?? .null,
            ]
        )
    }

    // MARK: - Query

    /// 加载全部模型 manifest。
    public func loadAll() async throws -> [ModelManifest] {
        let rows = try await db.executeQuery(
            sql: "SELECT * FROM ModelManifest ORDER BY modelId",
            bindings: []
        )
        return try rows.map { try Self.rowToManifest($0) }
    }

    /// 按 modelId 加载单个 manifest。
    public func load(modelId: String) async throws -> ModelManifest? {
        let rows = try await db.executeQuery(
            sql: "SELECT * FROM ModelManifest WHERE modelId = ?",
            bindings: [.text(modelId)]
        )
        return try rows.first.map { try Self.rowToManifest($0) }
    }

    /// 删除指定模型 manifest。
    @discardableResult
    public func remove(modelId: String) async throws -> Bool {
        let changes = try await db.executeWrite(
            sql: "DELETE FROM ModelManifest WHERE modelId = ?",
            bindings: [.text(modelId)]
        )
        return changes > 0
    }

    /// 清空全部 manifest。
    public func removeAll() async throws {
        _ = try await db.executeWrite(sql: "DELETE FROM ModelManifest", bindings: [])
    }

    // MARK: - Row Mapping

    private static func rowToManifest(_ row: [String: DBValue]) throws -> ModelManifest {
        guard let modelId = row["modelId"]?.stringValue,
              let revision = row["revision"]?.stringValue,
              let artifactHash = row["artifactHash"]?.stringValue,
              let licenseId = row["licenseId"]?.stringValue,
              let runtimeRaw = row["runtime"]?.stringValue,
              let runtime = ModelRuntime(rawValue: runtimeRaw),
              let poolingRaw = row["pooling"]?.stringValue,
              let pooling = PoolingStrategy(rawValue: poolingRaw),
              let normRaw = row["normalization"]?.stringValue,
              let normalization = Normalization(rawValue: normRaw),
              let dim = row["dimension"]?.intValue else {
            throw DatabaseError.rowMappingFailed
        }
        return ModelManifest(
            modelId: modelId,
            revision: revision,
            artifactHash: artifactHash,
            licenseId: licenseId,
            runtime: runtime,
            tokenizer: row["tokenizer"]?.stringValue,
            promptTemplate: row["promptTemplate"]?.stringValue,
            pooling: pooling,
            normalization: normalization,
            dimension: Int(dim),
            quantization: row["quantization"]?.stringValue
        )
    }
}
