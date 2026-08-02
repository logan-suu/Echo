// ==========================================
// 文件: BackgroundTaskPanelUITests.swift
// 对应规格: docs/ui/automation-workflow.md §2 (journey 验证),
//            docs/ui/testing-and-artifacts.md §2.4 (journey 测试)
// 任务: 3.5 - 后台任务面板 journey 行为验证
// AC 覆盖: US-SYS-001 AC-1 (活跃任务列表), AC-2 (进度计数), AC-3 (暂停/取消), AC-5 (自动隐藏空态)
// 架构约束: 使用稳定 accessibility identifier，不依赖坐标 (AGENTS.md §9.1 UI 测试)
// 生成时间: 2026-08-02
// ==========================================

import XCTest

/// 后台任务面板 journey 测试 — 运行时覆盖 BackgroundTaskPanelView 声明式 body（coverage gate）。
final class BackgroundTaskPanelUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// loaded fixture: Home tab 工具栏入口 → 打开面板 → 验证任务列表 + 进度 + 暂停/取消按钮
    @MainActor
    func test_loadedJourney() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "background-tasks-loaded"]
        app.launch()

        // 面板已通过 launch argument 自动打开
        let panel = app.otherElements["background-tasks-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Panel should be presented")

        // 任务列表
        let list = app.collectionViews["background-tasks-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5), "Task list should appear")

        // 2 个任务行 + 暂停/取消按钮
        XCTAssertTrue(app.buttons["background-task-pause-task-sync-001"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["background-task-cancel-task-sync-001"].exists)
        XCTAssertTrue(app.buttons["background-task-pause-task-index-001"].exists)
        XCTAssertTrue(app.buttons["background-task-cancel-task-index-001"].exists)

        // 进度计数可见 (US-SYS-001 AC-2)
        XCTAssertTrue(app.staticTexts["32/128 · 25%"].exists)
        XCTAssertTrue(app.staticTexts["100/500 · 20%"].exists)
    }

    /// 暂停交互: 点击暂停 → 状态标签变为 Paused (US-SYS-001 AC-3)
    @MainActor
    func test_pauseInteraction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "background-tasks-loaded"]
        app.launch()

        let pauseButton = app.buttons["background-task-pause-task-sync-001"]
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 10))
        pauseButton.tap()

        XCTAssertTrue(app.staticTexts["Paused"].exists, "Paused status label should appear")
        XCTAssertTrue(app.buttons["background-task-pause-task-sync-001"].exists)
    }

    /// W-1 回归测试 (PR #40 review): 暂停全部任务后面板保持打开 — 自动隐藏
    /// 仅在任务列表为空时触发（AC-5），paused 任务保留恢复入口（AC-3）。
    @MainActor
    func test_pauseAllTasksKeepsPanelOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "background-tasks-loaded"]
        app.launch()

        let panel = app.otherElements["background-tasks-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Panel should be presented")

        // 暂停两条任务
        let pauseSync = app.buttons["background-task-pause-task-sync-001"]
        XCTAssertTrue(pauseSync.waitForExistence(timeout: 5))
        pauseSync.tap()
        app.buttons["background-task-pause-task-index-001"].tap()

        // 两条均变为 Paused
        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 5))
        let pausedCount = app.staticTexts.matching(NSPredicate(format: "label == 'Paused'")).count
        XCTAssertEqual(pausedCount, 2, "Both tasks should show Paused")

        // 等待超过自动隐藏窗口 (1.5s) — 面板必须保持打开（暂停状态可恢复，AC-3）
        sleep(3)
        XCTAssertTrue(panel.exists, "Panel should stay open with paused tasks (W-1)")

        // 恢复一条 → 状态回到 Running
        app.buttons["background-task-pause-task-sync-001"].tap()
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 5),
                      "Resumed task should show Running")
    }

    /// 取消交互: 点击取消 → 确认弹窗 → 确认后任务移除 (US-SYS-001 AC-3)
    @MainActor
    func test_cancelInteraction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "background-tasks-loaded"]
        app.launch()

        let cancelButton = app.buttons["background-task-cancel-task-sync-001"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 10))
        cancelButton.tap()

        // 确认弹窗出现
        let confirmButton = app.buttons["Cancel Task"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), "Cancel confirmation should appear")
        confirmButton.tap()

        // 任务已移除 — 仅剩 1 个任务（等待列表行移除动画完成）
        let removedRow = app.buttons["background-task-cancel-task-sync-001"]
        XCTAssertTrue(removedRow.waitForNonExistence(timeout: 5), "Cancelled task row should be removed")
        XCTAssertTrue(app.buttons["background-task-cancel-task-index-001"].exists)
    }

    /// AC-5 转换路径: loaded → 取消全部任务 → 空态渲染 → 1.5s 后面板自动关闭。
    /// 空态经 launch-args fixture 注入时本身即瞬态（契约 background-tasks-state-empty:
    /// autoHide 1.5s），故用用户驱动的确定性转换覆盖空态渲染与自动隐藏两者。
    @MainActor
    func test_cancelAllTasksShowsEmptyAndAutoHides() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "background-tasks-loaded"]
        app.launch()

        let panel = app.otherElements["background-tasks-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Panel should be presented")

        // 取消任务 A（确认弹窗 → 确认）
        let cancelSync = app.buttons["background-task-cancel-task-sync-001"]
        XCTAssertTrue(cancelSync.waitForExistence(timeout: 5))
        cancelSync.tap()
        app.buttons["Cancel Task"].firstMatch.tap()
        XCTAssertTrue(cancelSync.waitForNonExistence(timeout: 5), "Cancelled task row should be removed")

        // 取消任务 B → 空态渲染（自动隐藏计时自此刻起 1.5s）
        let cancelIndex = app.buttons["background-task-cancel-task-index-001"]
        XCTAssertTrue(cancelIndex.waitForExistence(timeout: 5))
        cancelIndex.tap()
        app.buttons["Cancel Task"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["No active tasks"].waitForExistence(timeout: 3),
                      "Empty state should be shown after cancelling all tasks")
        XCTAssertTrue(app.descendants(matching: .any)["background-tasks-empty"].exists)

        // AC-5: 无活跃任务 → 面板自动关闭
        XCTAssertTrue(panel.waitForNonExistence(timeout: 10), "Panel should auto-hide when no active tasks")
    }

    /// Done 按钮回归测试: 点击 Done 必须真正关闭 Sheet（修复: Done 仅清空任务列表,
    /// 未触发 dismiss 导致半屏面板残留）
    @MainActor
    func test_doneDismissesPanel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "background-tasks-loaded"]
        app.launch()

        let panel = app.otherElements["background-tasks-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Panel should be presented")

        let doneButton = app.buttons["background-tasks-done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Done button should exist in toolbar")
        doneButton.tap()

        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "Panel should dismiss after tapping Done")
    }
}
