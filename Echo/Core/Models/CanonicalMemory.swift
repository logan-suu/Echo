// ==========================================
// 文件: CanonicalMemory.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-A.1 (规范 Memory 与 Representation)
//            调研报告 §15.1 (数据模型: Memory / Representation)
//            docs/01-spec/用户故事与验收标准规格书.md → US-AWK-007 (编辑字段)
//            docs/decisions/ADR-010-canonical-generation-lifecycle.md 决策-1
// 任务: R-A.1 - 规范 Memory 与 Representation 数据模型
//      3F.4 - Canonical storage（US-AWK-007 originalTimestamp/userEdited/userLocked）
// AC 覆盖: memoryId, sourceLocator, canonicalText, sourceType, timestamps, recoverability
//          representationId, memoryId, modality, preprocessVersion, contentHash
//          US-AWK-007 AC-2 (userEdited + originalTimestamp), AC-4 (userLocked), AC-6 (originalTimestamp 备份)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007 (禁止 unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-31 | 更新: 2026-08-09 (3F.4 编辑字段)
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
    /// 覆盖时间戳的原始值备份（US-AWK-007 AC-6，仅详情页展示，不参与检索）
    public nonisolated let originalTimestamp: Date?
    /// 用户手动编辑标记（US-AWK-007 AC-2）
    public nonisolated let userEdited: Bool
    /// 用户选择手工维护，同步永久跳过（US-AWK-007 AC-4）
    public nonisolated let userLocked: Bool

    public nonisolated init(
        memoryId: UUID = UUID(),
        sourceLocator: String,
        canonicalText: String? = nil,
        sourceType: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        recoverability: Recoverability = .full,
        originalTimestamp: Date? = nil,
        userEdited: Bool = false,
        userLocked: Bool = false
    ) {
        self.memoryId = memoryId
        self.sourceLocator = sourceLocator
        self.canonicalText = canonicalText
        self.sourceType = sourceType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recoverability = recoverability
        self.originalTimestamp = originalTimestamp
        self.userEdited = userEdited
        self.userLocked = userLocked
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

// MARK: - Vector→Memory Mapping (WP3 steps 0a/0b, §7.5)

/// 向量 ↔ representation ↔ canonical memory 的一对一绑定（ADR-015 D-7：
/// 新建向量强制 vectorId == representationId，限定 generation scope）。
public nonisolated struct CanonicalVectorBinding: Sendable, Equatable {
    public nonisolated let vectorID: UUID
    public nonisolated let representationID: UUID
    public nonisolated let memoryID: UUID
    public nonisolated let modality: Modality
    public nonisolated let generationID: String

    public nonisolated init(
        vectorID: UUID,
        representationID: UUID,
        memoryID: UUID,
        modality: Modality,
        generationID: String
    ) {
        self.vectorID = vectorID
        self.representationID = representationID
        self.memoryID = memoryID
        self.modality = modality
        self.generationID = generationID
    }
}

/// 向量 ID → canonical memory 的类型化映射结果（交接计划 §7.5 三态；
/// WP1 二态已升级为 WP3 全形态，歧义 fail-closed 判定就绪）。
public nonisolated enum CanonicalMappingResult: Sendable, Equatable {
    case mapped(CanonicalVectorBinding)
    case missing(vectorID: UUID, generationID: String)
    case ambiguous(vectorID: UUID, generationID: String, candidateMemoryIDs: [UUID])
}
