// ==========================================
// 文件: R3_PureFunctionTests.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-3
// 任务: R-3 纯函数单元测试（rrfFuse, characterNgrams, l2Normalize, hasSpeech）
// AC 覆盖: R-3.7 RRF 融合公式、R-3.6 字符 n-gram、R-3.1 L2 归一化、R-3.3 VAD
// 架构约束: AGENTS.md §9.1 (覆盖率 ≥95%), §13.2 (TDD)
// 生成时间: 2026-08-01
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - R-3.7: RRF Fusion

@Suite("R-3.7 RRF Fusion", .serialized)
@MainActor
struct RRFFusionTests {

    /// 构造一个最小 SearchPipeline 实例用于测试 rrfFuse（nonisolated 方法）。
    private func makePipeline() -> SearchPipeline {
        SearchPipeline(
            embedder: StubEmbedder(),
            vectorStore: VectorStoreActor(dimension: 512)
        )
    }

    @Test("rrfFuse merges single channel rankings correctly")
    func test_rrfFuse_singleChannel() {
        let pipeline = makePipeline()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        let results = [
            SearchPipeline.ChannelResult(channel: "text_dense", rankedIds: [id1, id2, id3])
        ]

        let fused = pipeline.rrfFuse(channelResults: results, k: 3)
        // Single channel: order preserved (rank 1 > rank 2 > rank 3)
        #expect(fused.count == 3)
        #expect(fused[0] == id1)
        #expect(fused[1] == id2)
        #expect(fused[2] == id3)
    }

    @Test("rrfFuse promotes docs appearing in multiple channels")
    func test_rrfFuse_multiChannel_promotion() {
        let pipeline = makePipeline()
        let idA = UUID()  // appears in both channels
        let idB = UUID()  // only in text_dense
        let idC = UUID()  // only in lexical

        let results = [
            SearchPipeline.ChannelResult(channel: "text_dense", rankedIds: [idB, idA]),
            SearchPipeline.ChannelResult(channel: "lexical", rankedIds: [idC, idA]),
        ]

        let fused = pipeline.rrfFuse(channelResults: results, k: 3)
        // idA appears in both channels → highest RRF score → ranked first
        #expect(fused[0] == idA, "Doc in multiple channels should rank first")
        #expect(fused.count == 3)
    }

    @Test("rrfFuse respects k limit")
    func test_rrfFuse_kLimit() {
        let pipeline = makePipeline()
        let ids = (0..<10).map { _ in UUID() }
        let results = [
            SearchPipeline.ChannelResult(channel: "text_dense", rankedIds: ids)
        ]
        let fused = pipeline.rrfFuse(channelResults: results, k: 5)
        #expect(fused.count == 5)
    }

    @Test("rrfFuse empty channels returns empty")
    func test_rrfFuse_empty() {
        let pipeline = makePipeline()
        let fused = pipeline.rrfFuse(channelResults: [], k: 10)
        #expect(fused.isEmpty)
    }
}

// MARK: - R-3.1: L2 Normalization

@Suite("R-3.1 L2 Normalization", .serialized)
@MainActor
struct L2NormalizeTests {

    @Test("l2Normalize produces unit vector")
    func test_l2Normalize_unitVector() {
        let input: [Float] = [3.0, 4.0]
        let result = E5Embedder.l2Normalize(input)
        // ||[3,4]|| = 5, so [3/5, 4/5] = [0.6, 0.8]
        #expect(abs(result[0] - 0.6) < 0.001)
        #expect(abs(result[1] - 0.8) < 0.001)
        // Verify unit length
        let norm = sqrt(result.reduce(0) { $0 + $1 * $1 })
        #expect(abs(norm - 1.0) < 0.001)
    }

    @Test("l2Normalize handles zero vector")
    func test_l2Normalize_zeroVector() {
        let input: [Float] = [0.0, 0.0, 0.0]
        let result = E5Embedder.l2Normalize(input)
        // Zero vector returned unchanged (no division by zero)
        #expect(result == input)
    }

    @Test("l2Normalize preserves dimension")
    func test_l2Normalize_dimension() {
        let input = Array(repeating: Float(1.0), count: 384)
        let result = E5Embedder.l2Normalize(input)
        #expect(result.count == 384)
    }
}

// MARK: - R-3.6: Character N-grams

@Suite("R-3.6 Character N-grams", .serialized)
@MainActor
struct CharacterNgramTests {

    private func makeEngine() -> LexicalEngine {
        LexicalEngine()
    }

    @Test("characterNgrams produces bigrams and trigrams")
    func test_ngrams_bigramTrigram() {
        let engine = makeEngine()
        let ngrams = engine.characterNgrams("北京旅游")
        // Bigrams: 北京, 京旅, 旅游
        // Trigrams: 北京旅, 京旅游
        #expect(ngrams.contains("北京"))
        #expect(ngrams.contains("京旅"))
        #expect(ngrams.contains("旅游"))
        #expect(ngrams.contains("北京旅"))
        #expect(ngrams.contains("京旅游"))
    }

    @Test("characterNgrams deduplicates")
    func test_ngrams_dedup() {
        let engine = makeEngine()
        let ngrams = engine.characterNgrams("aaaa")
        // Bigram "aa" appears 3 times but should be deduplicated
        let aaCount = ngrams.filter { $0 == "aa" }.count
        #expect(aaCount == 1, "N-grams should be deduplicated")
    }

    @Test("characterNgrams handles short text")
    func test_ngrams_shortText() {
        let engine = makeEngine()
        // Single char: no bigrams or trigrams possible
        let ngrams = engine.characterNgrams("a")
        #expect(ngrams.isEmpty)
    }

    @Test("tokenize falls back to characterNgrams")
    func test_tokenize_fallback() {
        let engine = makeEngine()
        let tokens = engine.tokenize("北京")
        // Without jieba, falls back to character n-grams
        #expect(tokens.contains("北京"))
    }
}

// MARK: - R-3.3: VAD (Voice Activity Detection)

@Suite("R-3.3 VAD", .serialized)
@MainActor
struct VADTests {

    private func makeEngine() -> WhisperASREngine {
        WhisperASREngine()
    }

    @Test("hasSpeech detects silence")
    func test_hasSpeech_silence() {
        let engine = makeEngine()
        let silence = Array(repeating: Float(0.0), count: 16000)
        #expect(engine.hasSpeech(silence) == false)
    }

    @Test("hasSpeech detects speech energy")
    func test_hasSpeech_speech() {
        let engine = makeEngine()
        // Simulate continuous speech: sine wave with amplitude 0.5
        // Average energy of sin² = 0.5 × amplitude² = 0.125 > threshold 0.01
        let speech = (0..<16000).map { i -> Float in
            0.5 * sin(Float(i) * 0.1)
        }
        #expect(engine.hasSpeech(speech) == true)
    }

    @Test("hasSpeech handles empty array")
    func test_hasSpeech_empty() {
        let engine = makeEngine()
        #expect(engine.hasSpeech([]) == false)
    }
}
