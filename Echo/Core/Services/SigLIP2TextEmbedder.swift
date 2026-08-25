// ==========================================
// 文件: SigLIP2TextEmbedder.swift
// 对应规格: 自然语言照片检索交接计划 §7.2（提议契约）
// 任务: WP2 - 精确双塔转换验证性试验（步骤 0b/0d）
// AC 覆盖: VisionTextEmbedder 协议声明 + 配对文本塔 actor 运行时骨架
// 架构约束: AGENTS.md §4.2 Actor 隔离；SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor 下显式 nonisolated；
//           与图像塔共享同一 checkpoint 与对齐空间（ADR-015 D-1/D-4）
// 生成时间: 2026-08-25
// ==========================================

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

// MARK: - Paired Text Tower Runtime（WP2 步骤 0d 骨架）

/// 配对 SigLIP2 文本塔运行时 —— 为 vision_dense 通道生成 768d 文本查询向量。
///
/// ## 实现状态（WP2 步骤 0d）
/// 协议一致性骨架已就绪；Core ML 推理接线待本包后续步骤产出文本塔
/// `.mlpackage` 后接入（精确 tokenizer + 固定 `int32[1,64]` 输入契约，
/// pinned revision `94dffa8cb1179de3e03f091dbc3917e5d5a9ae84`）。
/// 工件就绪前调用返回 `modelNotLoaded`（fail-closed，绝不零向量回退）。
public actor SigLIP2TextEmbedder: VisionTextEmbedder {

    /// 模型清单身份
    public nonisolated let modelManifestID: String
    /// 对齐空间标识（与修正后图像塔共享）
    public nonisolated let alignmentSpaceID: String
    /// 输出维度（双塔原生 768d，禁止补零/截断/投影）
    public nonisolated let dimension: Int = 768

    private let modelLoader: ModelLoaderActor

    public init(
        modelLoader: ModelLoaderActor,
        modelManifestID: String,
        alignmentSpaceID: String
    ) {
        self.modelLoader = modelLoader
        self.modelManifestID = modelManifestID
        self.alignmentSpaceID = alignmentSpaceID
    }

    /// 生成视觉通道文本查询向量（768d，与图像向量同对齐空间）。
    ///
    /// - Parameters:
    ///   - text: 自然语言查询（zh-Hans / en-US）
    ///   - locale: 查询语言标记
    ///   - traceID: 审计追溯 ID
    public func embedVisionQuery(
        text: String,
        locale: String,
        traceID: String
    ) async throws -> [Float] {
        // WP2 后续步骤接入：pinned tokenizer 分词 → 文本塔 Core ML 推理 →
        // L2 归一化（与图像塔共享归一化契约）。工件就绪前 fail-closed。
        throw EmbedderError.modelNotLoaded
    }
}
