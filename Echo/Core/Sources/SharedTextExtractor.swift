// ==========================================
// 文件: SharedTextExtractor.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-001/002 (备忘录文本摄入)
//            docs/decisions/ADR-008-source-import-boundaries.md §决策-3/7 (App Group 信封)
// 任务: 3F.5 - Production ingestion
// AC 覆盖: US-ING-001 AC-1/AC-2 (originalText 逐字节一致，语言方向), US-SRC-003 (第三方文本)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007 (禁止 unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-10
// ==========================================

import Foundation

/// 共享文本提取结果 — 供生产摄入管线消费。
public struct SharedTextContent: Sendable, Equatable {
    /// 去重键（ADR-008 §决策-4：来源×内容稳定哈希）
    public nonisolated let dedupeKey: String
    /// 原始文本（US-ING-001 AC-2：逐字节一致，不修改）
    public nonisolated let originalText: String
    /// 来源类型（"note" / "voice" / "thirdParty"）
    public nonisolated let sourceType: String

    public nonisolated init(dedupeKey: String, originalText: String, sourceType: String) {
        self.dedupeKey = dedupeKey
        self.originalText = originalText
        self.sourceType = sourceType
    }
}

/// 共享文本提取协议 — 从 Share 信封提取文本内容。
public protocol SharedTextExtracting: Sendable {
    /// 提取文本内容（校验非空；URL 类型返回其原始 payload）。
    nonisolated func extractText(from envelope: SharedImportEnvelope) throws -> SharedTextContent
}

/// 真实共享文本提取实现 — 与 Share Extension 信封 wire 格式一致。
public struct RealSharedTextExtractor: SharedTextExtracting {

    public nonisolated init() {}

    public nonisolated func extractText(from envelope: SharedImportEnvelope) throws -> SharedTextContent {
        let trimmed = envelope.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SharedImportError.emptyPayload
        }
        return SharedTextContent(
            dedupeKey: envelope.dedupeKey,
            originalText: envelope.payload,
            sourceType: envelope.sourceType.rawValue
        )
    }
}

/// 测试用 Fake 共享文本提取器 — 固定内容。
public actor FakeSharedTextExtractor: SharedTextExtracting {

    private let text: String?

    public init(text: String? = nil) {
        self.text = text
    }

    public nonisolated func extractText(from envelope: SharedImportEnvelope) throws -> SharedTextContent {
        let payload = text ?? envelope.payload
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SharedImportError.emptyPayload
        }
        return SharedTextContent(
            dedupeKey: envelope.dedupeKey,
            originalText: payload,
            sourceType: envelope.sourceType.rawValue
        )
    }
}
