// ==========================================
// 文件: Memory.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-004 (图片记忆摄入)
//            docs/02-architecture/架构设计文档.md §2.1 (IngestPipeline)
// 任务: 2.3 - IngestPipeline：图片摄入
// AC 覆盖: AC-1 (privacyBlurApplied=false), AC-2 (EXIF 元数据完整保留),
//          AC-3 (CLIP 向量 768 维), AC-4 (PHAsset 引用),
//          AC-5 (审计 .imageIngested)
// 架构约束: AGENTS.md §4.1 (Pipeline 纯函数性), R-007 (禁止 unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-09
// ==========================================

import Foundation

// MARK: - Memory Entry

/// 被摄入的记忆条目 — 对应 US-ING-004 图片记忆摄入数据模型。
///
/// AC-1: `privacyBlurApplied` 固定为 false，禁止任何模糊处理。
/// AC-2: `exifMetadata` 以 JSON Data 形式保留完整 EXIF，GPS 按 UserPolicy 决定。
/// AC-3: `embedding` 为 MobileCLIP-B LT 生成的 768 维 CLIP 向量。
/// AC-4: `assetId` 为 PHAsset.localIdentifier，不复制原始文件存储。
/// AC-5: 审计时使用 `traceID` + `.imageIngested` 事件。
public struct MemoryEntry: Sendable, Codable, Equatable {
    /// 记忆唯一标识符
    public nonisolated let id: UUID
    /// PHAsset.localIdentifier — 原始图片引用，AC-4：不复制存储
    public nonisolated let assetId: String
    /// CLIP 向量（MobileCLIP-B LT 输出，768 维），AC-3：与文本向量空间对齐
    public nonisolated let embedding: [Float]
    /// 数据源类型（图片记忆固定为 "photo"）
    public nonisolated let sourceType: String
    /// 记忆关联的时间戳（来自原始文件的创建日期）
    public nonisolated let timestamp: Date
    /// JSON 编码的 EXIF 元数据，AC-2：完整保留。nil 表示获取失败或文件无 EXIF
    public nonisolated let exifMetadata: Data?
    /// AC-1：禁止模糊处理，固定为 false
    public nonisolated let privacyBlurApplied: Bool
    /// 关联的审计追溯 ID（由 Pipeline 入口生成）
    public nonisolated let traceID: String
    /// 关联的记忆组 ID（同一次摄入中的多条向量共享，US-ING-005 视频摄入）
    public nonisolated var memoryGroupId: UUID?

    // MARK: - Init

    public nonisolated init(
        id: UUID = UUID(),
        assetId: String,
        embedding: [Float],
        sourceType: String = "photo",
        timestamp: Date = Date(),
        exifMetadata: Data? = nil,
        privacyBlurApplied: Bool = false,
        traceID: String,
        memoryGroupId: UUID? = nil
    ) {
        self.id = id
        self.assetId = assetId
        self.embedding = embedding
        self.sourceType = sourceType
        self.timestamp = timestamp
        self.exifMetadata = exifMetadata
        self.privacyBlurApplied = privacyBlurApplied
        self.traceID = traceID
        self.memoryGroupId = memoryGroupId
    }

    // MARK: - Metadata Encoding

    /// 将 MemoryEntry 序列化为 JSON Data，用于存入 VectorStoreActor.metadata。
    /// 使用 JSONSerialization 手动序列化（避免 Codable 的 MainActor 隔离），纯数据转换，nonisolated。
    public nonisolated func encodeMetadata() throws -> Data {
        var dict: [String: Any] = [
            "assetId": assetId,
            "sourceType": sourceType,
            "timestamp": timestamp.timeIntervalSince1970,
            "hasExif": exifMetadata != nil,
            "privacyBlurApplied": privacyBlurApplied,
            "traceID": traceID
        ]
        if let mgId = memoryGroupId?.uuidString {
            dict["memoryGroupId"] = mgId
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    /// 从 VectorStoreActor 返回的 metadata Data 解码 MemoryMetadata。
    public nonisolated static func decodeMetadata(from data: Data) throws -> MemoryMetadata {
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return MemoryMetadata(
            assetId: (dict["assetId"] as? String) ?? "",
            sourceType: (dict["sourceType"] as? String) ?? "photo",
            timestamp: (dict["timestamp"] as? TimeInterval) ?? 0,
            hasExif: (dict["hasExif"] as? Bool) ?? false,
            privacyBlurApplied: (dict["privacyBlurApplied"] as? Bool) ?? false,
            traceID: (dict["traceID"] as? String) ?? "",
            memoryGroupId: dict["memoryGroupId"] as? String
        )
    }
}

// MARK: - Memory Metadata (lightweight, stored as VectorStoreActor metadata)

/// 存入 VectorStoreActor 元数据的轻量结构体 — 不含大字段（如 embedding/exifMetadata）。
///
/// 向量本身存储在 HNSW 索引中，EXIF 等大数据体由 Pipeline 层按需从 PHAsset 重新获取。
public struct MemoryMetadata: Sendable, Codable, Equatable {
    public nonisolated let assetId: String
    public nonisolated let sourceType: String
    public nonisolated let timestamp: TimeInterval
    public nonisolated let hasExif: Bool
    public nonisolated let privacyBlurApplied: Bool
    public nonisolated let traceID: String
    public nonisolated let memoryGroupId: String?

    public nonisolated init(
        assetId: String,
        sourceType: String,
        timestamp: TimeInterval,
        hasExif: Bool = false,
        privacyBlurApplied: Bool = false,
        traceID: String,
        memoryGroupId: String? = nil
    ) {
        self.assetId = assetId
        self.sourceType = sourceType
        self.timestamp = timestamp
        self.hasExif = hasExif
        self.privacyBlurApplied = privacyBlurApplied
        self.traceID = traceID
        self.memoryGroupId = memoryGroupId
    }
}
