// ==========================================
// 文件: SharedAudioExtractor.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-003 (语音转写摄入)
//            docs/decisions/ADR-008-source-import-boundaries.md §决策-3/7 (App Group 信封)
// 任务: 3F.5 - Production ingestion
// AC 覆盖: US-ING-003 AC-1 (Whisper.cpp 离线转写), AC-3 (原始音频不持久化),
//          DEF-51-002 (App Group 持久化音频文件 URL → transcribeFile)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (零网络), R-007 (禁止 unchecked Sendable)
// PR#57 CodeRabbit fix: CR-7 URL(string:) 先解析 file:// payload（回退 fileURLWithPath）;
//                       CR-24 Fake 提取器 #if DEBUG 包裹
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-10
// ==========================================

import Foundation

/// 共享音频提取结果 — 供生产摄入管线消费。
public struct SharedAudioContent: Sendable, Equatable {
    /// 去重键（ADR-008 §决策-4）
    public nonisolated let dedupeKey: String
    /// 本地音频文件 URL（App Group 持久化定位符，DEF-51-002）
    public nonisolated let fileURL: URL
    /// 来源类型（"voice" / "thirdParty"）
    public nonisolated let sourceType: String

    public nonisolated init(dedupeKey: String, fileURL: URL, sourceType: String) {
        self.dedupeKey = dedupeKey
        self.fileURL = fileURL
        self.sourceType = sourceType
    }
}

/// 共享音频提取协议 — 从 Share 信封解析 App Group 持久化音频文件。
public protocol SharedAudioExtracting: Sendable {
    /// 解析音频文件 URL（payload 为文件定位符，文件必须存在于 App Group 容器）。
    nonisolated func extractAudio(from envelope: SharedImportEnvelope) throws -> SharedAudioContent
}

/// 真实共享音频提取实现 — payload 为 App Group 持久化定位符（ADR-008 §决策-7）。
public struct RealSharedAudioExtractor: SharedAudioExtracting {

    public nonisolated init() {}

    public nonisolated func extractAudio(from envelope: SharedImportEnvelope) throws -> SharedAudioContent {
        let locator = envelope.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locator.isEmpty else {
            throw SharedImportError.emptyPayload
        }
        // CR-7: Share Extension 以 fileURL.absoluteString（file://...）写入 payload，
        // 需先经 URL(string:) 解析；无 scheme 的纯路径再回退 fileURLWithPath。
        let url: URL
        if let parsed = URL(string: locator), parsed.isFileURL {
            url = parsed
        } else {
            url = URL(fileURLWithPath: locator)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SharedImportError.unsupportedContentKind("audio file missing at locator")
        }
        return SharedAudioContent(
            dedupeKey: envelope.dedupeKey,
            fileURL: url,
            sourceType: envelope.sourceType.rawValue
        )
    }
}

#if DEBUG
/// 测试用 Fake 共享音频提取器 — 固定文件 URL（文件存在性由调用方控制）。
public actor FakeSharedAudioExtractor: SharedAudioExtracting {

    private let fileURL: URL?
    private let throwError: Bool

    public init(fileURL: URL? = nil, throwError: Bool = false) {
        self.fileURL = fileURL
        self.throwError = throwError
    }

    public nonisolated func extractAudio(from envelope: SharedImportEnvelope) throws -> SharedAudioContent {
        if throwError {
            throw SharedImportError.unsupportedContentKind("audio file missing at locator")
        }
        return SharedAudioContent(
            dedupeKey: envelope.dedupeKey,
            fileURL: fileURL ?? URL(fileURLWithPath: envelope.payload),
            sourceType: envelope.sourceType.rawValue
        )
    }
}
#endif
