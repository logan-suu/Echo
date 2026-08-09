// ==========================================
// 文件: 3F.3b_WhisperRuntimeTests.swift
// 对应规格: docs/decisions/ADR-009-offline-model-runtime.md → 决策 2/3
//            docs/01-spec/用户故事与验收标准规格书.md → US-ING-003 AC-1, US-ING-005 AC-2, US-SRC-011
//            3F.3b - whisper.cpp 运行时接入与真实转写
// 任务: 3F.3b - whisper.cpp 运行时接入（GREEN 测试）
// AC 覆盖: runtime-linked（WhisperRuntimeBridge 真实转写可用）、real-transcript（16kHz mono PCM→文本）、
//          reference-CER/WER（whisper-reference-transcripts.json 阈值）、GGUF-hash（SHA-256 与 register 一致）、
//          DEF-51-002 ASR 文件输入契约重设计（文件 URL 输入 → 转写）
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (零网络), R-007 (禁止 unchecked Sendable)
// 状态: GREEN — whisper.cpp 运行时已接入，真实转写验证通过（本地 CER=0.0 ≤ 0.15）
// 模型门控: 模型缺失时静默跳过（与 3F.3a SigLIP2 / E5 测试约定一致，DEF-54-001 先例）；
//           CI 无模型时测试跳过而非失败，最终门禁由 3F.11 no-fixture E2E 覆盖
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-09
// ==========================================

import Testing
import Foundation
import CryptoKit
@testable import Echo
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Shared Helpers

/// whisper GGUF 是否存在于当前 Bundle（模型文件 gitignored，CI 可能缺失）。
private func whisperModelAvailable() -> Bool {
    Bundle.main.url(forResource: "whisper-tiny-q5_1", withExtension: "gguf") != nil
}

/// jfk.wav 参考转写音频是否存在于 Bundle。
private func jfkAudioAvailable() -> Bool {
    Bundle.main.url(forResource: "jfk", withExtension: "wav") != nil
}

/// 从 Bundle 加载 whisper-reference-transcripts.json（US-SRC-011 model semantics）。
private func loadReferenceTranscripts() throws -> [String: String] {
    guard let url = Bundle.main.url(forResource: "whisper-reference-transcripts", withExtension: "json") else {
        throw ASREngineError.transcriptionFailed(reason: "whisper-reference-transcripts.json missing")
    }
    let data = try Data(contentsOf: url)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let samples = obj?["samples"] as? [[String: Any]] else {
        throw ASREngineError.transcriptionFailed(reason: "invalid reference transcripts schema")
    }
    var dict: [String: String] = [:]
    for sample in samples {
        if let id = sample["id"] as? String, let transcript = sample["reference"] as? String {
            dict[id] = transcript
        }
    }
    return dict
}

/// 计算归一化 CER（字符编辑距离 / 参考字符数）。
private func cer(reference: String, hypothesis: String) -> Double {
    let ref = reference.lowercased().filter { $0.isLetter || $0.isNumber }
    let hyp = hypothesis.lowercased().filter { $0.isLetter || $0.isNumber }
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
    let refChars = Array(ref)
    let hypChars = Array(hyp)
    var dp = [[Int]](repeating: [Int](repeating: 0, count: hypChars.count + 1), count: refChars.count + 1)
    for i in 0...refChars.count { dp[i][0] = i }
    for j in 0...hypChars.count { dp[0][j] = j }
    for i in 1...refChars.count {
        for j in 1...hypChars.count {
            let cost = refChars[i - 1] == hypChars[j - 1] ? 0 : 1
            dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
        }
    }
    return Double(dp[refChars.count][hypChars.count]) / Double(refChars.count)
}

/// 从 jfk.wav 提取 16kHz mono Float PCM（与 WhisperASREngine.preprocessAudio 同契约）。
private func loadJFKPCM() throws -> [Float] {
    guard let url = Bundle.main.url(forResource: "jfk", withExtension: "wav") else {
        throw ASREngineError.transcriptionFailed(reason: "jfk.wav missing")
    }
    let data = try Data(contentsOf: url)
    guard data.count > 44, String(data: data[0..<4], encoding: .ascii) == "RIFF" else {
        throw ASREngineError.transcriptionFailed(reason: "invalid wav")
    }

    func u16(_ o: Int) -> UInt16 {
        UInt16(data[o]) | (UInt16(data[o + 1]) << 8)
    }
    func u32(_ o: Int) -> UInt32 {
        UInt32(data[o]) | (UInt32(data[o + 1]) << 8) | (UInt32(data[o + 2]) << 16) | (UInt32(data[o + 3]) << 24)
    }

    var offset = 12
    var sampleRate = 0, channels = 0, bitsPerSample = 0
    while offset + 8 <= data.count {
        let chunkID = String(data: data[offset..<offset + 4], encoding: .ascii) ?? ""
        let chunkSize = Int(u32(offset + 4))
        if chunkID == "fmt " {
            channels = Int(u16(offset + 10))
            sampleRate = Int(u32(offset + 12))
            bitsPerSample = Int(u16(offset + 22))
        }
        if chunkID == "data" {
            let dataStart = offset + 8
            var pcm: [Float] = []
            if bitsPerSample == 16 {
                let samples = Int(chunkSize) / 2
                for i in 0..<samples {
                    let raw = u16(dataStart + i * 2)
                    pcm.append(Float(Int16(bitPattern: raw)) / 32768.0)
                }
            } else if bitsPerSample == 32 {
                let samples = Int(chunkSize) / 4
                for i in 0..<samples {
                    let raw = u32(dataStart + i * 4)
                    pcm.append(Float(bitPattern: raw))
                }
            }
            var mono = pcm
            if channels == 2 {
                var m: [Float] = []
                for i in stride(from: 0, to: pcm.count - 1, by: 2) {
                    m.append((pcm[i] + pcm[i + 1]) / 2)
                }
                mono = m
            }
            if sampleRate != 16000 {
                let ratio = Double(sampleRate) / 16000.0
                let newCount = Int(Double(mono.count) / ratio)
                var resampled: [Float] = []
                for i in 0..<newCount {
                    resampled.append(mono[min(Int(Double(i) * ratio), mono.count - 1)])
                }
                mono = resampled
            }
            return mono
        }
        offset += 8 + Int(chunkSize) + (Int(chunkSize) % 2)
    }
    throw ASREngineError.transcriptionFailed(reason: "no data chunk in wav")
}

// MARK: - Runtime Linked

@Suite("WhisperRuntimeTests.RuntimeLinked", .serialized)
@MainActor
struct WhisperRuntimeLinkedTests {

    @Test("bridge transcribes when whisper.cpp runtime linked")
    func test_bridge_runtimeLinked() async throws {
        guard whisperModelAvailable() else { return }
        let bridge = WhisperRuntimeBridge()
        // RED: 实现前 bridge 默认 UnavailableWhisperCInterop → runtimeNotLinked
        // GREEN: 实现后默认 NativeWhisperCInterop → 可处理 1s 静音 PCM（无语音也会走完管线）
        _ = try await bridge.transcribe(pcm: [Float](repeating: 0, count: 16000))
        #expect(true, "whisper.cpp 运行时已链接，bridge.transcribe 不应抛 runtimeNotLinked")
    }
}

// MARK: - Real Transcription

@Suite("WhisperRuntimeTests.RealTranscript", .serialized)
@MainActor
struct WhisperRealTranscriptTests {

    @Test("bridge transcribes real 16kHz mono PCM (jfk.wav)")
    func test_bridge_realTranscript() async throws {
        guard whisperModelAvailable() && jfkAudioAvailable() else { return }
        let pcm = try loadJFKPCM()
        #expect(!pcm.isEmpty, "jfk.wav 必须产出非空 PCM")

        let bridge = WhisperRuntimeBridge()
        let transcript = try await bridge.transcribe(pcm: pcm)
        #expect(!transcript.isEmpty, "whisper.cpp 必须产出非空转写")
    }

    @Test("transcript contains key phrases of jfk speech")
    func test_bridge_transcriptContent() async throws {
        guard whisperModelAvailable() && jfkAudioAvailable() else { return }
        let pcm = try loadJFKPCM()
        let bridge = WhisperRuntimeBridge()
        let transcript = try await bridge.transcribe(pcm: pcm)
        let lower = transcript.lowercased()
        #expect(lower.contains("country"), "转写应包含 country，实际: \(transcript)")
    }
}

// MARK: - Reference CER/WER

@Suite("WhisperRuntimeTests.ReferenceCERWER", .serialized)
@MainActor
struct WhisperReferenceCERWERTests {

    /// CER 阈值：whisper tiny Q5_1 对 jfk.wav 的参考转写（spike 实测 CER=0.0，阈值 0.15 留裕量）
    nonisolated private static let cerThreshold: Double = 0.15

    @Test("reference transcripts file populated with jfk sample")
    func test_referenceFile_populated() throws {
        let refs = try loadReferenceTranscripts()
        #expect(refs["jfk"] != nil, "whisper-reference-transcripts.json 必须回填 jfk 参考转写")
    }

    @Test("real transcript CER within threshold")
    func test_transcript_CERWithinThreshold() async throws {
        guard whisperModelAvailable() && jfkAudioAvailable() else { return }
        let refs = try loadReferenceTranscripts()
        guard let reference = refs["jfk"] else {
            Issue.record("reference transcripts 未回填 jfk 样本")
            return
        }
        let pcm = try loadJFKPCM()
        let bridge = WhisperRuntimeBridge()
        let transcript = try await bridge.transcribe(pcm: pcm)
        let score = cer(reference: reference, hypothesis: transcript)
        #expect(score <= Self.cerThreshold,
                "CER \(score) 超出阈值 \(Self.cerThreshold)。参考: \(reference) 实际: \(transcript)")
    }
}

// MARK: - GGUF Hash

@Suite("WhisperRuntimeTests.GGUFHash", .serialized)
struct WhisperGGUFHashTests {

    /// model-provenance-register §2 登记的 whisper-tiny-q5_1.gguf SHA-256
    nonisolated private static let registeredHash = "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"

    @Test("bundle GGUF SHA-256 matches provenance register")
    func test_gguf_sha256() throws {
        guard let url = Bundle.main.url(forResource: "whisper-tiny-q5_1", withExtension: "gguf") else { return }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hash == Self.registeredHash,
                "GGUF SHA-256 \(hash) 与 register \(Self.registeredHash) 不一致")
    }
}

// MARK: - DEF-51-002 ASR File Input Contract

@Suite("WhisperRuntimeTests.FileInputContract", .serialized)
@MainActor
struct WhisperFileInputContractTests {

    @Test("ASR engine transcribes from file URL (DEF-51-002 contract redesign)")
    func test_asrEngine_fileURLInput() async throws {
        guard whisperModelAvailable() && jfkAudioAvailable() else { return }
        let engine = WhisperASREngine()
        // RED: 实现前 transcribeFile 依赖 bridge → runtimeNotLinked / modelNotLoaded
        // GREEN: 实现后从 jfk.wav 真实转写（DEF-51-002 文件输入契约）
        guard let url = Bundle.main.url(forResource: "jfk", withExtension: "wav") else { return }
        let transcript = try await engine.transcribeFile(at: url)
        #expect(!transcript.isEmpty, "WhisperASREngine 必须支持文件 URL 输入转写（DEF-51-002）")
    }
}
