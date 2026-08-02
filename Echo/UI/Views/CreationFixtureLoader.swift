// ==========================================
// 文件: CreationFixtureLoader.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8/3.9.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SYN-003 (情感内容生成+保存到备忘录),
//            US-SYN-004 (月度/年度叙事报告), US-SYN-005 (私有 Prompt 草稿)
//            docs/ui/echo-memory-canvas-style.md §3.2 (Focus surfaces), §5 (确定性 Fixture),
//            UIAutomation/Fixtures/README.md (Fixture 规范),
//            docs/ui/testing-and-artifacts.md §2.1 (fixture 可确定性解码)
// 任务: 3.9 - 整合所有 ViewModel 与 Pipeline + 创作保存 UI
// AC 覆盖: US-SYN-003 AC-3 ✅ (预览/复制/导出), AC-4 ✅ (保存到备忘录按钮), AC-5 ✅ (Toast+链接 / L2 重试),
//          US-SYN-004 AC-4 ✅ (分享/导出/打印), US-SYN-005 AC-4 ✅ (Prompt 草稿可编辑确认), AC-6 ✅ (重置为默认)
//          契约 fixture IDs: creation-idle / creation-generated-letter / creation-generated-report /
//                            creation-empty / creation-error / creation-prompt-draft / creation-saved
// 架构约束: 确定性、离线、可复现; 不访问网络或生产数据库 (docs/ui/architecture.md §3 Fixture Loader);
//           fixture ID 必须与 UIAutomation/Fixtures/creation/*.json 对齐
// 生成时间: 2026-08-02
// ==========================================

import Foundation

/// 创作模板类型 (US-SYN-003 AC-1: 信件/报告/诗歌/时间线)。
enum CreationTemplate: String, CaseIterable, Sendable, Equatable {
    case letter
    case report
    case poem
    case timeline

    /// 展示标题（i18n 延后至 Phase 3.9 String Catalog）
    var displayName: String {
        switch self {
        case .letter:   return "Letter"
        case .report:   return "Report"
        case .poem:     return "Poem"
        case .timeline: return "Timeline"
        }
    }

    var systemImage: String {
        switch self {
        case .letter:   return "envelope"
        case .report:   return "doc.richtext"
        case .poem:     return "quote.opening"
        case .timeline: return "calendar"
        }
    }
}

/// 创作段落 — AI 生成文本 + 溯源锚点 (US-SYN-002/003 AC-2)。
struct CreationParagraph: Sendable, Equatable, Identifiable {
    /// 段落唯一标识（确定性）
    let id: UUID
    /// 段落文本
    let text: String
    /// 溯源锚点 — 关联的源记忆 (US-SYN-002 AC-1)
    let citation: CreationCitation?
}

/// 溯源锚点 — [🔗 MemoryID:xxx] 指向原始数据 (US-SYN-002 AC-1/AC-2)。
struct CreationCitation: Sendable, Equatable {
    /// 源记忆 ID
    let memoryId: UUID
    /// 是否存在可跳转来源（无来源 → [⚠️ NoSource] 置灰, US-SYN-002 AC-3）
    let hasSource: Bool
}

/// 创作结果展示模型 — 薄适配器 (docs/ui/architecture.md §7.1)。
struct CreationModel: Sendable, Equatable {
    /// 选中的创作模板
    var selectedTemplate: CreationTemplate
    /// 结果标题（叙事报告含周期, US-SYN-004 AC-5）
    var title: String?
    /// 报告周期（US-SYN-004: 月/年）
    var periodType: String?
    /// AI 生成段落（含溯源锚点）
    var paragraphs: [CreationParagraph]
    /// 引用的源记忆数
    var sourceMemoryCount: Int
    /// 空态原因（无匹配源记忆时非 nil → empty state）
    var emptyReason: String?
    /// 保存到备忘录后的笔记链接 (US-SYN-003 AC-5)
    var noteLink: String?
    /// 保存状态
    var savePhase: CreationSavePhase
}

/// 保存到备忘录的阶段 (US-SYN-003 AC-4/AC-5)。
enum CreationSavePhase: Sendable, Equatable {
    /// 未保存
    case none
    /// 保存中
    case saving
    /// 已保存（含笔记链接）
    case saved
    /// 保存失败 (L2)
    case failed
}

/// 确定性创作 Fixture Loader — Preview / 单元测试 / Live Sim Review 注入。
enum CreationFixtureLoader {
    /// 根据 fixture ID 返回确定性 ``CreationModel``。
    /// 无效 ID 返回 nil（不抛错，保持确定性降级）。
    static func load(_ fixtureID: String) -> CreationModel? {
        switch fixtureID {
        case "creation-idle":
            return idle

        case "creation-generated-letter":
            return generatedLetter

        case "creation-generated-report":
            return generatedReport

        case "creation-empty":
            return empty

        case "creation-prompt-draft":
            return promptDraft

        case "creation-saved":
            return saved

        case "creation-error":
            // error 由 ViewModel 模拟（L2 错误路径）
            return nil

        default:
            return nil
        }
    }

    /// 全部已注册 fixture ID
    static var availableFixtureIDs: [String] {
        [
            "creation-idle",
            "creation-generated-letter",
            "creation-generated-report",
            "creation-empty",
            "creation-error",
            "creation-prompt-draft",
            "creation-saved",
        ]
    }

    /// 按模板加载确定性生成结果 — `generate()` 的 fixture 兜底 (Live Sim Review / XCUITest 确定性路径)。
    ///
    /// 未选择模板或无匹配模板时返回 nil（由 ViewModel 降级为 error）。
    static func load(for template: CreationTemplate) -> CreationModel? {
        switch template {
        case .letter:   return generatedLetter
        case .report:   return generatedReport
        case .poem:     return generatedPoem
        case .timeline: return generatedTimeline
        }
    }

    /// 默认 System Prompt 草稿 (US-SYN-005)。
    static var defaultPromptDraft: String {
        "You are Echo, a local AI memory assistant. Focus on recent queries and feelings."
    }

    // MARK: - creation-idle

    /// 初始态 — 未选择模板。
    private static var idle: CreationModel {
        CreationModel(
            selectedTemplate: .letter,
            title: nil,
            periodType: nil,
            paragraphs: [],
            sourceMemoryCount: 0,
            emptyReason: nil,
            noteLink: nil,
            savePhase: .none
        )
    }

    // MARK: - creation-generated-letter

    /// 生成的信件 — 含两段 + 溯源锚点。
    private static var generatedLetter: CreationModel {
        CreationModel(
            selectedTemplate: .letter,
            title: "A letter to your future self",
            periodType: nil,
            paragraphs: [
                CreationParagraph(
                    id: uuid("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                    text: "In the summer of 2025 you spent many evenings walking in the park, and a small orange cat often followed you home.",
                    citation: CreationCitation(
                        memoryId: uuid("22222222-2222-2222-2222-222222222222"),
                        hasSource: true
                    )
                ),
                CreationParagraph(
                    id: uuid("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
                    text: "You wrote down how peaceful those evenings felt, even on hard days.",
                    citation: CreationCitation(
                        memoryId: uuid("33333333-3333-3333-3333-333333333333"),
                        hasSource: true
                    )
                ),
            ],
            sourceMemoryCount: 2,
            emptyReason: nil,
            noteLink: nil,
            savePhase: .none
        )
    }

    // MARK: - creation-generated-report

    /// 生成的年度叙事报告 — 分享/导出目标 (US-SYN-004)。
    private static var generatedReport: CreationModel {
        CreationModel(
            selectedTemplate: .report,
            title: "Your 2025 Narrative Report",
            periodType: "year",
            paragraphs: [
                CreationParagraph(
                    id: uuid("cccccccc-cccc-cccc-cccc-cccccccccccc"),
                    text: "This year had three clear chapters: a quiet winter, an active spring in the park, and a reflective autumn.",
                    citation: CreationCitation(
                        memoryId: uuid("44444444-4444-4444-4444-444444444444"),
                        hasSource: true
                    )
                ),
                CreationParagraph(
                    id: uuid("dddddddd-dddd-dddd-dddd-dddddddddddd"),
                    text: "Your top recurring theme was time outdoors with people close to you.",
                    citation: CreationCitation(
                        memoryId: uuid("55555555-5555-5555-5555-555555555555"),
                        hasSource: true
                    )
                ),
            ],
            sourceMemoryCount: 2,
            emptyReason: nil,
            noteLink: nil,
            savePhase: .none
        )
    }

    // MARK: - creation-empty

    /// 空态 — 无匹配源记忆。
    private static var empty: CreationModel {
        CreationModel(
            selectedTemplate: .letter,
            title: nil,
            periodType: nil,
            paragraphs: [],
            sourceMemoryCount: 0,
            emptyReason: "No source memories matched this template",
            noteLink: nil,
            savePhase: .none
        )
    }

    // MARK: - creation-prompt-draft

    /// Prompt 草稿态 — 可编辑/确认/重置 (US-SYN-005 AC-4)。
    private static var promptDraft: CreationModel {
        CreationModel(
            selectedTemplate: .letter,
            title: nil,
            periodType: nil,
            paragraphs: [],
            sourceMemoryCount: 0,
            emptyReason: nil,
            noteLink: nil,
            savePhase: .none
        )
    }

    // MARK: - creation-saved

    /// 已保存到备忘录 — Toast + 链接 (US-SYN-003 AC-5)。
    private static var saved: CreationModel {
        CreationModel(
            selectedTemplate: .letter,
            title: "A letter to your future self",
            periodType: nil,
            paragraphs: [
                CreationParagraph(
                    id: uuid("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                    text: "In the summer of 2025 you spent many evenings walking in the park, and a small orange cat often followed you home.",
                    citation: CreationCitation(
                        memoryId: uuid("22222222-2222-2222-2222-222222222222"),
                        hasSource: true
                    )
                ),
            ],
            sourceMemoryCount: 1,
            emptyReason: nil,
            noteLink: "notes://echo/creation/2025-letter",
            savePhase: .saved
        )
    }

    // MARK: - creation-generated-poem

    /// 生成的诗歌 — 短句 + 溯源锚点 (US-SYN-003 诗歌模板)。
    private static var generatedPoem: CreationModel {
        CreationModel(
            selectedTemplate: .poem,
            title: "Evenings in the park",
            periodType: nil,
            paragraphs: [
                CreationParagraph(
                    id: uuid("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"),
                    text: "A small orange cat at my feet,\nturning ordinary evenings into a quiet kind of warmth.",
                    citation: CreationCitation(
                        memoryId: uuid("22222222-2222-2222-2222-222222222222"),
                        hasSource: true
                    )
                ),
            ],
            sourceMemoryCount: 1,
            emptyReason: nil,
            noteLink: nil,
            savePhase: .none
        )
    }

    // MARK: - creation-generated-timeline

    /// 生成的时间线 — 事件链 (US-SYN-003 时间线模板)。
    private static var generatedTimeline: CreationModel {
        CreationModel(
            selectedTemplate: .timeline,
            title: "2025: a year of quiet seasons",
            periodType: "year",
            paragraphs: [
                CreationParagraph(
                    id: uuid("ffffffff-ffff-ffff-ffff-ffffffffffff"),
                    text: "Spring 2025 — long evening walks in the park.",
                    citation: CreationCitation(
                        memoryId: uuid("22222222-2222-2222-2222-222222222222"),
                        hasSource: true
                    )
                ),
            ],
            sourceMemoryCount: 1,
            emptyReason: nil,
            noteLink: nil,
            savePhase: .none
        )
    }

    private static func uuid(_ string: String) -> UUID {
        UUID(uuidString: string) ?? UUID()
    }
}
