// ==========================================
// 文件: TextEmbedding.swift
// 对应规格: 自然语言照片检索交接计划 §7.1（提议契约）
// 任务: WP1 - 独立缺陷修复（E5 显式 query/passage 上下文）
// AC 覆盖: WP1 步骤 1a-1d（生产搜索 .query / 生产摄入 .passage）、步骤 2c-2d（nonisolated 声明）
// 架构约束: AGENTS.md §4.2 (Actor 隔离)；SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor 下值类型显式 nonisolated
// 生成时间: 2026-08-25
// ==========================================

import Foundation

/// 文本嵌入上下文 —— 区分检索侧查询与摄入侧内容（交接计划 §7.1；R-3.8 前缀注入）。
///
/// - `.query`: 查询侧（E5 注入 `"query: "` 前缀）——生产搜索必须显式传入
/// - `.passage`: 摄入侧（E5 注入 `"passage: "` 前缀）——生产摄入必须显式传入
///
/// legacy 无参 `embedText(_:)` 视为 deprecated 兼容桥（默认等价 .passage），
/// 生产代码禁止再直接调用无参版本（交接计划根因 C7）。
public nonisolated enum TextEmbeddingContext: String, Sendable, Codable, Equatable {
    case query
    case passage
}

// MARK: - Contextual Text Embedder Protocol (WP1 步骤 2b)

/// 上下文感知文本嵌入协议 —— 显式携带 query/passage 上下文（交接计划 §7.1）。
///
/// 声明为 `nonisolated protocol`：requirements 不绑定 MainActor，
/// actor 测试替身与生产 actor 均可直接 conform；async witness 保持
/// actor-isolated，调用方一律 `try await`（R-008）。
/// E5 摄入传 `.passage`，检索/OCR 查询传 `.query`。
public nonisolated protocol ContextualTextEmbedder: Sendable {
    /// 模型清单身份（model-manifest.json 对应条目 ID）
    nonisolated var modelManifestID: String { get }
    /// 原生输出维度（E5 = 384）
    nonisolated var dimension: Int { get }

    func embed(
        text: String,
        context: TextEmbeddingContext,
        traceID: String
    ) async throws -> [Float]
}
