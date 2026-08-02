// ==========================================
// 文件: MemoryDetailFixtureLoader.swift
// 对应规格: docs/ui/echo-memory-canvas-style.md §5 (确定性 Fixture),
//            UIAutomation/Fixtures/README.md (Fixture 规范),
//            docs/ui/testing-and-artifacts.md §2.1 (fixture 可确定性解码)
// 任务: 3.3 - MemoryDetailView 确定性 Fixture Loader
// AC 覆盖: US-AWK-007 (编辑/冲突 fixture), US-DIS-002 (翻译 fixture),
//          US-RET-001 (多类型记忆详情: photo/note/voice/video_frame 展示)
//          契约 fixture IDs: memory-detail-loaded / memory-detail-translated /
//                            memory-detail-conflict / memory-detail-error /
//                            memory-detail-photo-loaded / memory-detail-voice-loaded /
//                            memory-detail-video-loaded
// 架构约束: 确定性、离线、可复现; 控制 id/timestamp/translation/conflict;
//           不访问网络或生产数据库 (docs/ui/architecture.md §3 Fixture Loader);
//           fixture ID 必须与 UIAutomation/Fixtures/search/*.json 结果 ID 对齐
//           (Search → Detail 导航链路: SearchView.onOpen 按 result.id 匹配)
// 生成时间: 2026-08-01
// ==========================================

import Foundation

/// 确定性记忆详情 Fixture Loader — Preview / 单元测试 / Live Sim Review 注入。
///
/// ## 职责 (docs/ui/architecture.md §3: Fixture Loader)
/// - Preview/测试环境加载确定性数据
/// - 不访问网络或生产数据库
///
/// ## Fixture ID 映射
/// - `memory-detail-loaded`: 中文文本记忆（需翻译，未展开）
/// - `memory-detail-translated`: 已展开译文的记忆
/// - `memory-detail-conflict`: 冲突态记忆（本地草稿 vs 外部版本）
/// - `memory-detail-error`: 加载失败态
/// - `memory-detail-photo-loaded`: 图片记忆（用户补充描述，userEdited=true）
/// - `memory-detail-voice-loaded`: 语音转写记忆
/// - `memory-detail-video-loaded`: 视频帧记忆
enum MemoryDetailFixtureLoader {
    /// 根据 fixture ID 返回确定性 ``MemoryDetailModel``。
    /// 无效 ID 返回 nil（不抛错，保持确定性降级）。
    static func load(_ fixtureID: String) -> MemoryDetailModel? {
        switch fixtureID {
        case "memory-detail-loaded":
            return loaded

        case "memory-detail-translated":
            return translated

        case "memory-detail-conflict":
            return conflict

        case "memory-detail-photo-loaded":
            return photoLoaded

        case "memory-detail-voice-loaded":
            return voiceLoaded

        case "memory-detail-video-loaded":
            return videoLoaded

        case "memory-detail-error":
            return nil

        default:
            return nil
        }
    }

    /// 按记忆 ID 匹配确定性详情 — Search → Detail 导航链路（US-RET-001）。
    ///
    /// SearchView 点击结果卡片时按 `result.id` 查找对应详情 fixture；
    /// 命中则预加载详情，未命中（生产路径）由 Core 按 memoryId 拉取（Phase 3.9）。
    static func load(memoryID: UUID) -> MemoryDetailModel? {
        allModels.first { $0.id == memoryID }
    }

    /// 全部已注册 fixture ID
    static var availableFixtureIDs: [String] {
        [
            "memory-detail-loaded",
            "memory-detail-translated",
            "memory-detail-conflict",
            "memory-detail-error",
            "memory-detail-photo-loaded",
            "memory-detail-voice-loaded",
            "memory-detail-video-loaded",
        ]
    }

    /// 全部可加载的详情模型（不含 error — error 由 ViewModel 模拟）。
    private static var allModels: [MemoryDetailModel] {
        [loaded, translated, conflict, photoLoaded, voiceLoaded, videoLoaded]
    }

    // MARK: - memory-detail-loaded

    /// 中文文本记忆 — 源语言 zh-Hans，首选语言 en-US，未展开翻译。
    /// 对应 fixture 文件 UIAutomation/Fixtures/memory-detail/memory-detail-loaded.json
    private static var loaded: MemoryDetailModel {
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
            translationVisible: false,
            translatedText: nil,
            sourceLanguageConfidence: nil
        )
    }

    // MARK: - memory-detail-translated

    /// 已展开译文的记忆 — translationVisible = true。
    /// 对应 fixture 文件 memory-detail-translated.json
    private static var translated: MemoryDetailModel {
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

    // MARK: - memory-detail-conflict

    /// 冲突态记忆 — 外部数据源变更，用户编辑未保存。
    /// 对应 fixture 文件 memory-detail-conflict.json
    private static var conflict: MemoryDetailModel {
        MemoryDetailModel(
            id: uuid("55555555-5555-5555-5555-555555555555"),
            assetId: "note-zh-5",
            sourceType: "note",
            title: "出差记录",
            originalText: "今天去杭州出差。",
            sourceLanguage: "zh-Hans",
            preferredLanguage: "en-US",
            timestamp: Date(timeIntervalSince1970: 1723507200),
            tags: [],
            conflict: MemoryConflictModel(
                localDraft: "今天去杭州出差，傍晚去了西湖。",
                externalVersion: "今天去杭州出差，客户改期到下周。"
            )
        )
    }

    // MARK: - memory-detail-photo-loaded

    /// 图片记忆 — 用户补充描述（US-AWK-007 AC-1），userEdited=true。
    /// 对应 fixture 文件 memory-detail-photo-loaded.json；ID 与 search 结果 photo-zh-1 对齐。
    private static var photoLoaded: MemoryDetailModel {
        MemoryDetailModel(
            id: uuid("11111111-1111-1111-1111-111111111111"),
            assetId: "photo-zh-1",
            sourceType: "photo",
            title: "公园里的红裙子",
            originalText: "公园里穿红裙子的女孩，在喷泉边喂鸽子，那天下午阳光很好。",
            sourceLanguage: "zh-Hans",
            preferredLanguage: "en-US",
            timestamp: Date(timeIntervalSince1970: 1723507200),
            tags: ["公园", "红裙子", "喷泉"],
            userEdited: true,
            mediaAssetName: "photo-park-sunset",
            location: "西湖公园"
        )
    }

    // MARK: - memory-detail-voice-loaded

    /// 语音转写记忆 — Whisper 转写文本 + 示例音频。
    /// 对应 fixture 文件 memory-detail-voice-loaded.json；ID 与 search 结果 voice-zh-1 对齐。
    private static var voiceLoaded: MemoryDetailModel {
        MemoryDetailModel(
            id: uuid("66666666-6666-6666-6666-666666666666"),
            assetId: "voice-zh-1",
            sourceType: "voice",
            title: "明天下午接妈妈",
            originalText: "帮我记得明天下午三点去高铁站接妈妈，她坐 G1234 次列车。",
            sourceLanguage: "zh-Hans",
            preferredLanguage: "en-US",
            timestamp: Date(timeIntervalSince1970: 1723593600),
            tags: ["家人", "提醒"],
            mediaAssetName: "voice-note-reminder",
            location: "杭州东站"
        )
    }

    // MARK: - memory-detail-video-loaded

    /// 视频帧记忆 — 帧级语义描述 + 示例视频。
    /// 对应 fixture 文件 memory-detail-video-loaded.json；ID 与 search 结果 video-zh-1 对齐。
    private static var videoLoaded: MemoryDetailModel {
        MemoryDetailModel(
            id: uuid("77777777-7777-7777-7777-777777777777"),
            assetId: "video-zh-1",
            sourceType: "video_frame",
            title: "海边日落",
            originalText: "傍晚的海边，日落把天空染成橙色，海浪声很大，画面最后有小孩跑过镜头。",
            sourceLanguage: "zh-Hans",
            preferredLanguage: "en-US",
            timestamp: Date(timeIntervalSince1970: 1723680000),
            tags: ["海边", "日落"],
            mediaAssetName: "video-seaside-sunset",
            location: "三亚湾"
        )
    }

    private static func uuid(_ string: String) -> UUID {
        UUID(uuidString: string) ?? UUID()
    }
}
