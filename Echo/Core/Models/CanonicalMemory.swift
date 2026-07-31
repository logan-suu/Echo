// ==========================================
// 文件: CanonicalMemory.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-A.1 (规范 Memory 与 Representation)
//            调研报告 §15.1 (数据模型: Memory / Representation)
// 任务: R-A.1 - 规范 Memory 与 Representation 数据模型
// AC 覆盖: memoryId, sourceLocator, canonicalText, sourceType, timestamps, recoverability
//          representationId, memoryId, modality, preprocessVersion, contentHash
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007 (禁止 unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-31
// ==========================================

import Foundation

// MARK: - Recoverability

/// 记忆的可恢复性标记 — 决定不可恢复记录在 UI 中的 UX。
public enum Recoverability: String, Sendable, Codable, Equatable {
    /// 可从原始数据源完全恢复
    case full
    /// 可部分恢复（如仅元数据可恢复，内容不可）
    case partial
    /// 无法恢复
    case unrecoverable
}

// MARK: - Modality

/// 表示的模态 — 定义单个记忆的多种表示通道。
public enum Modality: String, Sendable, Codable, Equatable, CaseIterable {
    /// 文本稠密向量（E5 等）
    case textDense
    /// 视觉稠密向量（SigLIP2 等）
    case visionDense
    /// OCR 文本
    case ocrText
    /// 词法索引（JiebaFTS5 等）
    case lexical
}

// MARK: - Memory (Canonical)

/// 规范记忆实体 — 记忆的事实源（R-A.1）。
///
/// 与旧 `MemoryEntry`（向量存储 payload）的关系：
/// - `MemoryEntry` 是摄入时的扁平载荷，其向量存储在 ProximaKit 中
/// - `Memory` 是 SQLite 中的规范事实源，一个记忆可关联多个 `Representation`
/// - 向后兼容：旧数据保留在向量存储中，新 schema 通过 SQLite 映射层查询
public struct Memory: Sendable, Codable, Equatable {
    /// 记忆唯一标识符
    public nonisolated let memoryId: UUID
    /// 源定位符（PHAsset.localIdentifier / 备忘录 URI 等）
    public nonisolated let sourceLocator: String
    /// 人类可读的规范文本摘要（非原始全文）
    public nonisolated let canonicalText: String?
    /// 数据源类型（"photo" / "note" / "voice" 等）
    public nonisolated let sourceType: String
    /// 创建时间戳
    public nonisolated let createdAt: Date
    /// 最后更新时间戳
    public nonisolated let updatedAt: Date
    /// 可恢复性
    public nonisolated let recoverability: Recoverability

    public nonisolated init(
        memoryId: UUID = UUID(),
        sourceLocator: String,
        canonicalText: String? = nil,
        sourceType: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        recoverability: Recoverability = .full
    ) {
        self.memoryId = memoryId
        self.sourceLocator = sourceLocator
        self.canonicalText = canonicalText
        self.sourceType = sourceType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recoverability = recoverability
    }
}

// MARK: - Representation

/// 记忆的一种表示 — 一个记忆的多种模态通道（R-A.1）。
public struct Representation: Sendable, Codable, Equatable {
    /// 表示唯一标识符
    public nonisolated let representationId: UUID
    /// 所属记忆 ID
    public nonisolated let memoryId: UUID
    /// 模态
    public nonisolated let modality: Modality
    /// 预处理版本（模型 + tokenizer + pooling 版本标识）
    public nonisolated let preprocessVersion: String
    /// 内容哈希（用于构建校验）
    public nonisolated let contentHash: String

    public nonisolated init(
        representationId: UUID = UUID(),
        memoryId: UUID,
        modality: Modality,
        preprocessVersion: String,
        contentHash: String
    ) {
        self.representationId = representationId
        self.memoryId = memoryId
        self.modality = modality
        self.preprocessVersion = preprocessVersion
        self.contentHash = contentHash
    }
}
