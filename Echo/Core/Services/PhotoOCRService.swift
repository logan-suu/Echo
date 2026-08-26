// ==========================================
// 文件: PhotoOCRService.swift
// 对应规格: 交接计划 §WP5 提议接口 / 产出的接口（逐字实现）
// 任务: WP5 - OCR 辅助通道
// 架构约束: OCRDocument 为 nonisolated Sendable 值契约；
//           PhotoOCRService protocol 不继承 MainActor，
//           生产 OCR actor 的 async witness 保持 actor-isolated，调用方必须 try await。
// 目标边界: OCR 是照片内可见文本检索的独立辅助能力，
//           不得描述为场景或物体理解；仅支持 zh-Hans/en-US；禁用云 OCR。
// 生成时间: 2026-08-25
// ==========================================

import Foundation

/// 照片内可见文本的规范化识别结果（交接计划 §WP5 提议接口原文实现）。
public nonisolated struct OCRDocument: Sendable, Equatable {
    public nonisolated let normalizedText: String
    public nonisolated let locale: String
    public nonisolated let observationCount: Int
    public nonisolated let contentHash: String

    public nonisolated init(
        normalizedText: String,
        locale: String,
        observationCount: Int,
        contentHash: String
    ) {
        self.normalizedText = normalizedText
        self.locale = locale
        self.observationCount = observationCount
        self.contentHash = contentHash
    }
}

/// OCR 服务契约——生产实现为 actor，async witness 保持 actor-isolated。
public nonisolated protocol PhotoOCRService: Sendable {
    func recognizeText(
        imageData: Data,
        preferredLanguages: [String],
        traceID: String
    ) async throws -> OCRDocument?
}

import CryptoKit
import Vision

/// Apple Vision 生产 OCR 实现（交接计划 §WP5 步骤组 2）。
///
/// - 识别语言强制收敛到批准白名单 zh-Hans/en-US（范围排除：不扩展两种语言之外）
/// - usesLanguageCorrection=false 保证相同输入产生相同输出
/// - 低置信度 observation 过滤；过滤后无有效内容返回 nil（无文本照片不得虚构 OCR 内容）
/// - 明文只进 OCRDocument，绝不进入审计日志（审计侧仅 contentHash/traceID）
public actor VisionPhotoOCRService: PhotoOCRService {
    /// 批准语言白名单（与 R-004 语言策略同源）
    nonisolated private static let approvedLanguages: Set<String> = ["zh-Hans", "en-US"]

    private let minimumConfidence: Float

    public init(minimumConfidence: Float = 0.5) {
        self.minimumConfidence = minimumConfidence
    }

    public func recognizeText(
        imageData: Data,
        preferredLanguages: [String],
        traceID: String
    ) async throws -> OCRDocument? {
        guard let cgImage = CGImageSourceCreateWithData(imageData as CFData, nil).flatMap({
            CGImageSourceCreateImageAtIndex($0, 0, nil)
        }) else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = Self.approvedRecognitionLanguages(preferred: preferredLanguages)

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return nil }
        let candidates: [(text: String, box: CGRect, confidence: Float)] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (candidate.string, observation.boundingBox, candidate.confidence)
        }
        let accepted = Self.thresholded(
            candidates: candidates,
            minimumConfidence: minimumConfidence
        )
        guard !accepted.isEmpty else { return nil }

        let normalized = Self.normalizedText(
            from: accepted.map(\.text),
            boxes: accepted.map(\.box)
        )
        guard !normalized.isEmpty else { return nil }

        let digest = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return OCRDocument(
            normalizedText: normalized,
            locale: Self.dominantLocale(of: normalized),
            observationCount: accepted.count,
            contentHash: "sha256:\(digest)"
        )
    }

    /// 置信度过滤纯函数——保留 ≥ 阈值的候选（确定性，不依赖 Vision 黑盒置信度）。
    nonisolated static func thresholded(
        candidates: [(text: String, box: CGRect, confidence: Float)],
        minimumConfidence: Float
    ) -> [(text: String, box: CGRect)] {
        candidates.filter { $0.confidence >= minimumConfidence }
            .map { (text: $0.text, box: $0.box) }
    }

    /// 语言白名单收敛——preferred 与批准集取交集（zh-CN 归一化为 zh-Hans）；
    /// 交集为空时回落完整批准集（仍不出白名单）。
    nonisolated static func approvedRecognitionLanguages(preferred: [String]) -> [String] {
        let normalized = preferred.map { $0 == "zh-CN" ? "zh-Hans" : $0 }
        let filtered = normalized.filter { Self.approvedLanguages.contains($0) }
        return filtered.isEmpty ? Self.approvedLanguages.sorted() : filtered
    }

    /// 确定性 normalization：版面排序（top→bottom，同行左→右；Vision 归一化坐标 y 向上，
    /// 行聚类阈值 0.02）后逐行折叠空白、行间换行连接。
    nonisolated static func normalizedText(from lines: [String], boxes: [CGRect]) -> String {
        guard lines.count == boxes.count else { return "" }
        let paired = zip(lines, boxes).sorted { lhs, rhs in
            if abs(lhs.1.midY - rhs.1.midY) > 0.02 { return lhs.1.midY > rhs.1.midY }
            return lhs.1.minX < rhs.1.minX
        }
        return paired
            .map { $0.0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .joined(separator: "\n")
    }

    /// 主导语言粗判定：CJK 标量占字母数字比例 ≥ 0.25 判 zh-Hans，否则 en-US。
    nonisolated static func dominantLocale(of text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let cjk = scalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let alphanumeric = scalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        guard alphanumeric > 0 else { return "en-US" }
        return Double(cjk) / Double(alphanumeric) >= 0.25 ? "zh-Hans" : "en-US"
    }
}
