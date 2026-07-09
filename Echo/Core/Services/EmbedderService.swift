// ==========================================
// 文件: EmbedderService.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-004 (CLIP 向量生成)
//            docs/02-architecture/技术选型文档.md §5 (MobileCLIP-B LT 模型)
// 任务: 2.3 - IngestPipeline：图片摄入（AC-3: CLIP 向量生成）
// AC 覆盖: US-ING-004 AC-3 (图片生成 CLIP 向量，与文本向量空间对齐)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载),
//           R-007 (禁止 unchecked Sendable), R-008 (跨 Actor 调用必须 await)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// TODO (Phase 2, Future Task): 实现真实 MobileCLIP-B LT Core ML 推理（含图像预处理
//   Resize 224x224 + Normalize mean=[0.4815,0.4578,0.4082] std=[0.2686,0.2613,0.2758]）
//   当前 Stub 提供固定零向量，供 IngestPipeline 测试；真实推理在模型 I/O 接口确认后接入。
// 生成时间: 2026-07-09
// ==========================================

import Foundation

// MARK: - Embedder Protocol

/// 图片嵌入协议 — 抽象 CLIP 图像编码，支持依赖注入与测试 Mock。
///
/// AC-3 (US-ING-004): 图片通过 MobileCLIP-B LT 生成 768 维 CLIP 向量，与文本向量空间对齐。
///
/// 协议设计为 Sendable（非 Actor），以便测试 Mock 无需 Actor 隔离。
public protocol EmbedderProtocol: Sendable {
    /// 对 PHAsset 引用生成 CLIP 嵌入向量。
    ///
    /// - Parameter assetId: PHAsset.localIdentifier
    /// - Returns: 768 维浮点向量
    /// - Throws: `EmbedderError` 若图像加载或推理失败
    func embedImage(assetId: String) async throws -> [Float]
}

// MARK: - Embedder Error

/// 嵌入服务统一错误类型
public enum EmbedderError: Error, LocalizedError, Sendable {
    /// 无法根据 PHAsset.localIdentifier 获取图像资源
    case assetUnavailable(assetId: String)
    /// 模型尚未加载（L3 阻断：ModelLoaderActor 未加载 MobileCLIP-B LT）
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
            return "MobileCLIP-B LT model not loaded — 请在「设置」中重试模型加载"
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
/// 真实 MobileCLIP-B LT 推理由未来的 `MobileCLIPEmbedder` Actor 实现。
public actor StubEmbedder: EmbedderProtocol {

    /// 每次 `embedImage()` 调用的返回值（测试可控）
    private var nextEmbedding: [Float]
    /// 是否在下一次调用时抛出错误（测试可控）
    private var shouldThrowNext: EmbedderError?

    /// 创建 Stub 嵌入器。
    /// - Parameter defaultEmbedding: 未显式设置 next 时使用的默认向量（默认 768 维全 1 向量）
    public init(defaultEmbedding: [Float] = Array(repeating: 1.0, count: 768)) {
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
    /// - Returns: 预设的 768 维浮点向量
    /// - Throws: 如已调用 `setNextError()` 则抛出对应错误
    public func embedImage(assetId: String) async throws -> [Float] {
        if let error = shouldThrowNext {
            shouldThrowNext = nil
            throw error
        }
        return nextEmbedding
    }
}
