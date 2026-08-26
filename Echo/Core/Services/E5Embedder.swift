// ==========================================
// 文件: E5Embedder.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-3.1/R-3.8
//            docs/02-architecture/技术选型文档.md §3 (multilingual-e5-small)
//            docs/decisions/ADR-009-offline-model-runtime.md → 决策 2/3/6
// 任务: 3F.3 - E5、SigLIP2、Whisper 与离线生成决策落地
// AC 覆盖: 384d 原生输出、query/passage 前缀、Unigram tokenizer、Core ML 推理、
//          损坏/缺失工件 L3 恢复（US-RES-004）、零网络（R-005）
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载), R-007 (禁止 unchecked Sendable)
// 法律状态: 工程暂定，MS MARCO 训练来源下游含义交专业法律审查
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-01 (3F.3: 2026-08-06 接入真实推理)
// ==========================================

import Foundation
@preconcurrency import CoreML

// MARK: - Embedding Context

/// 嵌入上下文 — 区分 query 与 passage 场景（R-3.8 前缀注入）。
public enum EmbeddingContext: Sendable {
    /// 查询侧：注入 "query: " 前缀
    case query
    /// 摄入侧：注入 "passage: " 前缀
    case passage
}

// MARK: - E5 Embedder

/// multilingual-e5-small 文本嵌入器（R-3.1 / 3F.3）。
///
/// 输出原生 384d 向量（不补零至 512d），写入独立的 `text_dense/e5-v1` generation。
/// 查询侧注入 `"query: "` 前缀，摄入侧注入 `"passage: "` 前缀（R-3.8）。
///
/// ## 推理流程
/// 1. 前缀注入（R-3.8）
/// 2. E5Tokenizer 标记化（Unigram / Metaspace，tokenizer.json 随 Bundle 分发）
/// 3. CoreMLInferenceAdapter 推理 → 384d 句子向量（tamikisg 导出已内置 masked-mean pooling + L2 归一化）
/// 4. 输出 384d 向量
///
/// ## 模型契约
/// - 输入：`input_ids` / `attention_mask`（Int32 [1, 256]）
/// - 输出：`embeddings`（Float16 [1, 384]，已归一化，norm≈1.0）
/// - 模型文件 `MultilingualE5Small.mlmodelc` 随 App Bundle 分发（R-005，零网络）
public actor E5Embedder: EmbedderProtocol {

    // MARK: - Constants

    /// E5 输出维度（原生 384d，不补零）
    public nonisolated static let dimension = 384

    /// Bundle 中 E5 模型资源名
    private nonisolated static let modelResourceName = "MultilingualE5Small"

    /// 模型输入特征名
    private nonisolated static let inputIDsName = "input_ids"
    private nonisolated static let attentionMaskName = "attention_mask"
    /// 模型输出特征名
    private nonisolated static let outputName = "embeddings"

    // MARK: - Properties

    private let modelLoader: ModelLoaderActor
    private var adapter: CoreMLInferenceAdapter?
    private var tokenizer: E5Tokenizer?

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
        try await embedText(text, context: EmbeddingContext.passage)
    }

    /// 对文本生成 E5 嵌入向量，带上下文前缀（R-3.8）。
    ///
    /// - Parameters:
    ///   - text: 待向量化的文本
    ///   - context: `.query`（查询侧）或 `.passage`（摄入侧）
    /// - Returns: 384d 浮点向量（L2 归一化）
    public func embedText(_ text: String, context: EmbeddingContext) async throws -> [Float] {
        // 懒加载 tokenizer + adapter
        let adapter = try await resolveAdapter()
        let tokenizer = try await resolveTokenizer()

        // 1. 标记化（前缀注入由 tokenizer 完成，R-3.8）
        let encoded = tokenizer.encode(text, context: context.mapToE5)

        // 2. 推理
        let output = try await adapter.predict(
            inputs: [
                Self.inputIDsName: .intArray(encoded.inputIDs),
                Self.attentionMaskName: .intArray(encoded.attentionMask),
            ],
            outputName: Self.outputName,
            expectedCount: Self.dimension
        )
        return output
    }

    /// WP1 步骤 1：协议级上下文入口 —— 映射到 R-3.8 内部前缀注入实现。
    public func embedText(_ text: String, context: TextEmbeddingContext) async throws -> [Float] {
        switch context {
        case .query:
            return try await embedText(text, context: EmbeddingContext.query)
        case .passage:
            return try await embedText(text, context: EmbeddingContext.passage)
        }
    }

    /// E5 不处理图像——视觉嵌入由 SigLIP2Embedder（R-3.2）负责。
    public func embedImage(assetId: String) async throws -> [Float] {
        throw EmbedderError.preprocessingFailed(
            reason: "E5Embedder does not support image embedding — use SigLIP2Embedder (R-3.2)"
        )
    }

    // MARK: - Lazy Resolution

    private func resolveAdapter() async throws -> CoreMLInferenceAdapter {
        if let adapter { return adapter }
        guard let bundleURL = await modelLoader.getModelBundleURL(.multilingualE5Small) else {
            throw EmbedderError.modelNotLoaded
        }
        let adapter = CoreMLInferenceAdapter()
        do {
            try await adapter.loadModel(at: bundleURL)
        } catch {
            await modelLoader.reportModelLoadFailed(
                .multilingualE5Small,
                error: .loadFailed(
                    modelName: ModelLoaderActor.ModelType.multilingualE5Small.modelName,
                    resourceName: ModelLoaderActor.ModelType.multilingualE5Small.resourceIdentifier,
                    underlying: error
                )
            )
            throw EmbedderError.modelNotLoaded
        }
        await modelLoader.reportModelLoaded(.multilingualE5Small)
        self.adapter = adapter
        return adapter
    }

    private func resolveTokenizer() async throws -> E5Tokenizer {
        if let tokenizer { return tokenizer }
        let tokenizer = try E5Tokenizer(bundle: .main)
        self.tokenizer = tokenizer
        return tokenizer
    }

    // MARK: - Math Utilities

    /// L2 归一化（单位向量）。
    nonisolated static func l2Normalize(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}

// MARK: - Context Mapping

extension EmbeddingContext {
    /// 映射到 E5Tokenizer 的上下文。
    nonisolated var mapToE5: E5Context {
        switch self {
        case .query: return .query
        case .passage: return .passage
        }
    }
}
