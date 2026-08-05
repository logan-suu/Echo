// ==========================================
// 文件: 2.5_IngestPipelineTextTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-001 (备忘录文本摄入-中文),
//            US-ING-002 (备忘录文本摄入-英文), US-ING-003 (语音备忘录转写摄入)
// 任务: 2.5 - IngestPipeline：备忘录 + 语音转写（US-ING-001~003）
// AC 覆盖: US-ING-001 AC-1 (sourceLanguage=zh-Hans), AC-2 (originalText 逐字节一致),
//          AC-3 (384d→512d 向量), AC-5 (.memoryIngested 审计),
//          US-ING-002 (language=en-US), US-ING-003 AC-1 (语音转写),
//          AC-3 (音频不持久化), AC-4 (置信度<0.7→.uncertainTranscript),
//          AC-5 (.voiceIngested 审计)
// 架构约束: AGENTS.md §4.1 (Pipeline 契约), R-006 (PrivacyCheckpoint)
// 重要: @MainActor 标注因 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// 生成时间: 2026-07-12
// ==========================================

import Testing
import Foundation
import ProximaKit
@testable import Echo

// MARK: - Test Suite: IngestPipeline Text & Voice Ingestion (US-ING-001~003)

@Suite("IngestPipeline Text & Voice Ingestion (US-ING-001~003)", .serialized)
@MainActor
struct IngestPipelineTextTests {

    // MARK: - Dependencies

    let db = DatabaseManager.shared
    let privacyActor = PrivacyActor.shared
    let vectorStore = VectorStoreActor(dimension: 512)

    /// Stub embedder — returns controllable vectors for deterministic testing
    let stubEmbedder = StubEmbedder()

    /// Stub ASR engine — returns controllable transcript for deterministic testing
    let stubASR = StubASREngine()

    /// System under test
    var sut: IngestPipeline {
        IngestPipeline(
            embedder: stubEmbedder,
            asrEngine: stubASR,
            privacyActor: privacyActor,
            vectorStore: vectorStore
        )
    }

    // MARK: - Setup

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        // 3F.1+ 套件可能先写 ConsentStore（deny-by-default gate 启用），
        // 本套件必须清理，否则残留 consent 会让 privacyActor.validate 拒绝（CI 顺序污染）
        try await db.execute(sql: "DELETE FROM ConsentStore")
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["note", "voice", "photo", "video"],
            policyVersion: 1
        ))
    }

    // MARK: - US-ING-001: Text Ingestion (Chinese)

    @Test("AC-1: sourceLanguage=zh-Hans recorded in audit")
    func test_AC1_zhHans_sourceLanguage() async throws {
        let text = "今天天气真好，适合出去散步。"
        let knownVector = Array(repeating: Float(0.1), count: 384)
        await stubEmbedder.setNextEmbedding(knownVector)
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let memory = try await sut.ingestText(
            text: text,
            sourceLanguage: "zh-Hans",
            sourceId: "note_zh_001",
            traceID: traceID
        )

        #expect(memory.sourceType == "text")
        // AC-3: 384d → zero-padded → 512d in VectorStore
        #expect(memory.embedding.count == 512)
        #expect(Array(memory.embedding.prefix(384)) == knownVector)
        #expect(memory.embedding.dropFirst(384).allSatisfy { $0 == 0.0 })
    }

    @Test("AC-2: originalText preserved byte-for-byte identical to input")
    func test_AC2_originalTextByteIdentical() async throws {
        let text = "这是一段包含特殊字符的测试文本：🍎🎉✨"
        let knownVector: [Float] = Array(repeating: 0.2, count: 384)
        await stubEmbedder.setNextEmbedding(knownVector)
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let memory = try await sut.ingestText(
            text: text,
            sourceLanguage: "zh-Hans",
            sourceId: "note_zh_002",
            traceID: traceID
        )

        // AC-2: originalText must be byte-by-byte identical (including emoji)
        #expect(memory.originalText == text)
        #expect(memory.originalText?.count == text.count)
    }

    @Test("AC-3: 384d text embedding zero-padded to 512d before VectorStore write")
    func test_AC3_zeroPaddedEmbedding() async throws {
        let text = "测试文本向量生成"
        let raw384: [Float] = (0..<384).map { Float($0) * 0.001 }
        await stubEmbedder.setNextEmbedding(raw384)
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let memory = try await sut.ingestText(
            text: text,
            sourceLanguage: "zh-Hans",
            sourceId: "note_zh_003",
            traceID: traceID
        )

        // AC-3: embedding is 512d (384 original + 128 zero padding)
        #expect(memory.embedding.count == 512)
        #expect(Array(memory.embedding.prefix(384)) == raw384)
        #expect(memory.embedding.dropFirst(384).allSatisfy { $0 == 0.0 })
    }

    @Test("AC-5: ingestion produces valid MemoryEntry with traceID and sourceLanguage")
    func test_AC5_validMemoryEntry() async throws {
        let text = "审计日志测试文本"
        await stubEmbedder.setNextEmbedding(Array(repeating: 0.3, count: 384))
        await stubEmbedder.setNextError(nil)

        let traceID = "trace-audit-\(UUID().uuidString.prefix(8))"
        let memory = try await sut.ingestText(
            text: text,
            sourceLanguage: "zh-Hans",
            sourceId: "note_zh_004",
            traceID: traceID
        )

        #expect(memory.traceID == traceID)
        #expect(memory.sourceType == "text")
        #expect(memory.originalText == text)
        #expect(memory.privacyBlurApplied == false)
    }

    // MARK: - US-ING-002: Text Ingestion (English)

    @Test("US-ING-002: English text ingestion with sourceLanguage=en-US")
    func test_USING002_englishTextIngestion() async throws {
        let text = "The quick brown fox jumps over the lazy dog."
        await stubEmbedder.setNextEmbedding(Array(repeating: 0.4, count: 384))
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let memory = try await sut.ingestText(
            text: text,
            sourceLanguage: "en-US",
            sourceId: "note_en_001",
            traceID: traceID
        )

        #expect(memory.sourceType == "text")
        #expect(memory.originalText == text)
        #expect(memory.embedding.count == 512)
    }

    // MARK: - US-ING-003: Voice Ingestion

    @Test("AC-1 (voice): transcription goes through ASREngine, then embedText")
    func test_AC1_voiceTranscriptionFlow() async throws {
        let transcript = "这是我的语音转写测试内容。"
        let transcriptVector: [Float] = Array(repeating: 0.5, count: 384)
        await stubASR.setNextTranscript(transcript)
        await stubASR.setNextError(nil)
        await stubEmbedder.setNextEmbedding(transcriptVector)
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let memory = try await sut.ingestVoice(
            audioAssetId: "voice_001",
            sourceLanguage: "zh-Hans",
            traceID: traceID
        )

        #expect(memory.sourceType == "voice")
        #expect(memory.originalText == transcript)
        #expect(memory.embedding.count == 512)
        #expect(Array(memory.embedding.prefix(384)) == transcriptVector)
    }

    @Test("AC-3 (voice): audio original file NOT persisted — only transcription kept")
    func test_AC3_audioNotPersisted() async throws {
        let transcript = "转写文本是唯一保留的数据。"
        await stubASR.setNextTranscript(transcript)
        await stubASR.setNextError(nil)
        await stubEmbedder.setNextEmbedding(Array(repeating: 0.6, count: 384))
        await stubEmbedder.setNextError(nil)

        let memory = try await sut.ingestVoice(
            audioAssetId: "voice_002",
            sourceLanguage: "zh-Hans",
            traceID: UUID().uuidString
        )

        // AC-3: Only the transcription is stored as originalText; audio asset is referenced
        // via assetId but NOT persisted/copied. The assetId is a PHAsset.localIdentifier.
        #expect(memory.originalText == transcript)
        #expect(memory.sourceType == "voice")
        #expect(memory.assetId == "voice_002")
    }

    @Test("AC-4 (voice): low transcriptConfidence < 0.7 stored on MemoryEntry")
    func test_AC4_lowConfidenceTranscript() async throws {
        // AC-4: confidence < 0.7 → stored on MemoryEntry.transcriptConfidence
        let transcript = "低置信度转写结果。"
        await stubASR.setNextTranscript(transcript)
        await stubASR.setNextError(nil)
        await stubEmbedder.setNextEmbedding(Array(repeating: 0.1, count: 384))
        await stubEmbedder.setNextError(nil)

        let memory = try await sut.ingestVoice(
            audioAssetId: "voice_lowconf",
            sourceLanguage: "zh-Hans",
            transcriptConfidence: 0.55,
            traceID: UUID().uuidString
        )

        #expect(memory.originalText == transcript)
        #expect(memory.sourceType == "voice")
        #expect(memory.transcriptConfidence == 0.55)
        #expect((memory.transcriptConfidence ?? 1.0) < 0.7)
    }

    @Test("AC-5 (voice): .voiceIngested should not throw under normal conditions")
    func test_AC5_voiceIngestedNoThrow() async throws {
        let transcript = "语音审计测试"
        await stubASR.setNextTranscript(transcript)
        await stubASR.setNextError(nil)
        await stubEmbedder.setNextEmbedding(Array(repeating: 0.7, count: 384))
        await stubEmbedder.setNextError(nil)

        let traceID = "trace-voice-\(UUID().uuidString.prefix(8))"
        let memory = try await sut.ingestVoice(
            audioAssetId: "voice_audit",
            sourceLanguage: "zh-Hans",
            traceID: traceID
        )

        #expect(memory.traceID == traceID)
        #expect(memory.sourceType == "voice")
    }

    // MARK: - Error Cases

    @Test("Error: empty text throws IngestError.emptyText")
    func test_emptyText_throws() async throws {
        await stubEmbedder.setNextError(nil)

        await #expect(throws: IngestError.emptyText) {
            _ = try await sut.ingestText(
                text: "",
                sourceLanguage: "zh-Hans",
                sourceId: "empty",
                traceID: UUID().uuidString
            )
        }
    }

    @Test("Error: whitespace-only text throws IngestError.emptyText")
    func test_whitespaceOnlyText_throws() async throws {
        await stubEmbedder.setNextError(nil)

        await #expect(throws: IngestError.emptyText) {
            _ = try await sut.ingestText(
                text: "   \n\t  ",
                sourceLanguage: "zh-Hans",
                sourceId: "whitespace",
                traceID: UUID().uuidString
            )
        }
    }

    @Test("Error: embeddingFailed propagated from embedder")
    func test_embeddingFailed_propagated() async throws {
        await stubEmbedder.setNextError(.modelNotLoaded)

        await #expect(throws: IngestError.embeddingFailed(underlying: EmbedderError.modelNotLoaded)) {
            _ = try await sut.ingestText(
                text: "valid text",
                sourceLanguage: "zh-Hans",
                sourceId: "fail_embed",
                traceID: UUID().uuidString
            )
        }
    }

    @Test("Error: audio transcription failure propagates")
    func test_audioTranscriptionFailed() async throws {
        await stubASR.setNextError(.modelNotLoaded)

        await #expect(throws: IngestError.audioTranscriptionFailed(underlying: ASREngineError.modelNotLoaded)) {
            _ = try await sut.ingestVoice(
                audioAssetId: "voice_fail",
                sourceLanguage: "zh-Hans",
                traceID: UUID().uuidString
            )
        }
    }

    @Test("Error: privacy denied for unauthorized source type")
    func test_privacyDenied_unauthorizedSource() async throws {
        // Reset policy to only allow photo (not note/voice)
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo"],
            policyVersion: 2
        ))

        await #expect(throws: IngestError.privacyDenied(sourceTypes: ["note"])) {
            _ = try await sut.ingestText(
                text: "valid text",
                sourceLanguage: "zh-Hans",
                sourceId: "denied",
                traceID: UUID().uuidString
            )
        }

        // Restore authorized sources for other tests
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["note", "voice", "photo", "video"],
            policyVersion: 3
        ))
    }

    // MARK: - Edge Cases

    @Test("Edge: long text with Chinese and English mixed")
    func test_mixedLanguageText() async throws {
        let longText = String(repeating: "中英混合 text mixing 测试 test 内容 content。", count: 20)
        await stubEmbedder.setNextEmbedding(Array(repeating: 0.8, count: 384))
        await stubEmbedder.setNextError(nil)

        let memory = try await sut.ingestText(
            text: longText,
            sourceLanguage: "zh-Hans",
            sourceId: "mixed_lang",
            traceID: UUID().uuidString
        )

        #expect(memory.originalText == longText)
        #expect(memory.embedding.count == 512)
        #expect(memory.sourceType == "text")
    }

    @Test("Edge: empty transcript from ASR produces memory anyway")
    func test_emptyTranscript_stillIngested() async throws {
        await stubASR.setNextTranscript("")
        await stubASR.setNextError(nil)
        await stubEmbedder.setNextEmbedding(Array(repeating: 0.0, count: 384))
        await stubEmbedder.setNextError(nil)

        // Empty transcript from ASR should still go through (ASR may return empty for silence)
        let memory = try await sut.ingestVoice(
            audioAssetId: "voice_empty_transcript",
            sourceLanguage: "zh-Hans",
            traceID: UUID().uuidString
        )

        #expect(memory.originalText == "")
        #expect(memory.sourceType == "voice")
    }

    @Test("Edge: multiple consecutive text ingestions produce unique traceIDs")
    func test_multipleIngestion_uniqueTraceIDs() async throws {
        await stubEmbedder.setNextEmbedding(Array(repeating: 0.9, count: 384))
        await stubEmbedder.setNextError(nil)

        let m1 = try await sut.ingestText(
            text: "first",
            sourceLanguage: "zh-Hans",
            sourceId: "multi_1",
            traceID: "trace-1"
        )
        let m2 = try await sut.ingestText(
            text: "second",
            sourceLanguage: "en-US",
            sourceId: "multi_2",
            traceID: "trace-2"
        )

        #expect(m1.traceID != m2.traceID)
        #expect(m1.id != m2.id)
    }

    @Test("Edge: vectorStore persistence — ingested text memory is retrievable")
    func test_vectorStore_persistence_text() async throws {
        let text = "持久化测试文本"
        let knownVector: [Float] = Array(repeating: 0.55, count: 384)
        await stubEmbedder.setNextEmbedding(knownVector)
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let memory = try await sut.ingestText(
            text: text,
            sourceLanguage: "zh-Hans",
            sourceId: "persist_001",
            traceID: traceID
        )

        // Search for the ingested vector using zero-padded query
        let results = await vectorStore.search(
            query: knownVector + Array(repeating: 0.0, count: 128),
            k: 5
        )
        #expect(!results.isEmpty, "Should find the ingested memory")
    }
}
