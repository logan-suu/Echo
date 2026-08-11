// ==========================================
// 文件: DataOverviewService.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-009 (数据处理可视化, 合并入 US-SYS-001)
//            docs/05-planning/phase3f-execution-plan.md → 3F.7 (UI 到 Core 全域接线)
// 任务: 3F.7 - UI 到 Core 全域接线
// AC 覆盖: US-SRC-009 AC-1 (各数据源条目数/存储占用/向量维度), AC-2 (模型状态),
//          AC-3 (≤5s 实时更新), AC-4 (JSON 导出), AC-5 (.dataOverviewAccessed 审计)
//          PR#59 CR 修复: translationCacheBytes (US-SET-003 缓存占用), DataOverviewError LocalizedError,
//                         审计写失败 os.Logger 可观测, URL.resourceValues 文件大小
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §5.4 (hash-only 审计), §4.4 (L1~L4 错误分级),
//           R-006/R-007/R-008
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-11
// ==========================================

import Foundation
import os

// MARK: - Data Overview Snapshot

/// 数据概览快照 — 设置页「数据概览」的实时统计（US-SRC-009 AC-1/AC-2）。
public struct DataOverviewSnapshot: Sendable, Equatable {
    /// 各数据源条目数（键 = sourceType: "photo" / "video" / "note" / "voice" / "text"）
    public nonisolated let countsBySourceType: [String: Int]
    /// 记忆总数
    public nonisolated let memoryCount: Int
    /// 数据库文件字节数（SQLite）
    public nonisolated let databaseBytes: Int64
    /// 向量索引文件字节数（全部 generation .pxkt）
    public nonisolated let vectorStoreBytes: Int64
    /// 翻译缓存条目数
    public nonisolated let translationCacheCount: Int
    /// 翻译缓存存储字节数（US-SET-003 缓存占用展示用）
    public nonisolated let translationCacheBytes: Int64
    /// 活跃 generation 的向量维度（键 = generationId）
    public nonisolated let vectorDimensions: [String: Int]
    /// 模型加载状态摘要（loaded / loading / failed / notLoaded 计数）
    public nonisolated let modelLoadedCount: Int
    public nonisolated let modelFailedCount: Int
    public nonisolated let modelNotLoadedCount: Int
    public nonisolated let modelTotalCount: Int
    /// 快照生成时间（≤5s 刷新判定，US-SRC-009 AC-3）
    public nonisolated let updatedAt: Date

    public nonisolated init(
        countsBySourceType: [String: Int],
        memoryCount: Int,
        databaseBytes: Int64,
        vectorStoreBytes: Int64,
        translationCacheCount: Int,
        translationCacheBytes: Int64,
        vectorDimensions: [String: Int],
        modelLoadedCount: Int,
        modelFailedCount: Int,
        modelNotLoadedCount: Int,
        modelTotalCount: Int,
        updatedAt: Date = Date()
    ) {
        self.countsBySourceType = countsBySourceType
        self.memoryCount = memoryCount
        self.databaseBytes = databaseBytes
        self.vectorStoreBytes = vectorStoreBytes
        self.translationCacheCount = translationCacheCount
        self.translationCacheBytes = translationCacheBytes
        self.vectorDimensions = vectorDimensions
        self.modelLoadedCount = modelLoadedCount
        self.modelFailedCount = modelFailedCount
        self.modelNotLoadedCount = modelNotLoadedCount
        self.modelTotalCount = modelTotalCount
        self.updatedAt = updatedAt
    }
}

// MARK: - Data Overview Service

/// 数据概览服务 — 实时统计各数据源条目数、存储占用、向量维度与模型状态（US-SRC-009）。
///
/// ## 设计
/// - Actor 隔离：所有 SQLite 读取通过 DatabaseManager 串行化（AGENTS.md §4.2）
/// - 只读服务：不修改任何业务表，仅统计
/// - 审计：每次访问（快照/导出）写 `.dataOverviewAccessed`（US-SRC-009 AC-5）
public actor DataOverviewService {

    // MARK: - Dependencies

    private let db: DatabaseManager
    private let generationRegistry: GenerationRegistryActor
    private let modelLoader: ModelLoaderActor
    private let privacyActor: PrivacyActor

    // MARK: - Initialization

    public init(
        db: DatabaseManager = .shared,
        generationRegistry: GenerationRegistryActor = .shared,
        modelLoader: ModelLoaderActor = .shared,
        privacyActor: PrivacyActor = .shared
    ) {
        self.db = db
        self.generationRegistry = generationRegistry
        self.modelLoader = modelLoader
        self.privacyActor = privacyActor
    }

    // MARK: - Snapshot (US-SRC-009 AC-1/AC-2/AC-3)

    /// 生成当前数据概览快照，并写 `.dataOverviewAccessed` 审计（AC-5）。
    ///
    /// - Parameter traceID: 审计追溯 ID（默认自动生成）
    /// - Returns: 实时统计快照
    public func snapshot(traceID: String = UUID().uuidString) async throws -> DataOverviewSnapshot {
        let started = Date()
        let policy = await privacyActor.getPolicy()

        let counts = try await countMemoriesBySourceType()
        let memoryCount = counts.values.reduce(0, +)
        let databaseBytes = try await dbFileSize()
        let vectorStoreBytes = try await vectorStoreSize()
        let (cacheCount, cacheBytes) = try await translationCacheStats()
        let dimensions = try await activeVectorDimensions()

        let status = await modelLoader.overallStatus

        let auditResult = try? await privacyActor.writeAuditLog(
            eventType: .dataOverviewAccessed,
            traceID: traceID,
            policyVersion: policy.policyVersion,
            success: true,
            affectedCount: memoryCount,
            elapsedMs: Int(Date().timeIntervalSince(started) * 1000),
            content: "databaseBytes=\(databaseBytes)|vectorBytes=\(vectorStoreBytes)|generations=\(dimensions.count)"
        )
        if auditResult == nil {
            // 审计写入失败为 best-effort（不阻断），但需可观测（PR#59 CR Minor）
            auditLogger.error("dataOverviewAccessed audit write failed (traceID \(traceID, privacy: .public))")
        }

        return DataOverviewSnapshot(
            countsBySourceType: counts,
            memoryCount: memoryCount,
            databaseBytes: databaseBytes,
            vectorStoreBytes: vectorStoreBytes,
            translationCacheCount: cacheCount,
            translationCacheBytes: cacheBytes,
            vectorDimensions: dimensions,
            modelLoadedCount: status.loadedCount,
            modelFailedCount: status.failedCount,
            modelNotLoadedCount: status.notLoadedCount,
            modelTotalCount: status.allModelsCount,
            updatedAt: Date()
        )
    }

    // MARK: - JSON Export (US-SRC-009 AC-4)

    /// 导出统计报告（JSON）。
    ///
    /// - Parameter traceID: 审计追溯 ID
    /// - Returns: UTF-8 JSON 字符串（含快照时间）
    public func exportJSON(traceID: String = UUID().uuidString) async throws -> String {
        let snap = try await snapshot(traceID: traceID)
        let dateFormatter = ISO8601DateFormatter()
        let dict: [String: Any] = [
            "exportedAt": dateFormatter.string(from: Date()),
            "memoryCount": snap.memoryCount,
            "countsBySourceType": snap.countsBySourceType,
            "storageBytes": [
                "database": snap.databaseBytes,
                "vectorStore": snap.vectorStoreBytes,
            ],
            "translationCacheCount": snap.translationCacheCount,
            "vectorDimensions": snap.vectorDimensions,
            "modelStatus": [
                "loaded": snap.modelLoadedCount,
                "failed": snap.modelFailedCount,
                "notLoaded": snap.modelNotLoadedCount,
                "total": snap.modelTotalCount,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw DataOverviewError.exportFailed
        }
        return json
    }

    // MARK: - Private Helpers

    /// 统计 Memory 表按 sourceType 的条目数。
    private func countMemoriesBySourceType() async throws -> [String: Int] {
        let rows = try await db.executeQuery(
            sql: "SELECT sourceType, COUNT(*) AS cnt FROM Memory GROUP BY sourceType",
            bindings: []
        )
        var counts: [String: Int] = [:]
        for row in rows {
            if let type = row["sourceType"]?.stringValue {
                counts[type] = row["cnt"]?.intValue.map(Int.init) ?? 0
            }
        }
        return counts
    }

    /// SQLite 数据库文件大小（字节）。
    private func dbFileSize() async throws -> Int64 {
        await db.databaseSize()
    }

    /// 全部 generation 向量索引文件大小总和（字节）。
    private func vectorStoreSize() async throws -> Int64 {
        let generations = (try? await generationRegistry.loadGenerations()) ?? []
        var total: Int64 = 0
        for gen in generations {
            let url = await generationRegistry.storeFileURL(for: gen.generationId)
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if let size {
                total += Int64(size)
            }
        }
        return total
    }

    /// translationCache 条目数与存储字节数。
    private func translationCacheStats() async throws -> (count: Int, bytes: Int64) {
        let rows = try await db.executeQuery(
            sql: "SELECT COUNT(*) AS cnt, COALESCE(SUM(length(translatedText)), 0) AS bytes FROM translationCache",
            bindings: []
        )
        let row = rows.first
        let count = row?["cnt"]?.intValue.map(Int.init) ?? 0
        let bytes = row?["bytes"]?.intValue ?? 0
        return (count, bytes)
    }

    /// 活跃 generation 的向量维度（generationId → dimension）。
    private func activeVectorDimensions() async throws -> [String: Int] {
        let generations = (try? await generationRegistry.loadGenerations()) ?? []
        var dimensions: [String: Int] = [:]
        for gen in generations {
            dimensions[gen.generationId] = gen.dimension
        }
        return dimensions
    }
}

// MARK: - Error

/// 数据概览错误（L2 可恢复）。
public enum DataOverviewError: Error, LocalizedError {
    /// JSON 导出失败
    case exportFailed

    public nonisolated var errorDescription: String? {
        switch self {
        case .exportFailed: return "Unable to export data overview"
        }
    }
}

/// 审计写失败日志（best-effort 审计不阻断 Pipeline 时可观测）。
nonisolated private let auditLogger = Logger(subsystem: "com.echo.Echo", category: "audit")
