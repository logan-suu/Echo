// ==========================================
// 文件: E5Embedder.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-3.1/R-3.8
//            docs/02-architecture/技术选型文档.md §3 (multilingual-e5-small)
// 任务: R-3.1 - E5 原生 384d 文本索引（独立 generation）
//       R-3.8 - E5 query/document 前缀注入
// AC 覆盖: 384d 原生输出（不补零）、query/passage 前缀、masked mean pooling、L2 归一化
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载)
// 法律状态: 工程暂定，MS MARCO 训练来源下游含义交专业法律审查
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-01
// ==========================================

import Foundation
import CoreML

// MARK: - Embedding Context

/// 嵌入上下文 — 区分 query 与 passage 场景（R-3.8 前缀注入）。
public enum EmbeddingContext: Sendable {
    /// 查询侧：注入 "query: " 前缀
    case query
    /// 摄入侧：注入 "passage: " 前缀
    case passage
}

// MARK: - E5 Embedder

/// multilingual-e5-small 文本嵌入器（R-3.1）。
///
/// 输出原生 384d 向量（不补零至 512d），写入独立的 `text_dense/e5-v1` generation。
/// 查询侧注入 `"query: "` 前缀，摄入侧注入 `"passage: "` 前缀（R-3.8）。
///
/// ## 推理流程
/// 1. 前缀注入（R-3.8）
/// 2. Tokenization（SentencePiece / Core ML TextTokenizer）
/// 3. Core ML 推理 → token embeddings
/// 4. Masked mean pooling
/// 5. L2 normalization
/// 6. 输出 384d 向量
///
/// ## 当前状态
/// 推理部分为 scaffold——需要 multilingual-e5-small Core ML 模型文件（Bundle 中）
/// 和 tokenizer 实现。模型文件就绪后替换 `performInference` 内部逻辑。
public actor E5Embedder: EmbedderProtocol {

    // MARK: - Constants

    /// E5 输出维度（原生 384d，不补零）
    public nonisolated static let dimension = 384

    /// 查询前缀（R-3.8）
    private nonisolated static let queryPrefix = "query: "
    /// 摄入前缀（R-3.8）
    private nonisolated static let passagePrefix = "passage: "

    // MARK: - Properties

    private let modelLoader: ModelLoaderActor
    private var cachedModel: MLModel?

    // MARK: - Initialization

    public init(modelLoader: ModelLoaderActor = .shared) {
        self.modelLoader = modelLoader
    }

    // MARK: - EmbedderProtocol

    /// 对文本生成 E5 嵌入向量（384d 原生输出）。
    ///
    /// - Parameter text: 待向量化的文本
    /// - Returns: 384d 浮点向量（L2 归一化）
    /// - Throws: `EmbedderError` 若模型未加载或推理失败
    public func embedText(_ text: String) async throws -> [Float] {
        try await embedText(text, context: .passage)
    }

    /// 对文本生成 E5 嵌入向量，带上下文前缀（R-3.8）。
    ///
    /// - Parameters:
    ///   - text: 待向量化的文本
    ///   - context: `.query`（查询侧）或 `.passage`（摄入侧）
    /// - Returns: 384d 浮点向量（L2 归一化）
    public func embedText(_ text: String, context: EmbeddingContext) async throws -> [Float] {
        // R-3.8: 前缀注入
        let prefixedText: String
        switch context {
        case .query:
            prefixedText = Self.queryPrefix + text
        case .passage:
            prefixedText = Self.passagePrefix + text
        }

        // 获取或缓存模型
        let model = try await resolveModel()

        // 推理（scaffold：模型文件就绪后替换内部逻辑）
        return try await performInference(text: prefixedText, model: model)
    }

    /// E5 不处理图像——视觉嵌入由 SigLIP2Embedder（R-3.2）负责。
    public func embedImage(assetId: String) async throws -> [Float] {
        throw EmbedderError.preprocessingFailed(
            reason: "E5Embedder does not support image embedding — use SigLIP2Embedder (R-3.2)"
        )
    }

    // MARK: - Model Resolution

    private func resolveModel() async throws -> MLModel {
        if let cached = cachedModel {
            return cached
        }
        // R-3.4: 从 ModelLoaderActor 获取 bundle URL（Sendable），自行加载 MLModel
        // （MLModel 非 Sendable，不能跨 Actor 返回）
        guard let bundleURL = await modelLoader.getModelBundleURL(.multilingualE5Small) else {
            throw EmbedderError.modelNotLoaded
        }
        let model = try await MLModel.load(contentsOf: bundleURL, configuration: MLModelConfiguration())
        cachedModel = model
        return model
    }

    // MARK: - Inference (Scaffold)

    /// 执行 E5 推理（scaffold）。
    ///
    /// 完整实现需要：
    /// 1. SentencePiece tokenizer（内嵌 tokenizer.json 或 Core ML TextTokenizer）
    /// 2. Core ML 推理 → token embeddings
    /// 3. Masked mean pooling（attention mask 加权平均）
    /// 4. L2 normalization
    ///
    /// 当前返回零向量占位——模型文件就绪后替换。
    private func performInference(text: String, model: MLModel) async throws -> [Float] {
        // TODO (R-3.1): 实现完整推理管线
        // 1. let tokens = try tokenize(text)  // SentencePiece
        // 2. let output = try model.prediction(from: tokens)
        // 3. let pooled = maskedMeanPooling(output.embeddings, attentionMask: tokens.attentionMask)
        // 4. return l2Normalize(pooled)
        return Array(repeating: 0.0, count: Self.dimension)
    }

    // MARK: - Math Utilities

    /// L2 归一化（单位向量）。
    nonisolated static func l2Normalize(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}
