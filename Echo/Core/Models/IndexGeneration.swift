// ==========================================
// 文件: IndexGeneration.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-A.3 (IndexGeneration)
//            调研报告 §15.1 (数据模型: IndexGeneration / IndexBuildItem)
// 任务: R-A.3 - 分代索引管理
// AC 覆盖: generationId, indexType, manifestId, state, counts, validationDigest
//          generationId, representationId, state, error, retryCount
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007 (禁止 unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-31
// ==========================================

import Foundation

// MARK: - Generation State

/// 分代索引的状态。
public enum GenerationState: String, Sendable, Codable, Equatable {
    /// 构建中（影子索引）
    case building
    /// 构建完成，可验证（未激活）
    case ready
    /// 当前活跃（服务路由指向）
    case active
    /// 已退役（保留观察期，不服务）
    case retired
}

// MARK: - IndexGeneration

/// 分代索引 — 单一模型空间的一代索引（R-A.3）。
///
/// 与旧单一 HNSW 的关系：
/// - 每个 generation 对应一个独立 VectorStoreActor（独立 HNSW 文件）
/// - 不同模型空间（如 legacy-512-v1 与 text_dense/e5-v1）并存，不共享向量
/// - 通过 ActiveRouteSet 原子切换服务路由
public struct IndexGeneration: Sendable, Codable, Equatable {
    /// 分代 ID（如 "legacy-512-v1"、"text_dense/e5-v1"）
    public nonisolated let generationId: String
    /// 索引类型（"text_dense" / "vision_dense" / "ocr_text" / "lexical"）
    public nonisolated let indexType: String
    /// 关联的 ModelManifest.modelId（nil 表示词法等非模型索引）
    public nonisolated let manifestId: String?
    /// 当前状态
    public nonisolated let state: GenerationState
    /// 已索引条目数
    public nonisolated let counts: Int
    /// 校验摘要（哈希，用于完整性验证）
    public nonisolated let validationDigest: String?

    public nonisolated init(
        generationId: String,
        indexType: String,
        manifestId: String? = nil,
        state: GenerationState = .building,
        counts: Int = 0,
        validationDigest: String? = nil
    ) {
        self.generationId = generationId
        self.indexType = indexType
        self.manifestId = manifestId
        self.state = state
        self.counts = counts
        self.validationDigest = validationDigest
    }
}

// MARK: - IndexBuildItem

/// 分代索引的逐项构建状态（R-A.3）— 支持断点续传与失败重试。
public struct IndexBuildItem: Sendable, Codable, Equatable {
    /// 所属分代 ID
    public nonisolated let generationId: String
    /// 表示 ID（关联 Representation）
    public nonisolated let representationId: String
    /// 构建状态（pending / building / done / failed）
    public nonisolated let state: String
    /// 失败原因
    public nonisolated let error: String?
    /// 重试次数
    public nonisolated let retryCount: Int

    public nonisolated init(
        generationId: String,
        representationId: String,
        state: String = "pending",
        error: String? = nil,
        retryCount: Int = 0
    ) {
        self.generationId = generationId
        self.representationId = representationId
        self.state = state
        self.error = error
        self.retryCount = retryCount
    }
}
