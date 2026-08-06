// ==========================================
// 文件: WhisperRuntimeBridge.swift
// 对应规格: docs/decisions/ADR-009-offline-model-runtime.md → 决策 2/3
//            Echo dev-1.0 缺陷修复计划.md → Phase R-3.3 (whisper.cpp 桥接)
// 任务: 3F.3 - E5、SigLIP2、Whisper 与离线生成决策落地
// AC 覆盖: GGUF 模型加载、16kHz mono PCM 输入、转写文本输出、
//          损坏/缺失工件 L3 恢复（US-RES-004）、零网络（R-005）
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载),
//           R-007 (禁止 @unchecked Sendable / nonisolated(unsafe))
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-06
// ==========================================

import Foundation

// MARK: - Whisper Runtime Bridge

/// whisper.cpp 运行时桥接（R-3.3 / 3F.3）— 将 GGUF 模型与 PCM 音频送入 whisper.cpp。
///
/// ## 设计
/// - 通过 `WhisperCInterop` 协议隔离 C 互操作（whisper.cpp C API）
/// - 默认 `UnavailableWhisperCInterop`：whisper.cpp 静态库未随包链接时优雅降级
///   （L3 阻断：`runtimeNotLinked`），不崩溃、不伪造转写
/// - PCM 契约：16kHz 单声道 Float（由 `WhisperASREngine.preprocessAudio` 产出）
///
/// ## whisper.cpp 接入（后续 PR）
/// 1. 引入 whisper.cpp 源（SPM/静态库，需 AGENTS.md §2.2 白名单审批）
/// 2. 实现 `NativeWhisperCInterop`：`whisper_init_from_file` + `whisper_full`
/// 3. 校验 SHA-256 与 model-provenance-register 一致性
public actor WhisperRuntimeBridge {

    // MARK: - Error

    /// whisper 桥接错误
    public enum BridgeError: Error, LocalizedError, Sendable {
        /// 模型文件缺失（L3）
        case modelFileMissing(modelName: String)
        /// whisper.cpp 运行时未链接（L3，等待接入）
        case runtimeNotLinked
        /// 推理失败
        case transcriptionFailed(reason: String)

        public nonisolated var errorDescription: String? {
            switch self {
            case .modelFileMissing(let name):
                return "Whisper model missing: \(name)"
            case .runtimeNotLinked:
                return "whisper.cpp runtime not linked — transcription unavailable"
            case .transcriptionFailed(let reason):
                return "Whisper transcription failed: \(reason)"
            }
        }
    }

    // MARK: - Properties

    private let modelLoader: ModelLoaderActor
    private let cInterop: any WhisperCInterop

    // MARK: - Initialization

    /// 创建桥接器。
    ///
    /// - Parameters:
    ///   - modelLoader: 模型加载 Actor（获取 GGUF bundle URL）
    ///   - cInterop: whisper.cpp C 互操作实现（默认不可用，等待运行时接入）
    public init(
        modelLoader: ModelLoaderActor = .shared,
        cInterop: any WhisperCInterop = UnavailableWhisperCInterop()
    ) {
        self.modelLoader = modelLoader
        self.cInterop = cInterop
    }

    // MARK: - Transcription

    /// 转写 16kHz 单声道 PCM 浮点采样。
    ///
    /// - Parameter pcm: Float 采样（16kHz mono）
    /// - Returns: 转写文本
    public func transcribe(pcm: [Float]) async throws -> String {
        guard let ggufURL = await modelLoader.getModelBundleURL(.whisperTiny) else {
            throw BridgeError.modelFileMissing(modelName: "whisper-tiny-q5_1.gguf")
        }
        guard cInterop.isAvailable else {
            throw BridgeError.runtimeNotLinked
        }
        return try cInterop.transcribe(ggufPath: ggufURL.path, pcm: pcm)
    }
}

// MARK: - C Interop Protocol

/// whisper.cpp C 互操作协议（隔离 C 层，保证 Sendable 安全）。
public nonisolated protocol WhisperCInterop: Sendable {
    /// 运行时是否可用（静态库已链接）。
    var isAvailable: Bool { get }
    /// 执行转写。
    ///
    /// - Parameters:
    ///   - ggufPath: GGUF 模型文件路径
    ///   - pcm: 16kHz mono Float PCM
    /// - Returns: 转写文本
    func transcribe(ggufPath: String, pcm: [Float]) throws -> String
}

// MARK: - Unavailable Implementation

/// 默认不可用实现 — whisper.cpp 静态库未链接时使用。
///
/// 抛 `BridgeError.runtimeNotLinked`（L3），保证管线 fail-closed。
public nonisolated struct UnavailableWhisperCInterop: WhisperCInterop {
    public nonisolated let isAvailable = false

    public init() {}

    public func transcribe(ggufPath: String, pcm: [Float]) throws -> String {
        throw WhisperRuntimeBridge.BridgeError.runtimeNotLinked
    }
}
