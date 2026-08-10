// ==========================================
// 文件: EmbedderService.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-004 (CLIP 向量生成)
//            docs/02-architecture/技术选型文档.md §5 (SigLIP2-B/32 视觉模型)
// 任务: 2.3 - IngestPipeline：图片摄入（AC-3: CLIP 向量生成）；3F.3 更新模型引用
// AC 覆盖: US-ING-004 AC-3 (图片生成 CLIP 向量，与文本向量空间对齐)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载),
//           R-007 (禁止 unchecked Sendable), R-008 (跨 Actor 调用必须 await)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 3F.3 (2026-08-06): MobileCLIP-B（商业许可阻断）退役，视觉嵌入由 SigLIP2Embedder (R-3.2) 提供。
//   当前 Stub 保留供 IngestPipeline 测试；真实视觉推理接入 SigLIP2 Core ML 转换（model-provenance-register §3）。
// 生成时间: 2026-07-09
// ==========================================

import Foundation

// MARK: - Embedder Protocol

/// 图片嵌入协议 — 抽象 CLIP 图像编码，支持依赖注入与测试 Mock。
///
/// AC-3 (US-ING-004): 图片通过 SigLIP2-B/32 生成 768d 视觉向量（独立 vision generation，ADR-006）。
///
/// 协议设计为 Sendable（非 Actor），以便测试 Mock 无需 Actor 隔离。
public protocol EmbedderProtocol: Sendable {
    /// 对 PHAsset 引用生成 CLIP 嵌入向量。
    ///
    /// - Parameter assetId: PHAsset.localIdentifier
    /// - Returns: 浮点向量（SigLIP2-B/32 768d；Stub 默认 512d 占位，仅供测试）
    /// - Throws: `EmbedderError` 若图像加载或推理失败
    func embedImage(assetId: String) async throws -> [Float]

    /// 对文本生成 CLIP 嵌入向量（用于音频转写文本、备忘录文字等）。
    ///
    /// - Parameter text: 待向量化的文本
    /// - Returns: 浮点向量（multilingual-e5-small 384d；Stub 默认 512d — 待对齐）
    /// - Throws: `EmbedderError` 若推理失败
    func embedText(_ text: String) async throws -> [Float]

    /// 对图像数据（JPEG/PNG）生成嵌入向量 — 视频关键帧等非 PHAsset 引用场景。
    ///
    /// 默认实现抛出 `preprocessingFailed`；支持图像数据的嵌入器（SigLIP2）覆盖此方法。
    func embedImageData(_ data: Data) async throws -> [Float]
}

extension EmbedderProtocol {
    /// 默认实现：无图像数据嵌入能力的嵌入器返回预处理失败（L3 阻断）。
    public func embedImageData(_ data: Data) async throws -> [Float] {
        throw EmbedderError.preprocessingFailed(reason: "\(type(of: self)) does not support image data embedding")
    }
}

// MARK: - Embedder Error

/// 嵌入服务统一错误类型
public enum EmbedderError: Error, LocalizedError, Sendable {
    /// 无法根据 PHAsset.localIdentifier 获取图像资源
    case assetUnavailable(assetId: String)
    /// 模型尚未加载（L3 阻断：ModelLoaderActor 未加载视觉模型）
    case modelNotLoaded
    /// 模型推理失败
    case inferenceFailed(underlying: Error)
    /// 图像预处理失败
    case preprocessingFailed(reason: String)
    /// 输出向量维度不匹配
    case dimensionMismatch(expected: Int, got: Int)

    public var errorDescription: String? {
        switch self {
        case .assetUnavailable(let assetId):
            return "PHAsset unavailable: \(assetId)"
        case .modelNotLoaded:
            return "Vision model not loaded — 请在「设置」中重试模型加载"
        case .inferenceFailed(let error):
            return "CLIP inference failed: \(error.localizedDescription)"
        case .preprocessingFailed(let reason):
            return "Image preprocessing failed: \(reason)"
        case .dimensionMismatch(let expected, let got):
            return "Output dimension mismatch: expected \(expected), got \(got)"
        }
    }
}

// MARK: - Stub Embedder

/// Stub 嵌入服务 — 返回固定零向量或指定向量，用于 Pipeline 测试。
///
/// 该实现不依赖 Core ML 或 PHPhotoLibrary，纯逻辑验证 IngestPipeline 流程正确性。
/// 真实视觉推理由 `SigLIP2Embedder`（R-3.2，Core ML 转换后）实现。
public actor StubEmbedder: EmbedderProtocol {

    /// 每次 `embedImage()` 调用的返回值（测试可控）
    private var nextEmbedding: [Float]
    /// 是否在下一次调用时抛出错误（测试可控）
    private var shouldThrowNext: EmbedderError?

    /// 创建 Stub 嵌入器。
    /// - Parameter defaultEmbedding: 未显式设置 next 时使用的默认向量（默认 512d 占位向量，仅供 Pipeline 测试）
    public init(defaultEmbedding: [Float] = Array(repeating: 1.0, count: 512)) {
        self.nextEmbedding = defaultEmbedding
    }

    /// 设置下一次 `embedImage()` 返回的向量（测试用）。
    public func setNextEmbedding(_ vector: [Float]) {
        nextEmbedding = vector
    }

    /// 设置下一次 `embedImage()` 抛出指定错误（测试用）。
    public func setNextError(_ error: EmbedderError?) {
        shouldThrowNext = error
    }

    /// 返回预设的固定向量，或抛出预设错误。
    /// - Parameter assetId: PHAsset 标识符（Stub 忽略此参数）
    /// - Returns: 预设的浮点向量（默认 512d 占位）
    /// - Throws: 如已调用 `setNextError()` 则抛出对应错误
    public func embedImage(assetId: String) async throws -> [Float] {
        if let error = shouldThrowNext {
            shouldThrowNext = nil
            throw error
        }
        return nextEmbedding
    }

    /// 返回预设的固定向量，或抛出预设错误（与 embedImage 共享相同的 stub 向量和错误状态）。
    /// - Parameter text: 待向量化的文本（Stub 忽略此参数）
    /// - Returns: 预设的浮点向量（默认 512d 占位）；生产环境中 multilingual-e5-small 应返回 384d 并经零填充对齐
    /// - Throws: 如已调用 `setNextError()` 则抛出对应错误
    public func embedText(_ text: String) async throws -> [Float] {
        if let error = shouldThrowNext {
            shouldThrowNext = nil
            throw error
        }
        return nextEmbedding
    }

    /// 返回预设的固定向量（与 embedImage/embedText 共享相同 stub 向量）。
    public func embedImageData(_ data: Data) async throws -> [Float] {
        if let error = shouldThrowNext {
            shouldThrowNext = nil
            throw error
        }
        return nextEmbedding
    }
}
