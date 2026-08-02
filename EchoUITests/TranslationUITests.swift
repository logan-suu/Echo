// ==========================================
// 文件: TranslationUITests.swift
// 对应规格: docs/ui/automation-workflow.md §2 (journey 验证),
//            docs/ui/testing-and-artifacts.md §2.4 (journey 测试)
// 任务: 3.8 - 跨语言翻译层集成
// AC 覆盖: US-DIS-002 AC-1 (展开触发), AC-3 (低置信度保留原文), AC-4 (切换按钮)
// 架构约束: 使用稳定 accessibility identifier，不依赖坐标 (AGENTS.md §9.1 UI 测试)
// 生成时间: 2026-08-02
// ==========================================

import XCTest

/// 记忆详情按需翻译 journey 测试 — 运行时覆盖 TranslationService 驱动翻译区声明式 body。
final class TranslationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// high-confidence fixture: Search tab 启动 → 详情展示翻译切换按钮 → 点击 → 译文出现
    @MainActor
    func test_highConfidenceToggleShowsTranslation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "translation-zh-en-high"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        let toggle = app.buttons["memory-detail-translation-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Translation toggle should appear")
        XCTAssertTrue(toggle.label.contains("Show translation"), "Toggle starts in original state")

        toggle.tap()

        // 译文出现（fixture 服务确定性返回 "orange tabby"）
        let translated = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'orange tabby'")
        ).firstMatch
        XCTAssertTrue(translated.waitForExistence(timeout: 5), "Translated text should appear")

        // 切换回原文
        toggle.tap()
        XCTAssertFalse(translated.exists, "Toggle back to original hides translation")
    }

    /// low-confidence fixture: 展开后置信度 <0.7 → 保留原文 + 语言标签
    @MainActor
    func test_lowConfidenceRetainsOriginal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "translation-zh-en-low"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        let toggle = app.buttons["memory-detail-translation-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Translation toggle should appear")

        toggle.tap()

        // 原文保留标签出现 (US-DIS-002 AC-3)
        let originalLabel = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Original:'")
        ).firstMatch
        XCTAssertTrue(originalLabel.waitForExistence(timeout: 5), "Original text + language label retained")
    }

    /// error fixture: 翻译服务不可用 → L2 错误 + Retry 按钮
    @MainActor
    func test_errorFixtureShowsRetry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "translation-error"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        let toggle = app.buttons["memory-detail-translation-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Translation toggle should appear")

        toggle.tap()

        let retry = app.buttons["memory-detail-translation-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "Retry button should appear on L2 translation error")
    }
}
