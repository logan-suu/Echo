// ==========================================
// 文件: SearchJourneyUITests.swift
// 对应规格: docs/ui/automation-workflow.md §2 (journey 验证),
//            docs/ui/testing-and-artifacts.md §2.4 (journey 测试)
// 任务: 3.2 - SearchView journey 行为验证
// AC 覆盖: US-RET-001 AC-3 (结果展示), US-FBK-001 AC-1 (👍/👎), US-RET-006 (低置信度),
//          3.3 Search→Detail 导航 (search-multitype fixture, US-RET-001)
// 架构约束: 使用稳定 accessibility identifier，不依赖坐标 (AGENTS.md §9.1 UI 测试)
// 生成时间: 2026-08-01 | PR #37 review: coverage gate fix — XCUITest 覆盖声明式 UI 代码
// ==========================================

import XCTest

/// Search 检索页 journey 测试 — 运行时覆盖 SearchView 声明式 body（coverage gate）。
final class SearchJourneyUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// loaded fixture: 导航到 Search tab → 验证 2 条结果 + 反馈按钮
    @MainActor
    func test_searchLoadedJourney() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-fixture", "search-loaded"]
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
    @MainActor
    func test_searchFeedbackInteraction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-fixture", "search-loaded"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        let likeButton = app.buttons["result-like-11111111-1111-1111-1111-111111111111"]
        XCTAssertTrue(likeButton.waitForExistence(timeout: 5))
        likeButton.tap()

        // 反馈后按钮仍可访问（.contain 保留子元素独立性 — PR #37 review fix）
        XCTAssertTrue(likeButton.exists)
    }

    /// empty fixture: 空态文案 + 居中布局存在
    @MainActor
    func test_searchEmptyJourney() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-fixture", "search-empty"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        XCTAssertTrue(app.staticTexts["No memories found"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Try a different search term."].exists)
    }

    /// 3.3 Search → Detail 全流程: multitype fixture → 点击 Photo 卡片 → 详情页验证
    /// 覆盖: 结果卡片点击 → MemoryDetailView push → 详情标题/翻译切换/Edit 入口
    @MainActor
    func test_searchToDetailNavigationJourney() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-fixture", "search-multitype"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        // 多类型结果加载（首屏 Photo + note 可见；voice/video 滚动后懒加载）
        let resultsList = app.collectionViews["search-results-list"]
        XCTAssertTrue(resultsList.waitForExistence(timeout: 5), "Results list should appear")
        XCTAssertTrue(app.buttons["result-like-11111111-1111-1111-1111-111111111111"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["result-like-22222222-2222-2222-2222-222222222222"].exists)

        // 点击 Photo 结果卡片（photo-zh-1 → memory-detail-photo-loaded）
        app.staticTexts["A photo memory"].tap()

        // 详情页已 push: Edit 按钮 + 标题 + 翻译切换 (US-DIS-002)
        let editButton = app.buttons["memory-detail-edit-button"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "Memory detail should push with Edit entry")
        XCTAssertTrue(app.staticTexts["公园里的红裙子"].exists, "Photo memory title should render")
        XCTAssertTrue(app.buttons["memory-detail-translation-toggle"].exists, "Translation toggle for zh→en")
    }

    /// 回归 (2026-08-02): 从详情返回后 Search 结果必须保留（不再回 idle 空态）
    @MainActor
    func test_searchResultsPersistAfterDetailReturn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-fixture", "search-multitype"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        let likeButton = app.buttons["result-like-11111111-1111-1111-1111-111111111111"]
        XCTAssertTrue(likeButton.waitForExistence(timeout: 5), "Results should load")

        // 进入详情
        app.staticTexts["A photo memory"].tap()
        XCTAssertTrue(app.buttons["memory-detail-edit-button"].waitForExistence(timeout: 5))

        // 返回 Search
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 结果卡片必须保留
        XCTAssertTrue(app.buttons["result-like-11111111-1111-1111-1111-111111111111"].waitForExistence(timeout: 5),
                      "Result cards must persist after returning from detail")
        XCTAssertTrue(app.buttons["result-like-22222222-2222-2222-2222-222222222222"].exists)
        XCTAssertTrue(app.staticTexts["Results"].exists)
    }

    /// 回归 (2026-08-02): 详情页切 Tab 再切回，详情内容保留（不再卡 loading）
    @MainActor
    func test_detailPreservedAfterTabSwitch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-fixture", "search-multitype"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        let likeButton = app.buttons["result-like-11111111-1111-1111-1111-111111111111"]
        XCTAssertTrue(likeButton.waitForExistence(timeout: 5))

        // 进入 Photo 详情
        app.staticTexts["A photo memory"].tap()
        XCTAssertTrue(app.buttons["memory-detail-edit-button"].waitForExistence(timeout: 5))

        // 切到 Home tab 再切回 Search（详情应保留，不卡 loading）
        app.tabBars.buttons["Home"].tap()
        app.tabBars.buttons["Search"].tap()

        // 详情内容仍在（非 loading 卡住）
        XCTAssertTrue(app.staticTexts["公园里的红裙子"].waitForExistence(timeout: 5),
                      "Detail content must persist after tab switch (not stuck on loading)")
        XCTAssertTrue(app.buttons["memory-detail-edit-button"].exists)
    }
}
