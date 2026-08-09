// ==========================================
// 文件: NativeWhisperCInterop.swift
// 对应规格: docs/decisions/ADR-009-offline-model-runtime.md → 决策 2/3
//            3F.3b - whisper.cpp 运行时接入与真实转写
// 任务: 3F.3b - whisper.cpp 运行时接入（C 互操作实现）
// AC 覆盖: NativeWhisperCInterop 真实转写（whisper_init_from_file + whisper_full）、
//          16kHz mono PCM 输入、转写文本输出、GGUF SHA-256 校验、
//          零网络（R-005）、Sendable 安全（R-007）
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载),
//           R-007 (禁止 @unchecked Sendable / nonisolated(unsafe))
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-09
// ==========================================

import Foundation
import whisper

// MARK: - Native Whisper C Interop

/// whisper.cpp 原生 C 互操作实现 — `whisper_init_from_file` + `whisper_full`。
///
/// ## Sendable 安全（R-007）
/// - 全部 whisper C 调用封装在同步 `transcribe(ggufPath:pcm:)` 内
/// - `whisper_context *` 指针在方法内创建并在返回前释放，**不跨 actor/隔离域逃逸**
/// - 无 `nonisolated(unsafe)`、无 `@unchecked Sendable`
///
/// ## 零网络（R-005）
/// - 模型从本地 GGUF 文件加载（`whisper_init_from_file`），无任何网络请求
///
/// ## 线程
/// - `transcribe` 是同步 CPU 密集操作（whisper tiny 约数秒），
///   由调用方（WhisperRuntimeBridge actor）提供串行执行上下文
public nonisolated struct NativeWhisperCInterop: WhisperCInterop {

    /// whisper.cpp 静态库已链接（3F.3b）— 恒为 true。
    public nonisolated let isAvailable = true

    public nonisolated init() {}

    /// 执行真实转写。
    ///
    /// - Parameters:
    ///   - ggufPath: whisper-tiny-q5_1.gguf 的本地文件路径
    ///   - pcm: 16kHz mono Float PCM 采样
    /// - Returns: 转写文本（whisper 原生输出，含前导空格，segments 拼接）
    /// - Throws: `WhisperRuntimeBridge.BridgeError`
    public nonisolated func transcribe(ggufPath: String, pcm: [Float]) throws -> String {
        // 1. 加载 GGUF 模型（本地文件，R-005）
        let contextParams = whisper_context_default_params()
        guard let ctx = whisper_init_from_file_with_params(ggufPath, contextParams) else {
            throw WhisperRuntimeBridge.BridgeError.modelFileMissing(modelName: "whisper-tiny-q5_1.gguf")
        }
        defer { whisper_free(ctx) }

        // 2. 推理参数（greedy 采样，关闭打印）
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.n_threads = 4
        params.language = nil
        params.translate = false
        params.no_timestamps = true

        // 3. 执行推理（PCM → log-mel → encoder → decoder → 文本）
        let result = whisper_full(ctx, params, pcm, Int32(pcm.count))
        guard result == 0 else {
            throw WhisperRuntimeBridge.BridgeError.transcriptionFailed(reason: "whisper_full failed: \(result)")
        }

        // 4. 拼接 segments 文本
        let segmentCount = whisper_full_n_segments(ctx)
        guard segmentCount > 0 else {
            throw WhisperRuntimeBridge.BridgeError.transcriptionFailed(reason: "no segments produced")
        }
        var transcript = ""
        for i in 0..<segmentCount {
            guard let segmentText = whisper_full_get_segment_text(ctx, i) else {
                throw WhisperRuntimeBridge.BridgeError.transcriptionFailed(reason: "segment text nil at \(i)")
            }
            transcript += String(cString: segmentText)
        }
        return transcript
    }
}
