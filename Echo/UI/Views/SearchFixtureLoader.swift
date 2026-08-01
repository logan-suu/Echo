// ==========================================
// 文件: SearchFixtureLoader.swift
// 对应规格: docs/ui/echo-memory-canvas-style.md §5 (确定性 Fixture),
//            UIAutomation/Fixtures/README.md (Fixture 规范),
//            docs/ui/testing-and-artifacts.md §2.1 (fixture 可确定性解码)
// 任务: 3.2 - SearchView + SearchViewModel 确定性 Fixture Loader
// AC 覆盖: US-RET-001 AC-3 (结果展示 fixture), US-RET-006 (低置信度 fixture),
//          契约 fixture IDs: search-loaded / search-empty / search-lowconfidence / search-multitype
// 架构约束: 确定性、离线、可复现; 控制 id/timestamp/cosineSimilarity;
//           不访问网络或生产数据库 (docs/ui/architecture.md §3 Fixture Loader)
// 生成时间: 2026-08-01
// ==========================================

import Foundation

/// 确定性搜索 Fixture Loader — Preview / 单元测试 / Live Sim Review 注入。
///
/// ## 职责 (docs/ui/architecture.md §3: Fixture Loader)
/// - Preview/测试环境加载确定性数据
/// - 不访问网络或生产数据库
///
/// ## Fixture ID 映射
/// - `search-loaded`: 2 条结果（photo + note）
/// - `search-empty`: 0 条结果
/// - `search-lowconfidence`: 2 条低置信度结果（US-RET-006）
/// - `search-multitype`: 4 条结果（photo + note + voice + video_frame，ID 与详情 fixture 对齐）
enum SearchFixtureLoader {
    /// 根据 fixture ID 返回确定性 ``SearchResultItem`` 数组。
    /// 无效 ID 返回空数组（不抛错，保持确定性降级）。
    static func load(_ fixtureID: String) -> [SearchResultItem] {
        switch fixtureID {
        case "search-loaded":
            return loaded

        case "search-empty":
            return []

        case "search-lowconfidence":
            return lowConfidence

        case "search-multitype":
            return multiType

        default:
            return []
        }
    }

    /// 全部已注册 fixture ID
    static var availableFixtureIDs: [String] {
        ["search-loaded", "search-empty", "search-lowconfidence", "search-multitype"]
    }

    // MARK: - search-loaded

    private static var loaded: [SearchResultItem] {
        [
            SearchResultItem(
                id: uuid("11111111-1111-1111-1111-111111111111"),
                assetId: "photo-zh-1",
                sourceType: "photo",
                timestamp: 1723507200,
                originalText: nil,
                sourceLanguage: nil,
                crossLanguageMatch: false,
                cosineSimilarity: 0.91,
                alignmentScore: nil,
                feedbackAdjustment: nil,
                lowConfidence: false,
                fallbackReason: nil,
                unappliedFilters: []
            ),
            SearchResultItem(
                id: uuid("22222222-2222-2222-2222-222222222222"),
                assetId: "note-zh-2",
                sourceType: "note",
                timestamp: 1723420800,
                originalText: "昨晚在公园遇到一只橘猫，很亲人",
                sourceLanguage: "zh-Hans",
                crossLanguageMatch: false,
                cosineSimilarity: 0.87,
                alignmentScore: nil,
                feedbackAdjustment: nil,
                lowConfidence: false,
                fallbackReason: nil,
                unappliedFilters: []
            ),
        ]
    }

    // MARK: - search-lowconfidence

    private static var lowConfidence: [SearchResultItem] {
        [
            SearchResultItem(
                id: uuid("33333333-3333-3333-3333-333333333333"),
                assetId: "photo-en-1",
                sourceType: "photo",
                timestamp: 1723680000,
                originalText: nil,
                sourceLanguage: nil,
                crossLanguageMatch: false,
                cosineSimilarity: 0.82,
                alignmentScore: 0.55,
                feedbackAdjustment: nil,
                lowConfidence: true,
                fallbackReason: "cross_language_low_alignment",
                unappliedFilters: []
            ),
            SearchResultItem(
                id: uuid("44444444-4444-4444-4444-444444444444"),
                assetId: "note-en-2",
                sourceType: "note",
                timestamp: 1723593600,
                originalText: "A note about summer plans",
                sourceLanguage: "en-US",
                crossLanguageMatch: false,
                cosineSimilarity: 0.79,
                alignmentScore: 0.5,
                feedbackAdjustment: nil,
                lowConfidence: true,
                fallbackReason: "cross_language_low_alignment",
                unappliedFilters: []
            ),
        ]
    }

    // MARK: - search-multitype

    /// 4 条多类型结果 — ID 与 MemoryDetailFixtureLoader 详情 fixture 对齐，
    /// 支撑 Search → Detail 全流程导航验证（US-RET-001）。
    private static var multiType: [SearchResultItem] {
        [
            SearchResultItem(
                id: uuid("11111111-1111-1111-1111-111111111111"),
                assetId: "photo-zh-1",
                sourceType: "photo",
                timestamp: 1723507200,
                originalText: nil,
                sourceLanguage: nil,
                crossLanguageMatch: false,
                cosineSimilarity: 0.91,
                alignmentScore: nil,
                feedbackAdjustment: nil,
                lowConfidence: false,
                fallbackReason: nil,
                unappliedFilters: []
            ),
            SearchResultItem(
                id: uuid("22222222-2222-2222-2222-222222222222"),
                assetId: "note-zh-2",
                sourceType: "note",
                timestamp: 1723420800,
                originalText: "昨晚在公园遇到一只橘猫，很亲人",
                sourceLanguage: "zh-Hans",
                crossLanguageMatch: false,
                cosineSimilarity: 0.87,
                alignmentScore: nil,
                feedbackAdjustment: nil,
                lowConfidence: false,
                fallbackReason: nil,
                unappliedFilters: []
            ),
            SearchResultItem(
                id: uuid("66666666-6666-6666-6666-666666666666"),
                assetId: "voice-zh-1",
                sourceType: "voice",
                timestamp: 1723593600,
                originalText: "帮我记得明天下午三点去高铁站接妈妈",
                sourceLanguage: "zh-Hans",
                crossLanguageMatch: false,
                cosineSimilarity: 0.84,
                alignmentScore: nil,
                feedbackAdjustment: nil,
                lowConfidence: false,
                fallbackReason: nil,
                unappliedFilters: []
            ),
            SearchResultItem(
                id: uuid("77777777-7777-7777-7777-777777777777"),
                assetId: "video-zh-1",
                sourceType: "video_frame",
                timestamp: 1723680000,
                originalText: "傍晚的海边，日落把天空染成橙色",
                sourceLanguage: "zh-Hans",
                crossLanguageMatch: false,
                cosineSimilarity: 0.82,
                alignmentScore: nil,
                feedbackAdjustment: nil,
                lowConfidence: false,
                fallbackReason: nil,
                unappliedFilters: []
            ),
        ]
    }

    private static func uuid(_ string: String) -> UUID {
        UUID(uuidString: string) ?? UUID()
    }
}
