// ==========================================
// 文件: OCREngine.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-3.5
//            docs/02-architecture/技术选型文档.md (Apple Vision OCR)
// 任务: R-3.5 - Apple Vision OCR 管道
// AC 覆盖: VNRecognizeTextRequest accurate 模式、简体+繁体中文识别、
//          OCR 文本经 E5 嵌入写入 ocr_text generation
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-01
// ==========================================

import Foundation
@preconcurrency import Vision
@preconcurrency import UIKit

// MARK: - OCR Engine Protocol

/// OCR 引擎协议 — 抽象文本识别，支持依赖注入与测试 Mock。
public protocol OCREngineProtocol: Sendable {
    /// 对图像执行 OCR 文本识别。
    ///
    /// - Parameter image: 待识别的 UIImage
    /// - Returns: 识别出的文本（多行拼接）
    /// - Throws: `OCRError` 若识别失败
    func recognizeText(in image: UIImage) async throws -> String
}

// MARK: - OCR Error

/// OCR 引擎统一错误类型
public enum OCRError: Error, LocalizedError, Sendable {
    /// 图像无法处理
    case imageUnavailable
    /// Vision 框架识别失败
    case recognitionFailed(underlying: Error)
    /// 未识别到任何文本
    case noTextRecognized

    public var errorDescription: String? {
        switch self {
        case .imageUnavailable:
            return "Image unavailable for OCR processing"
        case .recognitionFailed(let error):
            return "Text recognition failed: \(error.localizedDescription)"
        case .noTextRecognized:
            return "No text recognized in image"
        }
    }
}

// MARK: - Vision OCR Engine

/// Apple Vision OCR 引擎（R-3.5）— 使用系统 Vision 框架，零新增模型包。
///
/// 配置：
/// - accurate 模式（最高精度）
/// - 显式设置简体中文 + 繁体中文识别语言
/// - 自动回退英文识别
///
/// ## 数据流
/// PHAsset → UIImage → VNRecognizeTextRequest → recognized strings → 拼接文本
/// → E5 嵌入 → 写入 `ocr_text/vision-revX-v1` generation
public actor VisionOCREngine: OCREngineProtocol {

    // MARK: - Constants

    /// 识别语言：简体中文 + 繁体中文 + 英文（回退）
    private nonisolated static let recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

    // MARK: - OCREngineProtocol

    /// 对图像执行 OCR 文本识别。
    public func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw OCRError.imageUnavailable
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = Self.recognitionLanguages
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            throw OCRError.recognitionFailed(underlying: error)
        }

        guard let observations = request.results, !observations.isEmpty else {
            throw OCRError.noTextRecognized
        }

        // 按置信度排序，提取 top-1 candidates
        let texts = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }

        guard !texts.isEmpty else {
            throw OCRError.noTextRecognized
        }

        return texts.joined(separator: "\n")
    }

    /// 对 PHAsset 引用的图像执行 OCR（便捷方法）。
    ///
    /// - Parameter assetId: PHAsset.localIdentifier
    /// - Returns: 识别出的文本
    public func recognizeText(assetId: String) async throws -> String {
        // TODO (R-3.5): 通过 PHAssetManager 加载 PHAsset → UIImage
        // 当前需要调用方提供 UIImage；完整实现需 Photos 框架集成
        throw OCRError.imageUnavailable
    }
}
