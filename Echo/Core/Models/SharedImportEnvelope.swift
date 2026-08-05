// ==========================================
// 文件: SharedImportEnvelope.swift
// 对应规格: docs/decisions/ADR-008-source-import-boundaries.md §决策-3 (App Group 信封),
//            §决策-4 (去重键与来源身份), §决策-7 (最小数据边界)
//            docs/01-spec/用户故事与验收标准规格书.md → US-SRC-001 (share-only 备忘录/语音),
//            US-SRC-003 (第三方 Share 文本/图片/链接/文件)
// 任务: 3F.2 - PhotoKit、Share Extension 与真实来源
// AC 覆盖: ADR-008 §决策-3 (App Group 信封最小字段), §决策-4 (稳定来源身份 + dedupe key),
//          §决策-7 (不存储原文件全文于队列), US-SRC-003 AC-1 (支持文本/图片/链接/文件),
//          R-002 (禁止用户主动输入文本记忆 — 文本仅来自系统备忘录/语音转写分享)
// 架构约束: AGENTS.md R-007 (禁止 unchecked Sendable), §5.4 (审计仅哈希摘要)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
//       本文件同时编译进 Echo 与 EchoShareExtension target，不得依赖 App target 专属符号
// 生成时间: 2026-08-05
// ==========================================

import Foundation
import CryptoKit

// MARK: - Shared Import Error

/// Share 信封校验错误（L2 可恢复：调用方传入非法参数）
public enum SharedImportError: Error, LocalizedError, Sendable, Equatable {
    /// 载荷为空或纯空白（最小数据边界，拒绝空投递）
    case emptyPayload
    /// 数据源类型与内容类型组合非法（如 note 不可能携带 audio）
    case unsupportedCombination(sourceType: String, contentKind: String)
    /// 不支持的 Share 内容类型
    case unsupportedContentKind(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPayload:
            return "Shared import payload is empty"
        case .unsupportedCombination(let sourceType, let contentKind):
            return "Unsupported combination: source=\(sourceType) kind=\(contentKind)"
        case .unsupportedContentKind(let kind):
            return "Unsupported shared content kind: \(kind)"
        }
    }
}

// MARK: - Content Kind

/// Share 内容类型（US-SRC-003 AC-1：文本/图片/链接/文件；voice 走 audio）
public enum SharedImportContentKind: String, Sendable, Codable, Equatable {
    case text
    case url
    case audio
    case image
    case file
}

// MARK: - Source Type

/// Share 来源类型（ADR-008 §决策-2：Notes/Voice 仅 Share Extension 显式分享）
public enum SharedImportSourceType: String, Sendable, Codable, Equatable {
    /// 备忘录显式分享（US-SRC-001）→ sourceType 对应 "note"
    case note
    /// 语音备忘录显式分享（US-SRC-001）→ sourceType 对应 "voice"
    case voice
    /// 第三方 App 分享（US-SRC-003）→ 标记 source=thirdParty，不参与自动情境触发
    case thirdParty
}

// MARK: - Shared Import Envelope

/// App Group 分享信封（ADR-008 §决策-3/§决策-7）。
///
/// ## 最小数据边界（ADR-008 §决策-7）
/// - 信封仅承载最小字段：内容类型、来源、载荷、来源 App、时间戳、可选标签
/// - 不存储原文件全文（payload 对 audio/image/file 为文件定位符，非文件内容）
///
/// ## 去重键（ADR-008 §决策-4）
/// - `dedupeKey` 由 来源身份 + 内容类型 + 载荷 计算 SHA-256，跨投递稳定
/// - 同一内容的重复投递被 `SharedImportQueueActor` 拒绝
public struct SharedImportEnvelope: Sendable, Codable, Equatable {

    public nonisolated let envelopeId: String
    public nonisolated let contentKind: SharedImportContentKind
    public nonisolated let sourceType: SharedImportSourceType
    /// 载荷：文本内容（text/url）或文件/音频定位符（audio/image/file）。绝不存原文件全文。
    public nonisolated let payload: String
    /// 来源 App Bundle ID（US-SRC-003 AC-4 审计字段）
    public nonisolated let sourceAppBundleId: String
    public nonisolated let createdAt: Date
    /// 用户可选标签/备注（US-SRC-003 AC-2 导入前确认）
    public nonisolated let optionalLabel: String?

    public nonisolated init(
        envelopeId: String = UUID().uuidString,
        contentKind: SharedImportContentKind,
        sourceType: SharedImportSourceType,
        payload: String,
        sourceAppBundleId: String,
        createdAt: Date = Date(),
        optionalLabel: String? = nil
    ) {
        self.envelopeId = envelopeId
        self.contentKind = contentKind
        self.sourceType = sourceType
        self.payload = payload
        self.sourceAppBundleId = sourceAppBundleId
        self.createdAt = createdAt
        self.optionalLabel = optionalLabel
    }

    // MARK: - Dedupe Key (ADR-008 §决策-4)

    /// 稳定去重键 = SHA-256(来源身份 | 内容类型 | 载荷)。
    ///
    /// 来源身份参与哈希：同一文本从 note 与 thirdParty 分享产生不同的键，
    /// 避免跨来源错误去重。载荷参与哈希保证内容一致才去重。
    public nonisolated var dedupeKey: String {
        let combined = sourceType.rawValue + "|" + contentKind.rawValue + "|" + payload
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Validation Factory

    /// 校验并构造信封（share-only 组合校验）。
    ///
    /// - 拒绝空载荷
    /// - 拒绝非法 来源×内容 组合：
    ///   - note → 仅 text（US-SRC-001 备忘录文本）
    ///   - voice → 仅 audio（US-SRC-001 语音备忘录）
    ///   - thirdParty → text/url/audio/image/file（US-SRC-003 AC-1）
    public static func make(
        contentKind: SharedImportContentKind,
        sourceType: SharedImportSourceType,
        payload: String,
        sourceAppBundleId: String,
        createdAt: Date = Date(),
        optionalLabel: String? = nil
    ) throws -> SharedImportEnvelope {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SharedImportError.emptyPayload }
        guard isValidCombination(contentKind: contentKind, sourceType: sourceType) else {
            throw SharedImportError.unsupportedCombination(
                sourceType: sourceType.rawValue,
                contentKind: contentKind.rawValue
            )
        }
        return SharedImportEnvelope(
            contentKind: contentKind,
            sourceType: sourceType,
            payload: payload,
            sourceAppBundleId: sourceAppBundleId,
            createdAt: createdAt,
            optionalLabel: optionalLabel
        )
    }

    /// 来源×内容组合合法性（share-only 语义）。
    public nonisolated static func isValidCombination(
        contentKind: SharedImportContentKind,
        sourceType: SharedImportSourceType
    ) -> Bool {
        switch sourceType {
        case .note:
            return contentKind == .text
        case .voice:
            return contentKind == .audio
        case .thirdParty:
            return [.text, .url, .audio, .image, .file].contains(contentKind)
        }
    }

    // MARK: - Wire Format

    /// App Group 信封 wire 编码（供队列文件存储，跨 App/Extension 共享格式契约）。
    public nonisolated func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        return try encoder.encode(self)
    }

    /// 解码 App Group 信封。
    public nonisolated static func decode(_ data: Data) throws -> SharedImportEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try decoder.decode(SharedImportEnvelope.self, from: data)
    }

    // MARK: - Codable (nonisolated — 队列 Actor 在非 MainActor 上下文编码/解码)

    private enum CodingKeys: String, CodingKey {
        case envelopeId
        case contentKind
        case sourceType
        case payload
        case sourceAppBundleId
        case createdAt
        case optionalLabel
    }

    public nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(envelopeId, forKey: .envelopeId)
        try container.encode(contentKind, forKey: .contentKind)
        try container.encode(sourceType, forKey: .sourceType)
        try container.encode(payload, forKey: .payload)
        try container.encode(sourceAppBundleId, forKey: .sourceAppBundleId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(optionalLabel, forKey: .optionalLabel)
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        envelopeId = try container.decode(String.self, forKey: .envelopeId)
        contentKind = try container.decode(SharedImportContentKind.self, forKey: .contentKind)
        sourceType = try container.decode(SharedImportSourceType.self, forKey: .sourceType)
        payload = try container.decode(String.self, forKey: .payload)
        sourceAppBundleId = try container.decode(String.self, forKey: .sourceAppBundleId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        optionalLabel = try container.decodeIfPresent(String.self, forKey: .optionalLabel)
    }
}
