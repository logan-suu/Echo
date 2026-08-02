// ==========================================
// 文件: TranslationFixtureLoader.swift
// 对应规格: docs/ui/echo-memory-canvas-style.md §5 (确定性 Fixture),
//            UIAutomation/Fixtures/README.md (Fixture 规范),
//            docs/01-spec/用户故事与验收标准规格书.md → US-DIS-002 (按需翻译)
// 任务: 3.8 - 跨语言翻译层集成
// AC 覆盖: US-DIS-002 AC-1/AC-2/AC-3/AC-4/AC-5 (确定性翻译 fixture)
//          契约 fixture IDs: translation-zh-en-high / translation-zh-en-low /
//                            translation-zh-en-cached / translation-error
// 架构约束: 确定性、离线、可复现; 不访问网络或生产数据库 (docs/ui/architecture.md §3);
//           fixture ID 与 UIAutomation/Fixtures/translation/*.json 对齐
// 生成时间: 2026-08-02
// ==========================================

import Foundation

/// 确定性翻译 Fixture Loader — Preview / 单元测试 / Live Sim Review 注入。
///
/// ## Fixture ID 映射 (与 FixtureTranslationService.zhEnMap 对齐)
/// - `translation-zh-en-high`: 中文记忆 → 源语言检测高置信度译文 (0.95)
/// - `translation-zh-en-low`: 中文记忆 → 源语言检测不确定 (0.55, <0.9) 保留原文 + 语言标签
/// - `translation-zh-en-cached`: 中文记忆 → 缓存命中 (translationVisible=true, 已含译文)
/// - `translation-error`: 中文记忆 → 触发 L2 错误 (未命中服务映射)
enum TranslationFixtureLoader {
    /// 根据 fixture ID 返回确定性 ``MemoryDetailModel``。
    /// 无效 ID 返回 nil（不抛错，保持确定性降级）。
    static func load(_ fixtureID: String) -> MemoryDetailModel? {
        switch fixtureID {
        case "translation-zh-en-high":
            return highConfidence

        case "translation-zh-en-low":
            return lowConfidence

        case "translation-zh-en-cached":
            return cached

        case "translation-error":
            return errorFixture

        default:
            return nil
        }
    }

    /// 全部已注册 fixture ID
    static var availableFixtureIDs: [String] {
        ["translation-zh-en-high", "translation-zh-en-low", "translation-zh-en-cached", "translation-error"]
    }

    // MARK: - translation-zh-en-high

    /// 中文文本记忆 — 展开后经 FixtureTranslationService 翻译为英文 (confidence 0.95)。
    private static var highConfidence: MemoryDetailModel {
        MemoryDetailModel(
            id: uuid("22222222-2222-2222-2222-222222222222"),
            assetId: "note-zh-2",
            sourceType: "note",
            title: "昨晚的公园散步",
            originalText: "昨晚在公园遇到一只橘猫，很亲人。它在我脚边蹭了很久，后来跟着我走了一段路。",
            sourceLanguage: "zh-Hans",
            preferredLanguage: "en-US",
            timestamp: Date(timeIntervalSince1970: 1723420800),
            tags: ["公园", "橘猫"],
            translationVisible: false
        )
    }

    // MARK: - translation-zh-en-low

    /// 中文俚语记忆 — 源语言检测不确定 (0.55, <0.9 .uncertain)，保留原文 + 语言标签 (AC-3, ADR-005)。
    private static var lowConfidence: MemoryDetailModel {
        MemoryDetailModel(
            id: uuid("33333333-3333-3333-3333-333333333333"),
            assetId: "note-zh-3",
            sourceType: "note",
            title: "俚语记忆",
            originalText: "今天整个下午都在搞这个破项目，快崩了。",
            sourceLanguage: "zh-Hans",
            preferredLanguage: "en-US",
            timestamp: Date(timeIntervalSince1970: 1723680000),
            tags: ["工作"],
            translationVisible: false
        )
    }

    // MARK: - translation-zh-en-cached

    /// 缓存命中记忆 — translationVisible=true 且已含译文（模拟 7 天内缓存命中，AC-2/AC-5）。
    private static var cached: MemoryDetailModel {
        MemoryDetailModel(
            id: uuid("22222222-2222-2222-2222-222222222222"),
            assetId: "note-zh-2",
            sourceType: "note",
            title: "昨晚的公园散步",
            originalText: "昨晚在公园遇到一只橘猫，很亲人。它在我脚边蹭了很久，后来跟着我走了一段路。",
            sourceLanguage: "zh-Hans",
            preferredLanguage: "en-US",
            timestamp: Date(timeIntervalSince1970: 1723420800),
            tags: ["公园", "橘猫"],
            translationVisible: true,
            translatedText: "Last night I met an orange tabby in the park. It was very friendly, rubbing against my legs and following me for a while.",
            sourceLanguageConfidence: 0.95
        )
    }

    // MARK: - translation-error

    /// 错误记忆 — 展开后触发 L2 错误（FixtureTranslationService 未命中 → serviceUnavailable）。
    private static var errorFixture: MemoryDetailModel {
        MemoryDetailModel(
            id: uuid("44444444-4444-4444-4444-444444444444"),
            assetId: "note-zh-4",
            sourceType: "note",
            title: "翻译失败记忆",
            originalText: "这是一条需要翻译但服务暂不可用的记忆。",
            sourceLanguage: "zh-Hans",
            preferredLanguage: "en-US",
            timestamp: Date(timeIntervalSince1970: 1723756800),
            tags: []
        )
    }

    private static func uuid(_ string: String) -> UUID {
        UUID(uuidString: string) ?? UUID()
    }
}
