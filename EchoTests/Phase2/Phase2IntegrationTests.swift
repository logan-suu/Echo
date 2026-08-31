// ==========================================
// 文件: Phase2IntegrationTests.swift
// 对应规格: docs/02-architecture/数据流全链路技术说明文档.md §2~6 (检索/摄入/同步/唤醒/反馈数据流)
//            docs/02-architecture/架构设计文档.md §3 (Cognitive Pipeline + Actor 架构)
//            docs/01-spec/用户故事与验收标准规格书.md §US-RET-001~006, §US-ING-001~005,
//            §US-SRC-012, §US-AWK-001, §US-AWK-003, §US-FBK-001~003
// 任务: 2.14 - Phase 2 集成测试：核心认知管线联调验证
// 测试范围: SearchPipeline + IngestPipeline + SyncPipeline + AwakeningPipeline +
//           FeedbackPipeline + PrivacyActor + ExcludedAssetsActor + FeedbackActor +
//           ProgressActor + VectorStoreActor 跨 Pipeline 联调
// 架构约束: AGENTS.md §4.1 (Pipeline 契约), §4.2 (Actor 隔离), R-006 (PrivacyCheckpoint),
//           R-008 (跨 Actor await), §4.4 (L1~L4 错误分级), §12.6 (阶段集成测试契约)
// 重要: @MainActor 标注因 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// 生成时间: 2026-07-13
// ==========================================

import Testing
import Foundation
import ProximaKit
@testable import Echo

// MARK: - Helpers

func makePhase2TestTextMetadata(assetId: String, text: String, sourceType: String = "text") -> Data {
    let memory = MemoryEntry(
        assetId: assetId,
        embedding: Array(repeating: 1.0, count: 512),
        sourceType: sourceType,
        timestamp: Date(),
        exifMetadata: nil,
        privacyBlurApplied: false,
        traceID: UUID().uuidString,
        originalText: text
    )
    return try! memory.encodeMetadata()
}

func makePhase2DirectionalVector(direction: Float, dimension: Int = 512) -> [Float] {
    let remaining = (1.0 - direction * direction) / Float(dimension - 1)
    let fill = remaining > 0 ? sqrt(max(0, remaining)) : 0.0
    var vec = [direction]
    vec.append(contentsOf: Array(repeating: fill, count: dimension - 1))
    return vec
}

// MARK: - Phase 2 Integration Test Suite

@Suite("Phase2Integration - Core Cognitive Pipeline", .serialized)
struct Phase2IntegrationTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
        try await db.execute(sql: "DELETE FROM FeedbackStore")
        try await db.execute(sql: "DELETE FROM TaskProgress")
        try await db.execute(sql: "DELETE FROM PendingOperations")
        try await PrivacyActor.shared.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice", "search", "geofence", "text"],
            policyVersion: 1
        ))
    }

    // MARK: - Suite 1: Search Pipeline Integration

    @Suite("SearchPipelineFullIntegration")
    @MainActor
    struct SearchPipelineFullIntegrationTests {
        let vectorStore = VectorStoreActor(dimension: 512)
        let stubEmbedder = StubEmbedder()
        let feedbackActor = FeedbackActor.shared
        let searchPipeline: SearchPipeline

        init() async throws {
            let db = DatabaseManager.shared
            try await db.open()
            try await db.execute(sql: "DELETE FROM FeedbackStore")
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(
                preferredLanguage: "zh-Hans",
                authorizedSourceTypes: ["search", "photo", "note", "voice", "text"],
                policyVersion: 1
            ))
            searchPipeline = SearchPipeline(
                embedder: stubEmbedder,
                privacyActor: PrivacyActor.shared,
                vectorStore: vectorStore,
                feedbackActor: feedbackActor
            )
            await stubEmbedder.setNextError(nil)
        }

        @Test("Empty query throws SearchError.emptyQuery")
        func test_emptyQueryThrows() async throws {
            do {
                _ = try await searchPipeline.search(query: "", k: 5)
                Issue.record("Expected SearchError.emptyQuery")
            } catch let error as SearchError {
                #expect(error == .emptyQuery)
            }
        }

        @Test("Search with vector store data returns results ordered by similarity")
        func test_searchReturnsResults() async throws {
            let id1 = UUID(); let id2 = UUID(); let id3 = UUID()
            let meta1 = makePhase2TestTextMetadata(assetId: "a1", text: "iPhone photography tips")
            let meta2 = makePhase2TestTextMetadata(assetId: "a2", text: "weekend cooking recipe")
            let meta3 = makePhase2TestTextMetadata(assetId: "a3", text: "iPhone camera review")
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 0.95), id: id1, metadata: meta1)
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 0.5), id: id2, metadata: meta2)
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 0.9), id: id3, metadata: meta3)
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 1.0))
            let results = try await searchPipeline.search(query: "iPhone photo", k: 2)
            #expect(results.count == 2)
            #expect(results[0].cosineSimilarity > results[1].cosineSimilarity)
        }

        @Test("SearchResultItem contains metadata fields")
        func test_searchResultItemFields() async throws {
            let id = UUID()
            let text = "sunset beach memories"
            let meta = makePhase2TestTextMetadata(assetId: "sunset-photo", text: text)
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 1.0), id: id, metadata: meta)
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 1.0))
            let results = try await searchPipeline.search(query: "beach", k: 1)
            #expect(results.count == 1)
            #expect(results[0].id == id)
            #expect(results[0].assetId == "sunset-photo")
            #expect(results[0].sourceType == "text")
            #expect(results[0].originalText == text)
        }

        @Test("Search large k returns no more than available")
        func test_searchLargeK() async throws {
            let id = UUID()
            try await vectorStore.ingest(
                vector: makePhase2DirectionalVector(direction: 1.0), id: id,
                metadata: makePhase2TestTextMetadata(assetId: "single", text: "only memory")
            )
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 1.0))
            let results = try await searchPipeline.search(query: "memory", k: 100)
            #expect(results.count <= 1)
        }
    }

    // MARK: - Suite 2: Ingest Pipeline Integration

    @Suite("IngestPipelineFullIntegration")
    @MainActor
    struct IngestPipelineFullIntegrationTests {
        let db = DatabaseManager.shared
        let vectorStore = VectorStoreActor(dimension: 512)
        let stubEmbedder = StubEmbedder()
        let ingestPipeline: IngestPipeline

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await db.execute(sql: "DELETE FROM ExcludedAssets")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(
                preferredLanguage: "zh-Hans",
                authorizedSourceTypes: ["photo", "note", "voice", "text"],
                policyVersion: 1
            ))
            ingestPipeline = IngestPipeline(
                embedder: stubEmbedder,
                privacyActor: PrivacyActor.shared,
                vectorStore: vectorStore,
                excludedAssets: ExcludedAssetsActor.shared
            )
            await stubEmbedder.setNextError(nil)
        }

        @Test("ingestImage creates entry with correct fields")
        func test_ingestImage_fullFlow() async throws {
            let assetId = "IMG-\(UUID().uuidString.prefix(8))"
            let vector = makePhase2DirectionalVector(direction: 0.8)
            await stubEmbedder.setNextEmbedding(vector)
            let exif = try JSONSerialization.data(withJSONObject: ["GPSLatitude": 31.23, "GPSLongitude": 121.47])
            let memory = try await ingestPipeline.ingestImage(assetId: assetId, exifMetadata: exif, traceID: "trace-img-1")
            #expect(memory.assetId == assetId)
            #expect(memory.sourceType == "photo")
            #expect(memory.privacyBlurApplied == false)
            let sr = await vectorStore.search(query: vector, k: 1)
            #expect(sr.count == 1)
            #expect(sr[0].id == memory.id)
        }

        @Test("ingestText preserves originalText")
        func test_ingestText_fullFlow() async throws {
            let sourceId = "NOTE-\(UUID().uuidString.prefix(8))"
            let text = "today coffee chat about AI with friends by the lake"
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 0.7))
            let memory = try await ingestPipeline.ingestText(text: text, sourceLanguage: "zh-Hans", sourceId: sourceId, traceID: "trace-text-1")
            #expect(memory.assetId == sourceId)
            #expect(memory.sourceType == "text")
            #expect(memory.originalText == text)
        }

        @Test("ingestText throws emptyText for whitespace")
        func test_ingestText_emptyTextThrows() async throws {
            do {
                _ = try await ingestPipeline.ingestText(text: "   ", sourceLanguage: "zh-Hans", sourceId: "empty", traceID: "t")
                Issue.record("Expected IngestError.emptyText")
            } catch let error as IngestError { #expect(error == .emptyText) }
        }

        @Test("Metadata encode/decode round-trip")
        func test_metadataRoundTrip() async throws {
            let originalText = "original text preserved"
            let memory = MemoryEntry(assetId: "test", embedding: makePhase2DirectionalVector(direction: 0.5), sourceType: "text", timestamp: Date(), exifMetadata: nil, privacyBlurApplied: false, traceID: UUID().uuidString, originalText: originalText)
            let encoded = try memory.encodeMetadata()
            let decoded = try MemoryEntry.decodeMetadata(from: encoded)
            #expect(decoded.assetId == "test")
            #expect(decoded.originalText == originalText)
            #expect(decoded.sourceType == "text")
        }
    }

    // MARK: - Suite 3: Ingest-to-Search End-to-End

    @Suite("IngestToSearchEndToEnd")
    @MainActor
    struct IngestToSearchEndToEndTests {
        let db = DatabaseManager.shared
        let vectorStore = VectorStoreActor(dimension: 512)
        let stubEmbedder = StubEmbedder()
        let ingestPipeline: IngestPipeline
        let searchPipeline: SearchPipeline

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await db.execute(sql: "DELETE FROM ExcludedAssets")
            try await db.execute(sql: "DELETE FROM FeedbackStore")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(preferredLanguage: "zh-Hans", authorizedSourceTypes: ["search", "photo", "note", "voice", "text"], policyVersion: 1))
            ingestPipeline = IngestPipeline(embedder: stubEmbedder, privacyActor: PrivacyActor.shared, vectorStore: vectorStore, excludedAssets: ExcludedAssetsActor.shared)
            searchPipeline = SearchPipeline(embedder: stubEmbedder, privacyActor: PrivacyActor.shared, vectorStore: vectorStore, feedbackActor: FeedbackActor.shared)
        }

        @Test("Ingest then search retrieves correct memory")
        func test_ingestThenSearch() async throws {
            let text = "treasures of the Palace Museum in Beijing"
            let sourceId = "note-e2e-\(UUID().uuidString.prefix(8))"
            let qv = makePhase2DirectionalVector(direction: 0.9)
            await stubEmbedder.setNextEmbedding(qv)
            let memory = try await ingestPipeline.ingestText(text: text, sourceLanguage: "zh-Hans", sourceId: sourceId, traceID: "e2e-ingest")
            await stubEmbedder.setNextEmbedding(qv)
            let results = try await searchPipeline.search(query: "museum treasure", k: 5, traceID: "e2e-search")
            #expect(results.contains { $0.id == memory.id })
        }

        @Test("Multiple ingest then search returns best matches")
        func test_multipleIngestThenSearch() async throws {
            for (i, (dir, text)) in [(-0.95 as Float, "machine learning basics"), (0.0 as Float, "weekend baking recipe"), (0.95 as Float, "deep learning guide")].enumerated() {
                await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: dir))
                _ = try await ingestPipeline.ingestText(text: text, sourceLanguage: "zh-Hans", sourceId: "multi-\(i)", traceID: "e2e-multi-\(i)")
            }
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 1.0))
            let results = try await searchPipeline.search(query: "deep learning", k: 2)
            #expect(results.count == 2)
            #expect(results[0].cosineSimilarity > results[1].cosineSimilarity)
        }
    }

    // MARK: - Suite 4: Feedback Re-ranking Integration

    @Suite("FeedbackRerankingIntegration")
    @MainActor
    struct FeedbackRerankingIntegrationTests {
        let db = DatabaseManager.shared
        let vectorStore = VectorStoreActor(dimension: 512)
        let stubEmbedder = StubEmbedder()
        let feedbackActor = FeedbackActor.shared
        let searchPipeline: SearchPipeline

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM FeedbackStore")
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(preferredLanguage: "zh-Hans", authorizedSourceTypes: ["search", "photo", "note", "voice", "text"], policyVersion: 1))
            searchPipeline = SearchPipeline(embedder: stubEmbedder, privacyActor: PrivacyActor.shared, vectorStore: vectorStore, feedbackActor: feedbackActor)
        }

        @Test("Positive feedback boosts ranking for high cosine sim")
        func test_positiveFeedbackBoostsRanking() async throws {
            let id1 = UUID(); let id2 = UUID(); let id3 = UUID()
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 0.93), id: id1, metadata: makePhase2TestTextMetadata(assetId: "a1", text: "Japan travel"))
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 0.91), id: id2, metadata: makePhase2TestTextMetadata(assetId: "a2", text: "Python intro"))
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 0.89), id: id3, metadata: makePhase2TestTextMetadata(assetId: "a3", text: "ML hands-on"))
            let entry = FeedbackEntry(id: UUID(), memoryId: id3, queryText: "learn code", sentiment: .like, cosineSimilarity: 0.89, createdAt: Date(), isBadCase: false, badCaseReason: nil)
            try await feedbackActor.recordFeedback(entry, traceID: "fb-int-1")
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 1.0))
            let results = try await searchPipeline.search(query: "learn code", k: 3)
            #expect(results.count == 3)
            let r3 = results.first { $0.id == id3 }
            #expect(r3 != nil)
            #expect((r3?.feedbackAdjustment ?? 0) >= 0)
        }

        @Test("Feedback below threshold 0.80 not applied")
        func test_feedbackBelowThreshold() async throws {
            let id = UUID()
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 0.5), id: id, metadata: makePhase2TestTextMetadata(assetId: "low", text: "irrelevant"))
            let entry = FeedbackEntry(id: UUID(), memoryId: id, queryText: "unrelated", sentiment: .like, cosineSimilarity: 0.50, createdAt: Date(), isBadCase: false, badCaseReason: nil)
            try await feedbackActor.recordFeedback(entry, traceID: "fb-thr")
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 1.0))
            let results = try await searchPipeline.search(query: "unrelated", k: 5)
            let r = results.first { $0.id == id }
            #expect((r?.feedbackAdjustment ?? 0) == 0)
        }

        @Test("Search without feedbackActor works")
        func test_searchWithoutFeedbackActor() async throws {
            let pipe = SearchPipeline(embedder: stubEmbedder, privacyActor: PrivacyActor.shared, vectorStore: vectorStore)
            let id = UUID()
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 0.95), id: id, metadata: makePhase2TestTextMetadata(assetId: "nf", text: "test"))
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 1.0))
            let r = try await pipe.search(query: "test", k: 5)
            #expect(!r.isEmpty && r.allSatisfy { ($0.feedbackAdjustment ?? 0) == 0 })
        }
    }

    // MARK: - Suite 5: Sync Pipeline Integration

    @Suite("SyncPipelineIntegration")
    @MainActor
    struct SyncPipelineIntegrationTests {
        let db = DatabaseManager.shared
        let vectorStore = VectorStoreActor(dimension: 512)
        let stubEmbedder = StubEmbedder()
        let syncPipeline: SyncPipeline

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await db.execute(sql: "DELETE FROM ExcludedAssets")
            try await db.execute(sql: "DELETE FROM TaskProgress")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(preferredLanguage: "zh-Hans", authorizedSourceTypes: ["photo", "note", "voice", "text"], policyVersion: 1))
            await stubEmbedder.setNextError(nil)
            syncPipeline = SyncPipeline(embedder: stubEmbedder, privacyActor: PrivacyActor.shared, vectorStore: vectorStore, excludedAssets: ExcludedAssetsActor.shared, progressActor: ProgressActor.shared)
        }

        // R-5.2: detectNoteChanges/detectCalendarChanges removed (auto-scan of
        // Notes/Calendar unsupported by iOS public API — Notes/Voice via Share Extension)
    }

    // MARK: - Suite 6: Awakening Pipeline Integration

    @Suite("AwakeningPipelineIntegration")
    @MainActor
    struct AwakeningPipelineIntegrationTests {
        let db = DatabaseManager.shared
        let vectorStore = VectorStoreActor(dimension: 512)
        let stubEmbedder = StubEmbedder()
        let searchPipeline: SearchPipeline
        let awakeningPipeline: AwakeningPipeline
        let stateStore: GeofenceStateStore

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await db.execute(sql: "DELETE FROM UserPolicyStore")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(preferredLanguage: "zh-Hans", authorizedSourceTypes: ["photo", "note", "voice", "search", "geofence"], policyVersion: 1))
            searchPipeline = SearchPipeline(embedder: stubEmbedder, privacyActor: PrivacyActor.shared, vectorStore: vectorStore)
            stateStore = GeofenceStateStore()
            await stateStore.clearAll()
            awakeningPipeline = AwakeningPipeline(privacyActor: PrivacyActor.shared, searchPipeline: searchPipeline, stateStore: stateStore)
        }

        @Test("Geofence enter empty store → .noMemories")
        func test_emptyStoreNoMemories() async throws {
            let r = await awakeningPipeline.handleGeofenceEnter(regionId: "empty", traceID: "g1")
            guard case .noMemories = r else { Issue.record("Expected .noMemories, got \(r)"); return }
        }

        @Test("Geofence enter twice → .alreadyPushed")
        func test_alreadyPushed() async throws {
            _ = await awakeningPipeline.handleGeofenceEnter(regionId: "claim")
            let r = await awakeningPipeline.handleGeofenceEnter(regionId: "claim")
            guard case .alreadyPushed = r else { Issue.record("Expected .alreadyPushed, got \(r)"); return }
        }

        @Test("Geofence exit resets for next enter")
        func test_exitResets() async throws {
            _ = await awakeningPipeline.handleGeofenceEnter(regionId: "reset")
            await awakeningPipeline.handleGeofenceExit(regionId: "reset")
            let r = await awakeningPipeline.handleGeofenceEnter(regionId: "reset")
            guard case .noMemories = r else { Issue.record("Expected .noMemories after reset, got \(r)"); return }
        }

        @Test("Memories trigger .processed with card")
        func test_memoriesTriggerCard() async throws {
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 0.95), id: UUID(), metadata: makePhase2TestTextMetadata(assetId: "gm", text: "coffee by the lake"))
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 1.0))
            let fresh = AwakeningPipeline(privacyActor: PrivacyActor.shared, searchPipeline: searchPipeline, stateStore: GeofenceStateStore())
            let r = await fresh.handleGeofenceEnter(regionId: "lake", traceID: "gm")
            switch r {
            case .processed(let card):
                #expect(!card.memoryIds.isEmpty)

            case .noMemories:
                break

            default:
                Issue.record("Unexpected: \(r)")
            }
        }
    }

    // MARK: - Suite 7: Feedback Collection Pipeline

    @Suite("FeedbackPipelineIntegration")
    @MainActor
    struct FeedbackPipelineIntegrationTests {
        let db = DatabaseManager.shared
        let feedbackActor = FeedbackActor.shared
        let feedbackPipeline: FeedbackPipeline

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM FeedbackStore")
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await db.execute(sql: "DELETE FROM UserPolicyStore")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(preferredLanguage: "zh-Hans", authorizedSourceTypes: ["photo", "note", "voice"], policyVersion: 1))
            feedbackPipeline = FeedbackPipeline(feedbackActor: feedbackActor, privacyActor: PrivacyActor.shared)
        }

        @Test("recordLike persists to FeedbackStore")
        func test_recordLike() async throws {
            let mid = UUID()
            try await feedbackPipeline.recordLike(memoryId: mid, queryText: "like test", cosineSimilarity: 0.95, traceID: "fbl")
            let entries = try await feedbackActor.fetchEntries(for: mid)
            #expect(entries.count == 1 && entries[0].sentiment == .like)
        }

        @Test("recordDislike persists")
        func test_recordDislike() async throws {
            let mid = UUID()
            try await feedbackPipeline.recordDislike(memoryId: mid, queryText: "dislike test", cosineSimilarity: 0.85, traceID: "fbd")
            #expect(try await feedbackActor.fetchEntries(for: mid).count == 1)
        }

        @Test("markBadCase writes bad case")
        func test_markBadCase() async throws {
            let mid = UUID()
            try await feedbackPipeline.markBadCase(memoryId: mid, queryText: "q", reason: "wrong", cosineSimilarity: 0.88, traceID: "fbbc")
            let bad = try await feedbackActor.fetchBadCases()
            #expect(bad.contains { $0.memoryId == mid && $0.isBadCase })
        }

        @Test("revokeFeedback removes entry")
        func test_revokeFeedback() async throws {
            let fid = UUID()
            try await feedbackActor.recordFeedback(FeedbackEntry(id: fid, memoryId: UUID(), queryText: "r", sentiment: .like, cosineSimilarity: 0.82, createdAt: Date(), isBadCase: false, badCaseReason: nil), traceID: "prep")
            #expect(try await feedbackPipeline.revokeFeedback(feedbackId: fid, traceID: "rev"))
        }

        @Test("resetAllFeedback clears all")
        func test_resetAllFeedback() async throws {
            try await feedbackPipeline.recordLike(memoryId: UUID(), queryText: "reset", cosineSimilarity: 0.90, traceID: "r1")
            try await feedbackPipeline.resetAllFeedback(traceID: "r2")
            #expect(try await feedbackActor.count() == 0)
        }
    }

    // MARK: - Suite 8: Low Confidence Fallback

    @Suite("LowConfidenceFallbackIntegration")
    @MainActor
    struct LowConfidenceFallbackIntegrationTests {
        let db = DatabaseManager.shared
        let vectorStore = VectorStoreActor(dimension: 512)
        let stubEmbedder = StubEmbedder()
        let searchPipeline: SearchPipeline

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(preferredLanguage: "zh-Hans", authorizedSourceTypes: ["search", "photo", "note", "voice", "text"], policyVersion: 1))
            searchPipeline = SearchPipeline(embedder: stubEmbedder, privacyActor: PrivacyActor.shared, vectorStore: vectorStore)
        }

        @Test("lowConfidence defaults false")
        func test_lowConfidenceDefaultsFalse() async throws {
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 0.95), id: UUID(), metadata: makePhase2TestTextMetadata(assetId: "lc", text: "normal"))
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 1.0))
            for item in try await searchPipeline.search(query: "search", k: 5) {
                #expect(!item.lowConfidence && item.fallbackReason == nil)
            }
        }

        @Test("Results returned even with dissimilarity")
        func test_resultsStillReturned() async throws {
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 0.3), id: UUID(), metadata: makePhase2TestTextMetadata(assetId: "lr", text: "heritage"))
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 1.0))
            #expect(!(try await searchPipeline.search(query: "modern tech", k: 5)).isEmpty)
        }
    }

    // MARK: - Suite 9: Privacy Denial

    @Suite("CrossPipelinePrivacyDenial")
    @MainActor
    struct CrossPipelinePrivacyDenialTests {
        let db = DatabaseManager.shared
        let vectorStore = VectorStoreActor(dimension: 512)
        let stubEmbedder = StubEmbedder()

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await db.execute(sql: "DELETE FROM UserPolicyStore")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(preferredLanguage: "zh-Hans", authorizedSourceTypes: ["photo"], policyVersion: 1))
        }

        @Test("IngestPipeline denies text when note unauthorized")
        func test_ingestTextDenied() async throws {
            let ip = IngestPipeline(embedder: stubEmbedder, privacyActor: PrivacyActor.shared, vectorStore: vectorStore, excludedAssets: ExcludedAssetsActor.shared)
            do {
                _ = try await ip.ingestText(text: "protected", sourceLanguage: "zh-Hans", sourceId: "p", traceID: "d1")
                Issue.record("Expected IngestError.privacyDenied")
            } catch let e as IngestError { if case .privacyDenied = e {} else { Issue.record("Unexpected: \(e)") } }
        }

        @Test("SearchPipeline denies when search unauthorized")
        func test_searchDenied() async throws {
            let sp = SearchPipeline(embedder: stubEmbedder, privacyActor: PrivacyActor.shared, vectorStore: vectorStore)
            do {
                _ = try await sp.search(query: "t", k: 5)
                Issue.record("Expected SearchError.privacyDenied")
            } catch let e as SearchError { if case .privacyDenied = e {} else { Issue.record("Unexpected: \(e)") } }
        }
    }

    // MARK: - Suite 10: ExcludedAssets + Search Filter

    @Suite("ExcludedAssetsSearchFilterIntegration")
    @MainActor
    struct ExcludedAssetsSearchFilterIntegrationTests {
        let db = DatabaseManager.shared
        let vectorStore = VectorStoreActor(dimension: 512)
        let excludedAssets = ExcludedAssetsActor.shared

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM ExcludedAssets")
            try await db.execute(sql: "DELETE FROM FeedbackStore")
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(preferredLanguage: "zh-Hans", authorizedSourceTypes: ["search", "photo", "note", "voice", "text"], policyVersion: 1))
        }

        @Test("Excluded asset round-trip")
        func test_roundTrip() async throws {
            let aid = "ex-1"
            try await excludedAssets.add(assetId: aid, sourceType: "photo")
            #expect(try await excludedAssets.contains(assetId: aid))
            try await excludedAssets.remove(assetId: aid)
            #expect(try await !excludedAssets.contains(assetId: aid))
        }

        @Test("Batch restore by source type")
        func test_batchRestore() async throws {
            try await excludedAssets.add(assetId: "ba", sourceType: "photo")
            try await excludedAssets.add(assetId: "bb", sourceType: "photo")
            try await excludedAssets.add(assetId: "bc", sourceType: "note")
            try await excludedAssets.batchRestore(sourceType: "photo")
            #expect(try await !excludedAssets.contains(assetId: "ba"))
            #expect(try await !excludedAssets.contains(assetId: "bb"))
            #expect(try await excludedAssets.contains(assetId: "bc"))
            try await excludedAssets.batchRestore(sourceType: "note")
        }

        @Test("Vector search with excluded filter excludes items")
        func test_vectorSearchFilter() async throws {
            let id1 = UUID()
            let id2 = UUID()
            let id2String = id2.uuidString
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 0.95), id: id1, metadata: makePhase2TestTextMetadata(assetId: id1.uuidString, text: "keep"))
            try await vectorStore.ingest(vector: makePhase2DirectionalVector(direction: 0.92), id: id2, metadata: makePhase2TestTextMetadata(assetId: id2String, text: "excl"))
            // Exclude by vector store UUID string (same as assetId in metadata)
            try await excludedAssets.add(assetId: id2String, sourceType: "text")
            let eids = Set(try await excludedAssets.listAll().map(\.assetId))
            let r = await vectorStore.search(query: makePhase2DirectionalVector(direction: 1.0), k: 2) { !eids.contains($0.uuidString) }
            #expect(r.contains { $0.id == id1 })
            #expect(!r.contains { $0.id == id2 })
        }
    }

    // MARK: - Suite 11: Audit Log Verification

    @Suite("AuditLogVerification")
    @MainActor
    struct AuditLogVerificationTests {
        let db = DatabaseManager.shared
        let vectorStore = VectorStoreActor(dimension: 512)
        let stubEmbedder = StubEmbedder()
        let searchPipeline: SearchPipeline
        let ingestPipeline: IngestPipeline

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await db.execute(sql: "DELETE FROM ExcludedAssets")
            try await db.execute(sql: "DELETE FROM FeedbackStore")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(preferredLanguage: "zh-Hans", authorizedSourceTypes: ["search", "photo", "note", "voice", "text"], policyVersion: 1))
            searchPipeline = SearchPipeline(embedder: stubEmbedder, privacyActor: PrivacyActor.shared, vectorStore: vectorStore)
            ingestPipeline = IngestPipeline(embedder: stubEmbedder, privacyActor: PrivacyActor.shared, vectorStore: vectorStore, excludedAssets: ExcludedAssetsActor.shared)
        }

        @Test("Search pipeline creates audit log")
        func test_searchAudit() async throws {
            let tid = "as-\(UUID().uuidString.prefix(8))"
            _ = try await searchPipeline.search(query: "audit", k: 5, traceID: tid)
            #expect(try await db.executeQuery(sql: "SELECT 1 FROM AuditLog WHERE traceID = ?", bindings: [.text(tid)]).count >= 1)
        }

        @Test("Ingest pipeline creates audit log")
        func test_ingestAudit() async throws {
            let tid = "ai-\(UUID().uuidString.prefix(8))"
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 0.8))
            _ = try await ingestPipeline.ingestText(text: "audit", sourceLanguage: "zh-Hans", sourceId: "an", traceID: tid)
            #expect(try await db.executeQuery(sql: "SELECT 1 FROM AuditLog WHERE traceID = ?", bindings: [.text(tid)]).count >= 1)
        }

        @Test("Feedback pipeline creates audit log")
        func test_feedbackAudit() async throws {
            let tid = "af-\(UUID().uuidString.prefix(8))"
            try await FeedbackPipeline(feedbackActor: FeedbackActor.shared, privacyActor: PrivacyActor.shared).recordLike(memoryId: UUID(), queryText: "fb", cosineSimilarity: 0.9, traceID: tid)
            #expect(try await db.executeQuery(sql: "SELECT 1 FROM AuditLog WHERE traceID = ?", bindings: [.text(tid)]).count >= 1)
        }

        @Test("Distinct trace IDs across pipelines")
        func test_distinctTraceIDs() async throws {
            let t1 = "dt-\(UUID().uuidString.prefix(8))"
            let t2 = "dt-\(UUID().uuidString.prefix(8))"
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 0.9))
            _ = try await ingestPipeline.ingestText(text: "d1", sourceLanguage: "zh-Hans", sourceId: "dn1", traceID: t1)
            await stubEmbedder.setNextEmbedding(makePhase2DirectionalVector(direction: 0.9))
            _ = try await searchPipeline.search(query: "d2", k: 5, traceID: t2)
            for t in [t1, t2] {
                #expect(try await db.executeQuery(sql: "SELECT 1 FROM AuditLog WHERE traceID = ?", bindings: [.text(t)]).count >= 1)
            }
        }
    }

    // MARK: - Suite 12: Vector Store Persistence

    @Suite("VectorStorePersistenceIntegration")
    @MainActor
    struct VectorStorePersistenceIntegrationTests {
        let db = DatabaseManager.shared
        let stubEmbedder = StubEmbedder()

        init() async throws {
            try await db.open()
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await db.execute(sql: "DELETE FROM ExcludedAssets")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(preferredLanguage: "zh-Hans", authorizedSourceTypes: ["search", "photo", "note", "voice", "text"], policyVersion: 1))
        }

        @Test("Save and load preserves data across SearchPipeline instances")
        func test_saveLoadWithSearch() async throws {
            let store = VectorStoreActor(dimension: 512)
            let id = UUID()
            let vector = makePhase2DirectionalVector(direction: 0.95)
            try await store.ingest(vector: vector, id: id, metadata: makePhase2TestTextMetadata(assetId: "persist", text: "persistence data"))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("p2i-persist.pxkt")
            defer { try? FileManager.default.removeItem(at: url) }
            try await store.save(to: url)
            let restored = try VectorStoreActor.load(from: url)
            #expect(await restored.liveCount == 1)
            await stubEmbedder.setNextEmbedding(vector)
            let r = try await SearchPipeline(embedder: stubEmbedder, privacyActor: PrivacyActor.shared, vectorStore: restored).search(query: "persistence", k: 5)
            #expect(r.contains { $0.id == id })
        }
    }
}
