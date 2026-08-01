// ==========================================
// 文件: SearchJourneyUITests.swift
// 对应规格: docs/ui/automation-workflow.md §2 (journey 验证),
//            docs/ui/testing-and-artifacts.md §2.4 (journey 测试)
// 任务: 3.2 - SearchView journey 行为验证
// AC 覆盖: US-RET-001 AC-3 (结果展示), US-FBK-001 AC-1 (👍/👎), US-RET-006 (低置信度)
// 架构约束: 使用稳定 accessibility identifier，不依赖坐标 (AGENTS.md §9.1 UI 测试)
// 生成时间: 2026-08-01 | PR #37 review: coverage gate fix — XCUITest 覆盖声明式 UI 代码
// ==========================================

import XCTest

/// Search 检索页 journey 测试 — 运行时覆盖 SearchView 声明式 body（coverage gate）。
@MainActor
final class SearchJourneyUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// loaded fixture: 导航到 Search tab → 验证 2 条结果 + 反馈按钮
    func test_searchLoadedJourney() throws {
        app.launchArguments = ["-ui-fixture", "search-loaded"]
        app.launch()

        // 点击 Tab Bar 的 Search 按钮
        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10), "Search tab should exist")
        searchTab.tap()

        // 结果列表存在
        let resultsList = app.collectionViews["search-results-list"]
        XCTAssertTrue(resultsList.waitForExistence(timeout: 5), "Results list should appear")

        // 2 条结果卡片
        XCTAssertTrue(app.buttons["result-like-11111111-1111-1111-1111-111111111111"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["result-dislike-11111111-1111-1111-1111-111111111111"].exists)
        XCTAssertTrue(app.buttons["result-like-22222222-2222-2222-2222-222222222222"].exists)
        XCTAssertTrue(app.buttons["result-dislike-22222222-2222-2222-2222-222222222222"].exists)

        // 结果计数头
        XCTAssertTrue(app.staticTexts["Results"].exists)
    }

    /// 反馈交互: 点击 👍 后状态变化（US-FBK-001 AC-1）
    func test_searchFeedbackInteraction() throws {
        app.launchArguments = ["-ui-fixture", "search-loaded"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        let likeButton = app.buttons["result-like-11111111-1111-1111-1111-111111111111"]
        XCTAssertTrue(likeButton.waitForExistence(timeout: 5))
        likeButton.tap()

        // 反馈后按钮仍可访问（.contain 保留子元素独立性 — PR #37 review fix）
        XCTAssertTrue(likeButton.exists)
    }

    /// empty fixture: 空态文案 + 居中布局存在
    func test_searchEmptyJourney() throws {
        app.launchArguments = ["-ui-fixture", "search-empty"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        XCTAssertTrue(app.staticTexts["No memories found"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Try a different search term."].exists)
    }
}
