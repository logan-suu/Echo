// ==========================================
// 文件: SigLIP2TextEmbedder.swift
// 对应规格: 自然语言照片检索交接计划 §7.2（提议契约）+ §WP4 步骤 1c/1d、5c/5d
// 任务: WP4 5c/5d - SigLIP2 文本塔生产接线
// AC 覆盖: VisionTextEmbedder 协议 + 配对文本塔真实推理（768d，与图像塔共享对齐空间）
// 架构约束: AGENTS.md §4.2 Actor 隔离；SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor 下显式 nonisolated；
//           与图像塔共享同一 checkpoint 与对齐空间（ADR-015 D-1/D-4）；
//           工件缺失 fail-closed（绝不零向量回退）
// 生成时间: 2026-08-25
// ==========================================

@preconcurrency import CoreML
import Foundation

// MARK: - Vision Text Embedder Protocol（WP2 步骤 0b）

/// 视觉通道配对文本查询协议 —— 由与图像塔同 checkpoint 的 SigLIP2 文本塔实现。
///
/// 声明为 `nonisolated protocol`：requirements 不绑定 MainActor；async witness
/// 保持 actor-isolated，调用方一律 `try await`（R-008）。
/// alignmentSpaceID 必须与修正后的图像塔一致——跨空间查询在 adapter 层 fail-closed。
public nonisolated protocol VisionTextEmbedder: Sendable {
    /// 模型清单身份（model-manifest.json 文本塔条目 ID）
    nonisolated var modelManifestID: String { get }
    /// 对齐空间标识（必须与图像塔相同，ADR-015 D-1）
    nonisolated var alignmentSpaceID: String { get }
    /// 输出维度（SigLIP2-B/32-256 双塔均为 768d）
    nonisolated var dimension: Int { get }

    func embedVisionQuery(
        text: String,
        locale: String,
        traceID: String
    ) async throws -> [Float]
}

// MARK: - Paired Text Tower Runtime（WP4 5c/5d 真实实现）

/// 配对 SigLIP2 文本塔运行时 —— 为 vision_dense 通道生成 768d 文本查询向量。
///
/// 推理链路（与 WP2 基准 harness 同源，真机实证 norm≈1.0004、warm 73.23ms）：
/// pinned tokenizer（Gemma BPE）分词 → `int32[1,64]` → `text_embeddings` 768d → L2 归一化。
/// 工件缺失时 fail-closed（`modelNotLoaded`，绝不零向量回退）。
public actor SigLIP2TextEmbedder: VisionTextEmbedder {

    /// 模型清单身份
    public nonisolated let modelManifestID: String
    /// 对齐空间标识（与修正后图像塔共享）
    public nonisolated let alignmentSpaceID: String
    /// 输出维度（双塔原生 768d，禁止补零/截断/投影）
    public nonisolated let dimension: Int = 768

    private var tokenizer: SigLIP2Tokenizer?
    private var model: MLModel?

    /// 计算单元按目标环境自动选择：模拟器的 .all 执行路径对文本塔输出异常
    /// （实测全零），强制 CPU；真机保持全加速（ANE/GPU，warm 10-73ms 实证）。
    private nonisolated static let computeUnits: MLComputeUnits = {
        #if targetEnvironment(simulator)
        return .cpuOnly
        #else
        return .all
        #endif
    }()

    public init(
        modelManifestID: String = "siglip2-text-base-patch32-256-v1",
        alignmentSpaceID: String = "aligned-siglip2-v1"
    ) {
        self.modelManifestID = modelManifestID
        self.alignmentSpaceID = alignmentSpaceID
    }

    /// 生成视觉通道文本查询向量（768d，与图像向量同对齐空间）。
    public func embedVisionQuery(
        text: String,
        locale: String,
        traceID: String
    ) async throws -> [Float] {
        let model = try await ensureModel()
        let tokenizer = try ensureTokenizer()

        let ids = tokenizer.encode(text)
        let idsArr = try MLMultiArray(shape: [1, 64], dataType: .int32)
        for (index, value) in ids.enumerated() {
            idsArr[index] = NSNumber(value: value)
        }
        let features = try MLDictionaryFeatureProvider(dictionary: ["input_ids": idsArr])

        let output = try await model.prediction(from: features)
        guard let embeddings = output.featureValue(for: "text_embeddings")?.multiArrayValue else {
            throw EmbedderError.inferenceFailed(underlying: NSError(domain: "SigLIP2TextEmbedder", code: 1, userInfo: [NSLocalizedDescriptionKey: "text_embeddings feature missing"]))
        }

        var vector = [Float](repeating: 0, count: embeddings.count)
        for index in 0..<embeddings.count {
            vector[index] = embeddings[index].floatValue
        }
        // L2 归一化（与图像塔共享归一化契约，余弦相似度可直接比较）
        let squaredSum = vector.reduce(0) { $0 + $1 * $1 }
        let norm = sqrt(squaredSum)
        guard norm > 0 else {
            throw EmbedderError.inferenceFailed(underlying: NSError(domain: "SigLIP2TextEmbedder", code: 2, userInfo: [NSLocalizedDescriptionKey: "zero-norm text embedding"]))
        }
        return vector.map { $0 / Float(norm) }
    }

    // MARK: - Lazy Loading（fail-closed：工件缺失抛 modelNotLoaded）

    private func ensureModel() throws -> MLModel {
        if let model { return model }
        guard let url = Bundle.main.url(forResource: "SigLIP2TextBasePatch32", withExtension: "mlmodelc") else {
            throw EmbedderError.modelNotLoaded
        }
        let config = MLModelConfiguration()
        config.computeUnits = Self.computeUnits
        let loaded = try MLModel(contentsOf: url, configuration: config)
        model = loaded
        return loaded
    }

    private func ensureTokenizer() throws -> SigLIP2Tokenizer {
        if let tokenizer { return tokenizer }
        guard let url = Bundle.main.url(forResource: "siglip2-tokenizer", withExtension: "json") else {
            throw EmbedderError.modelNotLoaded
        }
        let loaded = try SigLIP2Tokenizer(tokenizerJSON: try Data(contentsOf: url))
        tokenizer = loaded
        return loaded
    }
}
