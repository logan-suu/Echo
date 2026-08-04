// ==========================================
// 文件: ResumeProgressPromptUITests.swift
// 对应规格: docs/ui/automation-workflow.md §2 (journey 验证),
//            docs/ui/testing-and-artifacts.md §2.4 (journey 测试)
// 任务: 3.7 - 断点续传恢复提示 journey 行为验证
// AC 覆盖: US-SYS-001 AC-3 (取消后弹窗询问继续/重新开始), AC-4 (断点续传进度展示)
// 架构约束: 使用稳定 accessibility identifier，不依赖坐标 (AGENTS.md §9.1 UI 测试)
// 生成时间: 2026-08-02
// ==========================================

import XCTest

/// 断点续传恢复提示 journey 测试 — 运行时覆盖 ResumeProgressPromptView 声明式 body（coverage gate）。
final class ResumeProgressPromptUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// pending fixture: Home tab 启动 → 恢复提示弹窗出现（进度 50/128）→ 点击 Continue → 弹窗关闭
    @MainActor
    func test_pendingJourneyContinue() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-fixture", "resume-progress-pending"]
        app.launch()

        // confirmationDialog 出现（等待 checkForPendingProgress 异步完成）。
        // SwiftUI confirmationDialog 按钮以可见标题暴露，不携带自定义 identifier
        // （与 BackgroundTaskPanelUITests 的 "Cancel Task" 查询模式一致）。
        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10), "Continue button should appear in resume prompt")

        // 进度文本可见 (US-SYS-001 AC-4)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '50'")).firstMatch.exists,
                      "Progress text should show saved index")

        // 点击 Continue → 弹窗关闭
        continueButton.tap()
        XCTAssertTrue(continueButton.waitForNonExistence(timeout: 5), "Prompt should dismiss after Continue")
    }

    /// pending fixture: 点击 Restart → 弹窗关闭（重新开始意图）
    @MainActor
    func test_pendingJourneyRestart() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-fixture", "resume-progress-pending"]
        app.launch()

        let restartButton = app.buttons["Restart"]
        XCTAssertTrue(restartButton.waitForExistence(timeout: 10), "Restart button should appear in resume prompt")

        restartButton.tap()
        XCTAssertTrue(restartButton.waitForNonExistence(timeout: 5), "Prompt should dismiss after Restart")
    }

    /// error fixture: 内联 L2 错误 + Retry 按钮出现（无 confirmationDialog）
    @MainActor
    func test_errorFixtureShowsRetry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-fixture", "resume-progress-error"]
        app.launch()

        let retryButton = app.buttons["resume-prompt-retry"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 10), "Retry button should appear in error state")

        XCTAssertFalse(app.buttons["Continue"].exists,
                       "No continue prompt should be shown in error state")
    }

    /// none fixture: 无未完成进度 → 无弹窗（任务从头开始）
    @MainActor
    func test_noneFixtureNoPrompt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-fixture", "resume-progress-none"]
        app.launch()

        // 短暂等待后确认无恢复提示按钮出现
        sleep(2)
        XCTAssertFalse(app.buttons["Continue"].exists,
                       "No resume prompt when no pending progress")
        XCTAssertFalse(app.buttons["Restart"].exists)
    }
}
