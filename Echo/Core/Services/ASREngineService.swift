// ==========================================
// 文件: ASREngineService.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-005 (视频音频转写)
//            docs/02-architecture/数据流全链路技术说明文档.md §3.2 (视频摄入音频转写)
// 任务: 2.4 - IngestPipeline：视频摄入（AC-2: 离线转写）
//      3F.3b - DEF-51-002 ASR 文件输入契约重设计（2026-08-09）
// AC 覆盖: US-ING-005 AC-2 (离线转录音频轨道)、DEF-51-002 (文件 URL 输入契约)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载),
//           R-007 (禁止 unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 3F.3 (2026-08-06): SenseVoice（FunASR 自定义条款）退役，ASR 由 WhisperASREngine (R-3.3) 提供。
// 3F.3b (2026-08-09): whisper.cpp 真实转写接入；ASREngineProtocol 新增 `transcribeFile(at:)`
//   文件输入契约（DEF-51-002）— Share Extension 持久化的音频文件 URL 可直接转写，
//   PHAsset ID 语义契约由 3F.5 生产摄入统一。
// 生成时间: 2026-07-11
// ==========================================

import Foundation

// MARK: - ASR Engine Protocol

/// 离线语音转写协议 — 抽象 ASR 引擎，支持依赖注入与测试 Mock。
///
/// AC-2 (US-ING-005): 通过 Whisper tiny（whisper.cpp）离线转录音频轨道为文本。
/// DEF-51-002 (3F.3b): `transcribeFile(at:)` 提供文件 URL 输入契约 —
///   Share Extension 将音频拷入 App Group 持久定位符后可直接转写；
///   `transcribe(audioTrackAssetId:)` 保留 PHAsset ID 语义（视频轨，3F.5 统一）。
/// 协议设计为 Sendable（非 Actor），以便测试 Mock 无需 Actor 隔离。
public protocol ASREngineProtocol: Sendable {
    /// 对视频音频轨道进行离线语音转写。
    ///
    /// - Parameter audioTrackAssetId: 音频轨道的 PHAsset.localIdentifier
    /// - Returns: 转写后的文本
    /// - Throws: `ASREngineError` 若模型未加载或转写失败
    func transcribe(audioTrackAssetId: String) async throws -> String

    /// DEF-51-002: 对本地音频文件 URL 进行离线语音转写。
    ///
    /// - Parameter url: 本地音频文件 URL（16kHz mono 或任意采样率，引擎内部重采样）
    /// - Returns: 转写后的文本
    /// - Throws: `ASREngineError` 若模型未加载、音频无效或转写失败
    func transcribeFile(at url: URL) async throws -> String
}

// MARK: - ASR Engine Error

/// ASR 引擎统一错误类型
public enum ASREngineError: Error, LocalizedError, Sendable, Equatable {
    /// 转写模型尚未加载（L3 阻断）
    case modelNotLoaded
    /// 音频轨道提取或转写过程失败
    case transcriptionFailed(reason: String)
    /// 音频轨道无有效语音内容（静音或非语音）
    case noSpeechDetected

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "ASR model not loaded — 请在「设置」中重试模型加载"

        case .transcriptionFailed(let reason):
            return "Audio transcription failed: \(reason)"

        case .noSpeechDetected:
            return "No speech detected in audio track"
        }
    }
}

// MARK: - Stub ASR Engine

#if DEBUG
/// Stub ASR 引擎 — 返回固定转写文本或指定文本，用于 Pipeline 测试。
///
/// 该实现不依赖 Core ML 或 PHPhotoLibrary，纯逻辑验证 IngestPipeline 视频摄入流程正确性。
/// 真实转写由 `WhisperASREngine` + `WhisperRuntimeBridge`（R-3.3，whisper.cpp 接入后）实现。
public actor StubASREngine: ASREngineProtocol {
    /// 预设的转写文本（测试可控）
    private var nextTranscript: String
    /// 是否在下一次调用时抛出错误（测试可控）
    private var shouldThrowNext: ASREngineError?

    /// 创建 Stub ASR 引擎。
    /// - Parameter defaultTranscript: 未显式设置时使用的默认转写文本
    public init(defaultTranscript: String = "这是测试转写文本。") {
        self.nextTranscript = defaultTranscript
    }

    /// 设置下一次 `transcribe()` 返回的文本（测试用）。
    public func setNextTranscript(_ text: String) {
        nextTranscript = text
    }

    /// 设置下一次 `transcribe()` 抛出指定错误（测试用）。`nil` 清除错误。
    public func setNextError(_ error: ASREngineError?) {
        shouldThrowNext = error
    }

    /// 返回预设的固定转写文本，或抛出预设错误。
    /// - Parameter audioTrackAssetId: 音频轨道标识符（Stub 忽略此参数）
    /// - Returns: 预设的转写文本
    /// - Throws: 如已调用 `setNextError()` 则抛出对应错误
    public func transcribe(audioTrackAssetId: String) async throws -> String {
        if let error = shouldThrowNext {
            shouldThrowNext = nil
            throw error
        }
        return nextTranscript
    }

    /// DEF-51-002: 文件 URL 输入契约 — 返回预设文本（Stub 忽略文件内容）。
    public func transcribeFile(at url: URL) async throws -> String {
        if let error = shouldThrowNext {
            shouldThrowNext = nil
            throw error
        }
        return nextTranscript
    }
}
#endif
