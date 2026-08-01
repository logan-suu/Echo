// ==========================================
// 文件: SearchFixtureLoaderTests.swift
// 对应规格: UIAutomation/Fixtures/README.md (Fixture 规范),
//            docs/ui/testing-and-artifacts.md §2.1 (fixture 可确定性解码)
// 任务: 3.2 - SearchFixtureLoader 确定性数据测试
// AC 覆盖: US-RET-001 AC-3 (fixture 数据确定性), US-RET-006 (低置信度 fixture)
// 架构约束: 确定性、离线、可复现; 不访问网络或生产数据库
// 生成时间: 2026-08-01 | PR #37 review: coverage gate fix
// ==========================================

import Testing
import Foundation
@testable import Echo

/// SearchFixtureLoader 确定性数据测试 — 覆盖全部 3 个 fixture 与无效 ID 降级路径。
@MainActor
struct SearchFixtureLoaderTests {

    @Test("search-loaded fixture returns 2 deterministic results")
    func test_loadedFixture_returnsTwoResults() {
        let items = SearchFixtureLoader.load("search-loaded")
        #expect(items.count == 2)
        #expect(items[0].assetId == "photo-zh-1")
        #expect(items[0].sourceType == "photo")
        #expect(items[1].assetId == "note-zh-2")
        #expect(items[1].sourceType == "note")
        #expect(items[1].originalText == "昨晚在公园遇到一只橘猫，很亲人")
    }

    @Test("search-loaded fixture has stable IDs and similarity")
    func test_loadedFixture_stableValues() {
        let items = SearchFixtureLoader.load("search-loaded")
        #expect(items[0].cosineSimilarity == 0.91)
        #expect(items[1].cosineSimilarity == 0.87)
        #expect(items[0].lowConfidence == false)
        #expect(items[1].lowConfidence == false)
        #expect(items[0].timestamp == 1723507200)
        #expect(items[1].timestamp == 1723420800)
    }

    @Test("search-empty fixture returns empty array")
    func test_emptyFixture_returnsEmpty() {
        let items = SearchFixtureLoader.load("search-empty")
        #expect(items.isEmpty)
    }

    @Test("search-lowconfidence fixture flags results")
    func test_lowConfidenceFixture_flags() {
        let items = SearchFixtureLoader.load("search-lowconfidence")
        #expect(items.count == 2)
        #expect(items[0].lowConfidence == true)
        #expect(items[1].lowConfidence == true)
        #expect(items[0].fallbackReason == "cross_language_low_alignment")
        #expect(items[0].alignmentScore == 0.55)
    }

    @Test("search-lowconfidence fixture keeps original texts")
    func test_lowConfidenceFixture_texts() {
        let items = SearchFixtureLoader.load("search-lowconfidence")
        #expect(items[0].sourceType == "photo")
        #expect(items[0].originalText == nil)
        #expect(items[1].sourceType == "note")
        #expect(items[1].originalText == "A note about summer plans")
        #expect(items[1].sourceLanguage == "en-US")
    }

    @Test("invalid fixture ID degrades to empty array")
    func test_invalidFixtureID_returnsEmpty() {
        let items = SearchFixtureLoader.load("nonexistent-fixture")
        #expect(items.isEmpty)
    }

    @Test("search-multitype fixture returns 4 results across all memory types")
    func test_multitypeFixture_fourTypes() {
        let items = SearchFixtureLoader.load("search-multitype")
        #expect(items.count == 4)
        #expect(items[0].sourceType == "photo")
        #expect(items[1].sourceType == "note")
        #expect(items[2].sourceType == "voice")
        #expect(items[3].sourceType == "video_frame")
        #expect(items[0].assetId == "photo-zh-1")
        #expect(items[2].assetId == "voice-zh-1")
        #expect(items[3].assetId == "video-zh-1")
    }

    @Test("search-multitype result IDs align with memory-detail fixtures for navigation")
    func test_multitypeFixture_idAlignment() {
        let items = SearchFixtureLoader.load("search-multitype")
        let photoID = items[0].id
        let noteID = items[1].id
        let voiceID = items[2].id
        let videoID = items[3].id

        #expect(MemoryDetailFixtureLoader.load(memoryID: photoID)?.assetId == "photo-zh-1")
        #expect(MemoryDetailFixtureLoader.load(memoryID: noteID)?.assetId == "note-zh-2")
        #expect(MemoryDetailFixtureLoader.load(memoryID: voiceID)?.assetId == "voice-zh-1")
        #expect(MemoryDetailFixtureLoader.load(memoryID: videoID)?.assetId == "video-zh-1")
    }

    @Test("search-multitype fixture has stable similarity and timestamps")
    func test_multitypeFixture_stableValues() {
        let items = SearchFixtureLoader.load("search-multitype")
        #expect(items[0].cosineSimilarity == 0.91)
        #expect(items[1].cosineSimilarity == 0.87)
        #expect(items[2].cosineSimilarity == 0.84)
        #expect(items[3].cosineSimilarity == 0.82)
        #expect(items[2].timestamp == 1723593600)
        #expect(items[3].timestamp == 1723680000)
    }

    @Test("available fixture IDs lists all four")
    func test_availableFixtureIDs() {
        let ids = SearchFixtureLoader.availableFixtureIDs
        #expect(ids.contains("search-loaded"))
        #expect(ids.contains("search-empty"))
        #expect(ids.contains("search-lowconfidence"))
        #expect(ids.contains("search-multitype"))
        #expect(ids.count == 4)
    }
}
