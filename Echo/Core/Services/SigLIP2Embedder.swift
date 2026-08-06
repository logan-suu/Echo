// ==========================================
// 文件: SigLIP2Embedder.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-3.2
//            调研报告 §6 (SigLIP2-B/32, Apache-2.0)
// 任务: R-3.2 - SigLIP2-B/32 图像编码器（替代 MobileCLIP）
// AC 覆盖: 图像预处理（resize 256→crop 224）、Core ML 推理、vision_dense generation
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载)
// 状态: scaffold — 需 Core ML 转换（PyTorch → coremltools）+ 模型文件
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-01
// ==========================================

import Foundation
@preconcurrency import CoreML
@preconcurrency import UIKit

// MARK: - SigLIP2 Embedder

/// SigLIP2-B/32 图像编码器（R-3.2）— 替代 MobileCLIP（商业许可阻断）。
///
/// Apache-2.0 许可工件，约 1.5GB。需自转换 Core ML（PyTorch → coremltools）。
/// 输出写入独立的 `vision_dense/siglip2-v1` generation。
///
/// ## 当前状态
/// Scaffold — 需要：
/// 1. Core ML 转换：PyTorch checkpoint → coremltools → `.mlmodelc`
/// 2. 参考向量验证（与 HuggingFace 输出余弦相似度 > 0.995）
/// 3. 模型文件放入 Bundle
public actor SigLIP2Embedder: EmbedderProtocol {

    // MARK: - Constants

    /// SigLIP2-B/32 输出维度
    public nonisolated static let dimension = 768

    /// 预处理：输入尺寸
    private nonisolated static let inputSize = CGSize(width: 256, height: 256)
    /// 预处理：center crop 尺寸
    private nonisolated static let cropSize = CGSize(width: 224, height: 224)
    /// 预处理：归一化均值
    private nonisolated static let normalizeMean: [Float] = [0.5, 0.5, 0.5]
    /// 预处理：归一化标准差
    private nonisolated static let normalizeStd: [Float] = [0.5, 0.5, 0.5]

    // MARK: - Properties

    private let modelLoader: ModelLoaderActor
    private var cachedModel: MLModel?

    // MARK: - Initialization

    public init(modelLoader: ModelLoaderActor = .shared) {
        self.modelLoader = modelLoader
    }

    // MARK: - EmbedderProtocol

    /// 对图像生成 SigLIP2 嵌入向量。
    ///
    /// - Parameter assetId: PHAsset.localIdentifier
    /// - Returns: 768d 浮点向量
    public func embedImage(assetId: String) async throws -> [Float] {
        // TODO (R-3.2): PHAsset → UIImage → preprocess → Core ML inference
        // 1. let image = try await loadPHAsset(assetId)
        // 2. let preprocessed = try preprocess(image)
        // 3. let model = try await resolveModel()
        // 4. return try await performInference(preprocessed, model: model)
        throw EmbedderError.modelNotLoaded
    }

    /// SigLIP2 不处理文本——文本嵌入由 E5Embedder（R-3.1）负责。
    public func embedText(_ text: String) async throws -> [Float] {
        throw EmbedderError.preprocessingFailed(
            reason: "SigLIP2Embedder does not support text embedding — use E5Embedder (R-3.1)"
        )
    }

    // MARK: - Image Preprocessing

    /// 图像预处理：方向矫正 → resize → center crop → normalize。
    ///
    /// SigLIP2 要求 224×224 输入，归一化 mean=[0.5,0.5,0.5] std=[0.5,0.5,0.5]。
    ///
    /// DEF-34-004 修复：
    /// 1. 尊重 `image.imageOrientation`（EXIF 方向），避免旋转后语义错误
    /// 2. 等比缩放（aspect-fit）后 center crop，避免强制拉伸破坏宽高比
    /// 3. 显式设置 bitmap 字节序为 big-endian RGB，避免通道错乱
    nonisolated func preprocess(_ image: UIImage) throws -> [Float] {
        // 1. 应用图像方向，产出标准方向位图
        let oriented = image.applyingTransformToOrientation()
        guard let cgImage = oriented.cgImage else {
            throw EmbedderError.preprocessingFailed(reason: "No CGImage available")
        }

        // 2. 等比缩放（aspect-fit 到 256×256），保持宽高比
        let resized = aspectFitCGImage(cgImage, maxDimension: 256)

        // 3. Center crop 到 224×224
        let cropped = centerCropCGImage(resized, to: Self.cropSize)

        // 4. 归一化
        return try normalizeCGImage(cropped)
    }

    // MARK: - Core Graphics Utilities

    /// 等比缩放（aspect-fit），保持宽高比，长边缩放到 maxDimension。
    private nonisolated func aspectFitCGImage(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(maxDimension / width, maxDimension / height)
        let targetSize = CGSize(width: width * scale, height: height * scale)
        let context = CGContext(
            data: nil,
            width: Int(targetSize.width.rounded()),
            height: Int(targetSize.height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))
        return context.makeImage()!
    }

    private nonisolated func centerCropCGImage(_ image: CGImage, to size: CGSize) -> CGImage {
        let cropRect = CGRect(
            x: (CGFloat(image.width) - size.width) / 2,
            y: (CGFloat(image.height) - size.height) / 2,
            width: size.width,
            height: size.height
        )
        return image.cropping(to: cropRect)!
    }

    private nonisolated func normalizeCGImage(_ image: CGImage) throws -> [Float] {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        // DEF-34-004: 显式 big-endian 无预乘字节序，保证 RGB 通道与模型输入一致
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw EmbedderError.preprocessingFailed(reason: "Failed to create CGContext")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Convert to CHW float array with normalization
        var result = [Float](repeating: 0, count: 3 * width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * bytesPerPixel
                for c in 0..<3 {
                    let pixelValue = Float(pixelData[offset + c]) / 255.0
                    let normalized = (pixelValue - Self.normalizeMean[c]) / Self.normalizeStd[c]
                    result[c * width * height + y * width + x] = normalized
                }
            }
        }
        return result
    }
}

// MARK: - UIImage Orientation Helper

extension UIImage {
    /// 应用 EXIF 方向变换，返回标准方向（.up）的 UIImage。
    ///
    /// 通过 CIImage 的 oriented(for:) 重绘，正确处理旋转与镜像，
    /// 供模型预处理消费（DEF-34-004 修复：不忽略 imageOrientation）。
    nonisolated func applyingTransformToOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let ciImage = CIImage(image: self) ?? CIImage(cgImage: cgImage!)
        let oriented = ciImage.oriented(forExifOrientation: Int32(Self.cgOrientation(imageOrientation).rawValue))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(oriented, from: oriented.extent) else {
            return self
        }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    /// 映射 UIImage.Orientation → CGImagePropertyOrientation。
    nonisolated private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
