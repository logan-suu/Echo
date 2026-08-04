// ==========================================
// 文件: CreationUITests.swift
// 对应规格: docs/ui/automation-workflow.md §2 (journey 验证),
//            docs/ui/testing-and-artifacts.md §2.4 (journey 测试)
// 任务: 3.9 - 整合所有 ViewModel 与 Pipeline + 创作保存 UI
// AC 覆盖: US-SYN-003 AC-1 (模板选择), AC-3 (预览/复制/导出), AC-4 (保存到备忘录),
//          AC-5 (保存 Toast + 链接), US-SYN-005 AC-4 (Prompt 草稿编辑确认)
// 架构约束: 使用稳定 accessibility identifier，不依赖坐标 (AGENTS.md §9.1 UI 测试)
// 生成时间: 2026-08-02
// ==========================================

import XCTest

/// AI 创作结果页 journey 测试 — 从 MemoryDetail 创作入口导航 + 生成 + 保存。
final class CreationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// MemoryDetail 启动 → 点击 "Open full creation" → 创作页模板选择 → 生成 → 结果 + 溯源锚点
    @MainActor
    func test_generateFlowFromMemoryDetail() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-fixture", "memory-detail-loaded"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        // 记忆详情页 → 创作入口
        let openCreation = app.buttons["memory-detail-open-creation"]
        XCTAssertTrue(openCreation.waitForExistence(timeout: 5), "Open full creation button should appear")
        openCreation.tap()

        // 创作页：选择 Letter 模板
        let letterTemplate = app.buttons["creation-template-letter"]
        XCTAssertTrue(letterTemplate.waitForExistence(timeout: 5), "Letter template should appear")
        letterTemplate.tap()

        // 生成
        let generate = app.buttons["creation-generate"]
        XCTAssertTrue(generate.isEnabled, "Generate should be enabled after template selection")
        generate.tap()

        // 生成结果 + 溯源锚点
        let citation = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'creation-citation-anchor-'")
        ).firstMatch
        XCTAssertTrue(citation.waitForExistence(timeout: 5), "Generated content should show citation anchors")

        // 复制 / 导出 / 保存按钮出现
        XCTAssertTrue(app.buttons["creation-copy"].exists)
        XCTAssertTrue(app.buttons["creation-export"].exists)
        XCTAssertTrue(app.buttons["creation-save-to-notes"].exists)
    }

    /// 生成结果 → 保存到备忘录 → Toast + 链接
    @MainActor
    func test_saveToNotesShowsToast() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-fixture", "memory-detail-loaded"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        let openCreation = app.buttons["memory-detail-open-creation"]
        XCTAssertTrue(openCreation.waitForExistence(timeout: 5))
        openCreation.tap()

        let letterTemplate = app.buttons["creation-template-letter"]
        XCTAssertTrue(letterTemplate.waitForExistence(timeout: 5))
        letterTemplate.tap()

        app.buttons["creation-generate"].tap()

        let save = app.buttons["creation-save-to-notes"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        // 保存 Toast + 打开链接
        let openNote = app.buttons["creation-open-note"]
        XCTAssertTrue(openNote.waitForExistence(timeout: 5), "Open note link should appear after save")
    }

    /// Prompt 草稿编辑确认 (US-SYN-005 AC-4)
    @MainActor
    func test_promptEditorConfirm() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-fixture", "memory-detail-loaded"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        let openCreation = app.buttons["memory-detail-open-creation"]
        XCTAssertTrue(openCreation.waitForExistence(timeout: 5))
        openCreation.tap()

        // 打开 Prompt 编辑器
        let editPrompt = app.buttons["creation-edit-prompt"]
        XCTAssertTrue(editPrompt.waitForExistence(timeout: 5))
        editPrompt.tap()

        // 编辑草稿
        let editor = app.textViews["creation-prompt-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" Remember the park.")

        // 确认
        let confirm = app.buttons["creation-confirm-prompt"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // 编辑器关闭，回到创作页
        XCTAssertFalse(editor.exists)
        XCTAssertTrue(app.buttons["creation-generate"].exists)
    }
}
