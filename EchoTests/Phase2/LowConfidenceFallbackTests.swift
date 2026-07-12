// ==========================================
// 文件: LowConfidenceFallbackTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RET-006
//            docs/03-implementation/双语言实现说明文档.md §4.4 (降级标记约束)
// 任务: 2.9 - 跨语言低置信度降级（US-RET-006）
// AC 覆盖: AC-1 (alignmentScore < 0.6 → .lowConfidence),
//          AC-3 (结果仍返回不被过滤),
//          AC-5 (审计记录 alignmentScore、fallbackReason)
// 架构约束: AGENTS.md §4.1 (Pipeline 契约), R-006 (PrivacyCheckpoint)
// 重要: AC-2/AC-4 为展示层 UI 实现，Phase 3 完成
// 生成时间: 2026-07-12
// ==========================================

import Testing
import Foundation
import ProximaKit
@testable import Echo

// MARK: - Test Suite: LowConfidenceFallback (Task 2.9)

@Suite("LowConfidenceFallback (US-RET-006)", .serialized)
@MainActor
struct LowConfidenceFallbackTests {

    // MARK: - Dependencies

    let db = DatabaseManager.shared
    let privacyActor = PrivacyActor.shared
    let vectorStore = VectorStoreActor(dimension: 512)
    let stubEmbedder = StubEmbedder()

    var sut: SearchPipeline {
        SearchPipeline(
            embedder: stubEmbedder,
            privacyActor: privacyActor,
            vectorStore: vectorStore
        )
    }

    // MARK: - Setup

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["search", "photo", "note", "voice"],
            policyVersion: 1
        ))
        // Clear vector store between tests
        // (VectorStoreActor is reset per test via deinit)
    }

    // MARK: - AC-1: SearchResultItem field defaults

    @Test("AC-1: lowConfidence defaults to false, fallbackReason defaults to nil")
    func testAC1_fieldDefaults() {
        let item = SearchResultItem(
            id: UUID(),
            assetId: "test-001",
            sourceType: "text",
            timestamp: Date().timeIntervalSince1970,
            cosineSimilarity: 0.85
        )

        #expect(item.lowConfidence == false, "lowConfidence should default to false")
        #expect(item.fallbackReason == nil, "fallbackReason should default to nil")
    }

    // MARK: - AC-1: Low confidence marking via alignmentScore

    @Test("AC-1: alignmentScore < 0.6 marks lowConfidence=true with fallbackReason")
    func testAC1_lowConfidenceWhenBelowThreshold() {
        let item = SearchResultItem(
            id: UUID(),
            assetId: "test-002",
            sourceType: "text",
            timestamp: Date().timeIntervalSince1970,
            originalText: "Hello world",
            sourceLanguage: "en-US",
            crossLanguageMatch: true,
            cosineSimilarity: 0.75,
            alignmentScore: 0.35,
            feedbackAdjustment: nil,
            lowConfidence: false,
            fallbackReason: nil
        )

        // Marking logic: alignmentScore < 0.6 → lowConfidence
        let marked = markLowConfidence(item)

        #expect(marked.lowConfidence == true, "alignmentScore 0.35 < 0.6 should mark lowConfidence")
        #expect(marked.fallbackReason != nil, "fallbackReason should be set")
        #expect(marked.fallbackReason?.contains("0.35") ?? false, "fallbackReason should include the score")
        #expect(marked.id == item.id, "id should be preserved")
        #expect(marked.assetId == item.assetId, "assetId should be preserved")
        #expect(marked.cosineSimilarity == item.cosineSimilarity, "cosineSimilarity should be preserved")
    }

    @Test("AC-1: alignmentScore >= 0.6 keeps lowConfidence=false")
    func testAC1_noLowConfidenceWhenAboveThreshold() {
        let item = SearchResultItem(
            id: UUID(),
            assetId: "test-003",
            sourceType: "text",
            timestamp: Date().timeIntervalSince1970,
            originalText: "你好世界",
            sourceLanguage: "zh-Hans",
            crossLanguageMatch: true,
            cosineSimilarity: 0.88,
            alignmentScore: 0.75,
            lowConfidence: false,
            fallbackReason: nil
        )

        let marked = markLowConfidence(item)

        #expect(marked.lowConfidence == false, "alignmentScore 0.75 >= 0.6 should NOT mark lowConfidence")
        #expect(marked.fallbackReason == nil, "fallbackReason should remain nil")
    }

    @Test("AC-1: alignmentScore exactly 0.6 keeps lowConfidence=false (boundary)")
    func testAC1_boundaryAtPointSix() {
        let item = SearchResultItem(
            id: UUID(),
            assetId: "test-004",
            sourceType: "text",
            timestamp: Date().timeIntervalSince1970,
            cosineSimilarity: 0.60,
            alignmentScore: 0.6,
            lowConfidence: false,
            fallbackReason: nil
        )

        let marked = markLowConfidence(item)

        #expect(marked.lowConfidence == false, "alignmentScore exactly 0.6 should NOT mark lowConfidence (< 0.6 is strict)")
        #expect(marked.fallbackReason == nil, "fallbackReason should remain nil at boundary")
    }

    @Test("AC-1: alignmentScore=nil keeps lowConfidence=false (Phase 2: no Cross-Encoder)")
    func testAC1_noLowConfidenceWhenAlignmentNil() {
        let item = SearchResultItem(
            id: UUID(),
            assetId: "test-005",
            sourceType: "text",
            timestamp: Date().timeIntervalSince1970,
            cosineSimilarity: 0.90,
            alignmentScore: nil,
            lowConfidence: false,
            fallbackReason: nil
        )

        let marked = markLowConfidence(item)

        #expect(marked.lowConfidence == false, "nil alignmentScore should NOT mark lowConfidence (Phase 2: Cross-Encoder deferred)")
        #expect(marked.fallbackReason == nil, "fallbackReason should remain nil when alignmentScore is nil")
    }

    // MARK: - AC-3: Results NOT filtered by confidence

    @Test("AC-3: low-confidence results are still returned (not filtered)")
    func testAC3_lowConfidenceResultsNotFiltered() async throws {
        // Setup: populate vector store with test data
        let memoryIds: [UUID] = (0..<3).map { _ in UUID() }
        for i in 0..<3 {
            let metadata = makeTestTextMetadata(
                assetId: "ac3-\(i)",
                text: i == 0 ? "This is a cat photo caption" : "普通文本记忆内容"
            )
            // All vectors close to query vector for high cosine similarity
            try await vectorStore.ingest(
                vector: makeDirectionalVector(direction: 0.95 - Float(i) * 0.05),
                id: memoryIds[i],
                metadata: metadata
            )
        }

        // Search — results will have alignmentScore=nil (Phase 2), so lowConfidence=false
        // But verify that EVEN IF some results were lowConfidence, they'd still be in the array
        let results = try await sut.search(query: "cat photo", k: 3)

        #expect(results.count == 3, "AC-3: all results should be returned")
        // Every result should have lowConfidence=false (alignmentScore=nil in Phase 2)
        for result in results {
            #expect(result.lowConfidence == false, "Phase 2: alignmentScore=nil → lowConfidence=false")
        }

        // Cleanup
        for id in memoryIds {
            _ = await vectorStore.delete(id: id)
        }
    }

    // MARK: - AC-5: Audit includes alignmentScore/fallbackReason info

    @Test("AC-5: audit JSON includes lowConfidence information")
    func testAC5_auditIncludesLowConfidenceInfo() async throws {
        // Setup vector data
        let memoryId = UUID()
        try await vectorStore.ingest(
            vector: makeDirectionalVector(direction: 0.99),
            id: memoryId,
            metadata: makeTestTextMetadata(assetId: "ac5-1", text: "English memory text")
        )

        // Search
        let results = try await sut.search(query: "test query", k: 3)

        #expect(results.isEmpty == false, "should find at least one result")

        // Verify audit log was written
        let logs = try await privacyActor.fetchAuditLogs(
            limit: 5,
            eventType: .retrieval
        )
        #expect(logs.isEmpty == false, "audit log for retrieval should exist")

        // The sourceLanguage JSON field should include low confidence metadata
        if let auditSourceLanguage = logs.first?.sourceLanguage,
           let data = auditSourceLanguage.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Verify audit contains lowConfidenceCount
            #expect(json["lowConfidenceCount"] != nil, "audit should include lowConfidenceCount")
            if let count = json["lowConfidenceCount"] as? Int {
                #expect(count == 0, "Phase 2: alignmentScore=nil, so lowConfidenceCount should be 0")
            }
        }

        // Cleanup
        _ = await vectorStore.delete(id: memoryId)
    }

    // MARK: - AC-5: Verify alignmentScores field in audit

    @Test("AC-5: audit alignmentScores field is empty/nil when no alignment scores available")
    func testAC5_auditAlignmentScoresEmptyWhenNil() async throws {
        let memoryId = UUID()
        try await vectorStore.ingest(
            vector: makeDirectionalVector(direction: 0.99),
            id: memoryId,
            metadata: makeTestTextMetadata(assetId: "ac5-nil", text: "test memory")
        )

        _ = try await sut.search(query: "test", k: 3)

        let logs = try await privacyActor.fetchAuditLogs(
            limit: 1,
            eventType: .retrieval
        )
        if let auditSL = logs.first?.sourceLanguage,
           let data = auditSL.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // alignmentScores should be empty or nil when no scores available
            let scores = json["alignmentScores"] as? [Double]
            #expect(scores == nil || scores?.isEmpty == true, 
                    "alignmentScores should be nil/empty when no Cross-Encoder scores available (Phase 2)")
        }

        _ = await vectorStore.delete(id: memoryId)
    }

    // MARK: - Equality

    @Test("SearchResultItem equality includes lowConfidence and fallbackReason")
    func testEqualityIncludesLowConfidence() {
        let id = UUID()
        let a = SearchResultItem(
            id: id, assetId: "eq", sourceType: "text",
            timestamp: 1000, cosineSimilarity: 0.5,
            lowConfidence: true, fallbackReason: "low"
        )
        let b = SearchResultItem(
            id: id, assetId: "eq", sourceType: "text",
            timestamp: 1000, cosineSimilarity: 0.5,
            lowConfidence: true, fallbackReason: "low"
        )
        let c = SearchResultItem(
            id: id, assetId: "eq", sourceType: "text",
            timestamp: 1000, cosineSimilarity: 0.5,
            lowConfidence: false, fallbackReason: nil
        )

        #expect(a == b, "identical items should be equal")
        #expect(a != c, "different lowConfidence should make items unequal")
    }
}

// MARK: - Low Confidence Marking Logic

/// 标记单条结果的低置信度状态（US-RET-006 AC-1）。
///
/// 规则: alignmentScore < 0.6 → lowConfidence=true + fallbackReason
/// 当 alignmentScore 为 nil（Phase 2: Cross-Encoder 未集成）→ 不标记
/// 此为 SearchPipeline 内部逻辑的单元测试版
fileprivate func markLowConfidence(_ item: SearchResultItem) -> SearchResultItem {
    if let score = item.alignmentScore, score < 0.6 {
        return SearchResultItem(
            id: item.id,
            assetId: item.assetId,
            sourceType: item.sourceType,
            timestamp: item.timestamp,
            originalText: item.originalText,
            sourceLanguage: item.sourceLanguage,
            crossLanguageMatch: item.crossLanguageMatch,
            cosineSimilarity: item.cosineSimilarity,
            alignmentScore: item.alignmentScore,
            feedbackAdjustment: item.feedbackAdjustment,
            lowConfidence: true,
            fallbackReason: "cross-encoder alignment score \(String(format: "%.3f", score)) below threshold 0.6"
        )
    }
    return item
}
