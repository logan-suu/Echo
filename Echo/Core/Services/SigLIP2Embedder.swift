// ==========================================
// 文件: SigLIP2Embedder.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-3.2
//            调研报告 §6 (SigLIP2-B/32, Apache-2.0)
// 任务: R-3.2 - SigLIP2-B/32 图像编码器（替代 MobileCLIP）; 3F.3a - Core ML 推理接入
// AC 覆盖: 图像预处理（resize 256→crop 224）、Core ML 推理、vision_dense generation,
//          US-ING-004 AC-3 (视觉 embedding), US-SRC-011 (参考向量验证)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-01 (3F.3a: 2026-08-07 接入真实 Core ML 推理)
// ==========================================

import Foundation
@preconcurrency import CoreML
@preconcurrency import UIKit
import Photos

// MARK: - SigLIP2 Embedder

/// SigLIP2-B/32-256 图像编码器（R-3.2 / 3F.3a）— 替代 MobileCLIP（商业许可阻断）。
///
/// Apache-2.0 许可工件，约 180MB（.mlmodelc）。通过 `Scripts/convert_siglip2.py` 完成
/// PyTorch→coremltools→Core ML 转换，`.mlmodelc` 随 Bundle 分发（R-005）。
/// 输出写入独立的 `vision_dense/siglip2-v1` generation（ADR-009 决策 1 空间分离）。
///
/// ## 推理流程
/// 1. PHAsset → UIImage（PhotoKit）
/// 2. `preprocess()`: 方向矫正 → aspect-fit resize（最短边 256）→ center-crop 256 → normalize
/// 3. Core ML 推理 → 768d 视觉向量
/// 4. L2 归一化 → 返回 768d Float 数组
///
/// ## 模型契约
/// - 输入：`pixel_values`（Float32 [1, 3, 256, 256], NCHW, 归一化 [-1, 1]）
/// - 输出：`embeddings`（Float16 [1, 768]，probe-token attention pooling + L2 归一化）
/// - 模型文件 `SigLIP2BasePatch32.mlmodelc` 随 App Bundle 分发（R-005）
public actor SigLIP2Embedder: EmbedderProtocol {

    // MARK: - Constants

    /// SigLIP2-B/32 输出维度
    public nonisolated static let dimension = 768

    /// 预处理：输入尺寸
    private nonisolated static let inputSize = CGSize(width: 256, height: 256)
    /// 预处理：center crop 尺寸（siglip2-base-patch32-256 输入即 256×256）
    private nonisolated static let cropSize = CGSize(width: 256, height: 256)
    /// 预处理：归一化均值
    private nonisolated static let normalizeMean: [Float] = [0.5, 0.5, 0.5]
    /// 预处理：归一化标准差
    private nonisolated static let normalizeStd: [Float] = [0.5, 0.5, 0.5]

    /// Bundle 中 Core ML 模型资源名（siglip2-base-patch32-256，输入 256×256，输出 768d）
    private nonisolated static let modelResourceName = "SigLIP2BasePatch32"

    // MARK: - Properties

    private let modelLoader: ModelLoaderActor
    private var cachedModel: MLModel?

    // MARK: - Initialization

    public init(modelLoader: ModelLoaderActor = .shared) {
        self.modelLoader = modelLoader
    }

    // MARK: - EmbedderProtocol

    /// 对 PHAsset 图像生成 SigLIP2 嵌入向量（768d）。
    ///
    /// 流程：PHAsset → UIImage → preprocess → Core ML inference → L2 normalize。
    ///
    /// - Parameter assetId: PHAsset.localIdentifier
    /// - Returns: 768d L2 归一化浮点向量
    /// - Throws: `EmbedderError` 若模型未加载、图像不可用或推理失败
    public func embedImage(assetId: String) async throws -> [Float] {
        let image = try await loadImage(from: assetId)
        return try await embedImage(from: image)
    }

    /// SigLIP2 不处理文本——文本嵌入由 E5Embedder（R-3.1）负责。
    public func embedText(_ text: String) async throws -> [Float] {
        throw EmbedderError.preprocessingFailed(
            reason: "SigLIP2Embedder does not support text embedding — use E5Embedder (R-3.1)"
        )
    }

    /// 对 JPEG/PNG 图像数据生成嵌入向量（视频关键帧等非 PHAsset 引用场景）。
    public func embedImageData(_ data: Data) async throws -> [Float] {
        guard let image = UIImage(data: data) else {
            throw EmbedderError.preprocessingFailed(reason: "Invalid image data for SigLIP2")
        }
        return try await embedImage(from: image)
    }

    // MARK: - Image Embedding (Internal)

    /// 直接从 UIImage 生成嵌入向量（测试与流水线入口）。
    public func embedImage(from image: UIImage) async throws -> [Float] {
        let preprocessed = try preprocess(image)
        return try await runInference(preprocessedArray: preprocessed)
    }

    // MARK: - PHAsset Loading

    /// 从 PHAsset 加载 UIImage。
    private nonisolated func loadImage(from assetId: String) async throws -> UIImage {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw EmbedderError.assetUnavailable(assetId: assetId)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool, isDegraded {
                    return
                }
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(
                        throwing: EmbedderError.assetUnavailable(assetId: assetId)
                    )
                    return
                }
                guard let image = image else {
                    continuation.resume(
                        throwing: EmbedderError.assetUnavailable(assetId: assetId)
                    )
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Core ML Inference

    /// 解析 MLModel（惰性加载，首次使用后缓存）。
    ///
    /// `.mlmodelc` 是已编译模型，直接 `MLModel.load`；`MLModel.compileModel`
    /// 仅用于未编译的 `.mlpackage`（E5 路径）。对 `.mlmodelc` 调用
    /// `compileModel` 会导致 Core ML 尝试重新编译而报
    /// "A valid manifest does not exist" 错误（3F.3a 实测）。
    private func resolveModel() async throws -> MLModel {
        if let cached = cachedModel {
            return cached
        }

        guard let modelURL = await modelLoader.getModelBundleURL(.siglip2Vision) else {
            throw EmbedderError.modelNotLoaded
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let model: MLModel
        do {
            if modelURL.pathExtension == "mlpackage" {
                let compiledURL = try await MLModel.compileModel(at: modelURL)
                model = try await MLModel.load(contentsOf: compiledURL, configuration: config)
            } else {
                model = try await MLModel.load(contentsOf: modelURL, configuration: config)
            }
        } catch {
            await modelLoader.reportModelLoadFailed(
                .siglip2Vision,
                error: .loadFailed(
                    modelName: "SigLIP2",
                    resourceName: modelURL.lastPathComponent,
                    underlying: error
                )
            )
            throw EmbedderError.modelNotLoaded
        }

        await modelLoader.reportModelLoaded(.siglip2Vision)
        self.cachedModel = model
        return model
    }

    /// 执行 Core ML 推理。
    private func runInference(preprocessedArray preprocessed: [Float]) async throws -> [Float] {
        let model = try await resolveModel()

        // 显式命名输入/输出（convert_siglip2.py 固定契约），避免字典无序 .first
        let inputName = "pixel_values"
        let outputName = "embeddings"
        guard model.modelDescription.inputDescriptionsByName[inputName] != nil else {
            throw EmbedderError.inferenceFailed(
                underlying: NSError(domain: "SigLIP2Embedder", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Input '\(inputName)' not found"])
            )
        }

        let shaped = MLShapedArray<Float>(
            scalars: preprocessed,
            shape: [1, 3, 256, 256]
        )
        let provider = try MLDictionaryFeatureProvider(
            dictionary: [inputName: MLMultiArray(shaped)]
        )

        let prediction = try await model.prediction(from: provider)

        guard let output = prediction.featureValue(for: outputName)?.multiArrayValue else {
            throw EmbedderError.inferenceFailed(
                underlying: NSError(domain: "SigLIP2Embedder", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "Output '\(outputName)' not found"])
            )
        }

        return try extractEmbedding(from: output)
    }

    /// 从 MLMultiArray 提取嵌入向量。
    ///
    /// SigLIP2-B/32-256 Core ML 输出形状为 `[1, 768]`（probe token 池化 + L2 归一化）。
    private func extractEmbedding(from output: MLMultiArray) throws -> [Float] {
        let shape = output.shape.map { $0.intValue }

        guard shape == [1, 768] else {
            throw EmbedderError.dimensionMismatch(
                expected: 768,
                got: shape.last ?? 0
            )
        }

        var embedding = [Float](repeating: 0, count: 768)
        for i in 0..<768 {
            embedding[i] = Float(truncating: output[i])
        }
        return l2Normalize(embedding)
    }

    // MARK: - L2 Normalization

    /// L2 归一化：将向量缩放至单位长度。
    private nonisolated func l2Normalize(_ vector: [Float]) -> [Float] {
        let sumSq = vector.reduce(0) { $0 + $1 * $1 }
        let norm = sqrt(sumSq)
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    // MARK: - Image Preprocessing

    /// 图像预处理：方向矫正 → aspect-fit resize 256 → center-crop 256 → normalize。
    ///
    /// SigLIP2-B/32-256 要求 256×256 输入，归一化 mean=[0.5,0.5,0.5] std=[0.5,0.5,0.5]。
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
        let resized = try aspectFitCGImage(cgImage, maxDimension: 256)

        // 3. Center crop 到 224×224
        let cropped = try centerCropCGImage(resized, to: Self.cropSize)

        // 4. 归一化
        return try normalizeCGImage(cropped)
    }

    // MARK: - Core Graphics Utilities

    /// 等比缩放（aspect-fit），保持宽高比，**最短边**缩放到 maxDimension。
    ///
    /// 用 `max(scaleW, scaleH)` 保证缩放后最短边恰好为 maxDimension、
    /// 长边 ≥ maxDimension，使后续 center-crop(maxDimension) 永不越界。
    /// （若用 `min` 则短边 < maxDimension，crop 越界返回交集，
    /// 输出非 3×256×256，`MLShapedArray` scalars 数量不匹配 → 崩溃。C1 修复。）
    private nonisolated func aspectFitCGImage(_ image: CGImage, maxDimension: CGFloat) throws -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = max(maxDimension / width, maxDimension / height)
        let targetSize = CGSize(width: width * scale, height: height * scale)
        guard let context = CGContext(
            data: nil,
            width: Int(targetSize.width.rounded()),
            height: Int(targetSize.height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw EmbedderError.preprocessingFailed(reason: "Failed to create resize context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))
        guard let resized = context.makeImage() else {
            throw EmbedderError.preprocessingFailed(reason: "Failed to make resized image")
        }
        return resized
    }

    private nonisolated func centerCropCGImage(_ image: CGImage, to size: CGSize) throws -> CGImage {
        // 整数坐标 + clamp，保证输出恒为 size（浮点 cropRect 取整会导致 256×257 等错位尺寸，C1）
        let imageW = image.width
        let imageH = image.height
        let cropW = Int(size.width)
        let cropH = Int(size.height)
        let x = min(max(0, (imageW - cropW) / 2), max(0, imageW - cropW))
        let y = min(max(0, (imageH - cropH) / 2), max(0, imageH - cropH))
        let cropRect = CGRect(x: x, y: y, width: min(cropW, imageW - x), height: min(cropH, imageH - y))
        guard let cropped = image.cropping(to: cropRect) else {
            throw EmbedderError.preprocessingFailed(reason: "Failed to center-crop image")
        }
        return cropped
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
