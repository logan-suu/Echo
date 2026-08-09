// ==========================================
// 文件: WhisperASREngine.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-3.3
//            调研报告 §8 (Whisper 路线族)
// 任务: R-3.3 - Bundled 官方 Whisper ASR 引擎（替代 SenseVoice）
//      3F.3b - whisper.cpp 真实转写接入（2026-08-09）
// AC 覆盖: whisper.cpp Swift 桥接、音频预处理（PCM 16kHz mono）、
//          VAD、转写文本 + 语种标签输出、
//          DEF-51-002 ASR 文件输入契约（transcribeFile）
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载)
// 法律状态: 格式转换不授予新权利，源权重/runtime/转换器/量化/工件均需分别审查
// 状态: 3F.3b — whisper.cpp 真实转写已接入（NativeWhisperCInterop + WhisperRuntimeBridge）
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-01
// ==========================================

import Foundation
@preconcurrency import AVFoundation

// MARK: - Whisper ASR Engine

/// Whisper ASR 引擎（R-3.3）— 替代 SenseVoice（保守短名单排除）。
///
/// 路线：bundled 官方 Whisper 衍生（whisper.cpp runtime）。
/// 变体选择：tiny (~39MB GGUF)，追求包体与质量平衡（R-5.4 批准）。
///
/// ## 推理流程（3F.3b）
/// 1. 音频预处理：AVAssetReader → PCM 16kHz mono（`preprocessAudio`）
/// 2. VAD：基于能量阈值（`hasSpeech`）
/// 3. whisper.cpp 推理：`WhisperRuntimeBridge`（NativeWhisperCInterop）
/// 4. 输出：转写文本
public actor WhisperASREngine: ASREngineProtocol {

    // MARK: - Constants

    /// Whisper 要求的采样率
    private nonisolated static let sampleRate: Double = 16000.0
    /// VAD 能量阈值（低于此值视为静音）
    private nonisolated static let vadEnergyThreshold: Float = 0.01

    // MARK: - Properties

    private let modelLoader: ModelLoaderActor
    private let runtimeBridge: WhisperRuntimeBridge

    // MARK: - Initialization

    public init(modelLoader: ModelLoaderActor = .shared) {
        self.modelLoader = modelLoader
        self.runtimeBridge = WhisperRuntimeBridge(modelLoader: modelLoader)
    }

    // MARK: - ASREngineProtocol

    /// 对音频轨道执行 Whisper 转写。
    ///
    /// - Parameter audioTrackAssetId: 音频轨道的 PHAsset.localIdentifier
    /// - Returns: 转写文本
    public func transcribe(audioTrackAssetId: String) async throws -> String {
        guard let audioURL = await loadAudioAsset(audioTrackAssetId) else {
            throw ASREngineError.transcriptionFailed(reason: "Audio asset not found: \(audioTrackAssetId)")
        }
        return try await transcribeFile(at: audioURL)
    }

    /// DEF-51-002: 从本地音频文件 URL 执行 Whisper 转写（文件输入契约）。
    ///
    /// - Parameter url: 本地音频文件 URL（Share Extension App Group 持久化定位符）
    /// - Returns: 转写文本
    public func transcribeFile(at url: URL) async throws -> String {
        let pcmData = try await preprocessAudio(from: url)
        guard hasSpeech(pcmData) else {
            throw ASREngineError.noSpeechDetected
        }
        do {
            return try await runtimeBridge.transcribe(pcm: pcmData)
        } catch let error as WhisperRuntimeBridge.BridgeError {
            throw mapBridgeError(error)
        }
    }

    /// 将 Bridge 错误映射为 ASR 引擎错误。
    private nonisolated func mapBridgeError(_ error: WhisperRuntimeBridge.BridgeError) -> ASREngineError {
        switch error {
        case .modelFileMissing(let name):
            return .transcriptionFailed(reason: "Whisper model missing: \(name)")
        case .runtimeNotLinked:
            return .modelNotLoaded
        case .transcriptionFailed(let reason):
            return .transcriptionFailed(reason: reason)
        case .checksumMismatch(let expected, let actual):
            return .transcriptionFailed(reason: "GGUF checksum mismatch: expected \(expected), got \(actual)")
        }
    }

    /// 加载音频轨道（PHAsset ID → 本地文件 URL）。
    ///
    /// DEF-51-002 备注：PHAsset ID 语义与文件 URL 不符，3F.5 生产摄入将统一为
    /// 文件输入（`transcribeFile`）；本方法为兼容旧调用保留，失败返回 nil。
    private func loadAudioAsset(_ assetId: String) async -> URL? {
        nil
    }

    // MARK: - Audio Preprocessing

    /// 音频预处理：AVAssetReader → PCM 16kHz mono。
    ///
    /// Whisper 要求 16kHz 单声道 PCM 输入。
    func preprocessAudio(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ASREngineError.transcriptionFailed(reason: "No audio track found")
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)

        guard reader.startReading() else {
            throw ASREngineError.transcriptionFailed(reason: "Failed to start audio reader")
        }

        var pcmData: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer(),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

            if let pointer = dataPointer {
                let floatCount = length / MemoryLayout<Float>.size
                let floatPointer = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
                pcmData.append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: floatCount))
            }
        }

        // DEF-34-004 fix: 必须校验 reader 完整结束（非 .completed 即提前中断，丢弃不完整结果）
        guard reader.status == .completed else {
            throw ASREngineError.transcriptionFailed(
                reason: "Audio reader interrupted: status \(reader.status.rawValue)"
            )
        }

        return pcmData
    }

    // MARK: - VAD

    /// 简单能量阈值 VAD — 检测音频是否包含语音。
    nonisolated func hasSpeech(_ pcmData: [Float]) -> Bool {
        guard !pcmData.isEmpty else { return false }
        let energy = pcmData.reduce(0) { $0 + $1 * $1 } / Float(pcmData.count)
        return energy > Self.vadEnergyThreshold
    }
}
