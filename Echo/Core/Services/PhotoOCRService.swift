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
