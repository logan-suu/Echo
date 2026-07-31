// ==========================================
// 文件: ModelManifest.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-A.2 (ModelManifest)
//            调研报告 §15.1 (数据模型: ModelManifest)
// 任务: R-A.2 - ModelManifest 模型身份与许可登记
// AC 覆盖: modelId, revision, artifactHash, licenseId, runtime, tokenizer,
//          prompt, pooling, normalization, dimension, quantization
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007 (禁止 unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-31
// ==========================================

import Foundation

// MARK: - Model Runtime

/// 模型推理运行时。
public enum ModelRuntime: String, Sendable, Codable, Equatable {
    /// Core ML（.mlmodelc）
    case coreML
    /// MLX Swift
    case mlxSwift
    /// whisper.cpp（GGUF）
    case whisperCpp
    /// ONNX Runtime
    case onnx
}

// MARK: - Pooling Strategy

/// 嵌入池化策略 — 定义 token 级输出如何聚合为句子向量。
public enum PoolingStrategy: String, Sendable, Codable, Equatable {
    /// 掩码均值池化（E5 等）
    case maskedMean
    /// 最后一个 token（Qwen3 等）
    case lastToken
    /// CLS token（BERT 类）
    case cls
    /// 无池化（单向量输出模型）
    case none
}

// MARK: - Normalization

/// 向量归一化策略。
public enum Normalization: String, Sendable, Codable, Equatable {
    /// L2 归一化
    case l2
    /// 不归一化
    case none
}

// MARK: - ModelManifest

/// 模型身份与许可登记（R-A.2）— 定义嵌入函数的身份。
///
/// 取代 `ModelLoaderActor.ModelType` 硬编码 enum 的信息量不足问题：
/// - 含 revision、artifactHash、licenseId 等发布工件信息
/// - 含 runtime、tokenizer、prompt、pooling、normalization、dimension 等推理合同
public struct ModelManifest: Sendable, Codable {
    /// 模型 ID（如 "e5-small-v1"）
    public nonisolated let modelId: String
    /// 固定 revision（git commit hash）
    public nonisolated let revision: String
    /// 工件 SHA256
    public nonisolated let artifactHash: String
    /// 许可 ID（如 "apache-2.0" / "mit" / "research-only"）
    public nonisolated let licenseId: String
    /// 推理运行时
    public nonisolated let runtime: ModelRuntime
    /// tokenizer 标识（如 "sentencepiece"）
    public nonisolated let tokenizer: String?
    /// 提示模板（E5 的 "query: " / "passage: " 等）
    public nonisolated let promptTemplate: String?
    /// 池化策略
    public nonisolated let pooling: PoolingStrategy
    /// 归一化策略
    public nonisolated let normalization: Normalization
    /// 输出向量维度
    public nonisolated let dimension: Int
    /// 量化信息（如 "4bit"）
    public nonisolated let quantization: String?

    public nonisolated init(
        modelId: String,
        revision: String,
        artifactHash: String,
        licenseId: String,
        runtime: ModelRuntime,
        tokenizer: String? = nil,
        promptTemplate: String? = nil,
        pooling: PoolingStrategy = .none,
        normalization: Normalization = .none,
        dimension: Int,
        quantization: String? = nil
    ) {
        self.modelId = modelId
        self.revision = revision
        self.artifactHash = artifactHash
        self.licenseId = licenseId
        self.runtime = runtime
        self.tokenizer = tokenizer
        self.promptTemplate = promptTemplate
        self.pooling = pooling
        self.normalization = normalization
        self.dimension = dimension
        self.quantization = quantization
    }
}

// MARK: - Equatable (nonisolated)

extension ModelManifest: Equatable {
    nonisolated public static func == (lhs: ModelManifest, rhs: ModelManifest) -> Bool {
        lhs.modelId == rhs.modelId &&
            lhs.revision == rhs.revision &&
            lhs.artifactHash == rhs.artifactHash &&
            lhs.licenseId == rhs.licenseId &&
            lhs.runtime == rhs.runtime &&
            lhs.tokenizer == rhs.tokenizer &&
            lhs.promptTemplate == rhs.promptTemplate &&
            lhs.pooling == rhs.pooling &&
            lhs.normalization == rhs.normalization &&
            lhs.dimension == rhs.dimension &&
            lhs.quantization == rhs.quantization
    }
}
