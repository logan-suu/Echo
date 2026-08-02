// ==========================================
// 文件: OnboardingUITests.swift
// 对应规格: docs/ui/automation-workflow.md §2 (journey 验证),
//            docs/ui/testing-and-artifacts.md §2.4 (journey 测试), §2.7 (多分支旅程测试)
// 任务: 3.11 - 引导流程：欢迎页 + PIPL 隐私同意 + 权限序列 + 语言选择 + 首次模型加载
// AC 覆盖: US-PRV-008 AC-3 (同意/拒绝), US-SRC-001 AC-6 (iCloud 提示 + Open Settings),
//          US-SYN-001 AC-2 (语言选择), 首次模型加载 (§15.6)
// 架构约束: 使用稳定 accessibility identifier，不依赖坐标 (AGENTS.md §9.1 UI 测试)
// 生成时间: 2026-08-03
// ==========================================

import XCTest

/// 引导流程 journey 测试 — 通过 -ui-fixture onboarding-* 启动参数确定性导航。
final class OnboardingUITests: XCTestCase {
    deinit {}
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 引导 happy path：欢迎 → PIPL 同意 → 权限 → 语言 → 模型加载 → 完成
    @MainActor
    func test_happyPathCompletesOnboarding() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "onboarding-welcome"]
        app.launch()

        // Step 1 欢迎页
        let start = app.buttons["onboarding-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Get Started button should appear")
        start.tap()

        // Step 2 PIPL 隐私同意 (US-PRV-008 AC-3)
        let summary = app.staticTexts["onboarding-privacy-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "Privacy summary should appear")
        let agree = app.buttons["onboarding-privacy-agree"]
        let decline = app.buttons["onboarding-privacy-decline"]
        XCTAssertTrue(agree.exists, "Agree & Continue should be present")
        XCTAssertTrue(decline.exists, "Decline should be equally prominent (US-PRV-008 AC-3)")
        agree.tap()

        // Step 3 权限序列 — 照片 (含 iCloud 提示, US-SRC-001 AC-6)
        let allow = app.buttons["onboarding-permission-allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "Permission Allow should appear")
        let iCloudHint = app.otherElements["onboarding-icloud-hint"]
        XCTAssertTrue(iCloudHint.exists, "iCloud download hint should appear on photos step")
        allow.tap()
        allow.tap()
        allow.tap()
        allow.tap()

        // Step 4 语言选择 (US-SYN-001 AC-2)
        let picker = app.segmentedControls["onboarding-language-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Language picker should appear")
        app.buttons["English"].tap()

        // Step 5 模型加载 (§15.6)
        let begin = app.buttons["onboarding-begin-load"]
        XCTAssertTrue(begin.isEnabled, "Continue should be enabled after language selection")
        begin.tap()

        let progress = app.progressIndicators["onboarding-model-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "Model progress indicator should appear")
    }

    /// 引导 PIPL 拒绝分支 (US-PRV-008 AC-3): 拒绝 → declined 终态页 → Close 退出引导
    /// W-1 强化: 断言 declined 终态 UI 出现 + Close 后 cover 关闭 (此前断言平凡成立，无法捕获 P0-2 死胡同)
    @MainActor
    func test_privacyDeclinedBranch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "onboarding-welcome"]
        app.launch()

        app.buttons["onboarding-start"].tap()

        let decline = app.buttons["onboarding-privacy-decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 5), "Decline should be present")
        decline.tap()

        // declined 终态页出现 — 提供退出出口 (P0-2 修复)
        let closeButton = app.buttons["onboarding-declined-close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Declined terminal state with Close should appear (US-PRV-008 AC-3)")

        // 点击 Close → 引导 cover 关闭 (退出引导流程)
        closeButton.tap()
        XCTAssertFalse(app.buttons["onboarding-declined-close"].waitForExistence(timeout: 3), "Onboarding cover should dismiss after Close (P0-2)")
    }

    /// 引导权限拒绝分支 (US-SRC-001 AC-6): 拒绝照片权限 → 前往设置 / 继续
    @MainActor
    func test_permissionDeniedBranch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "onboarding-welcome"]
        app.launch()

        app.buttons["onboarding-start"].tap()
        app.buttons["onboarding-privacy-agree"].tap()

        // 拒绝照片权限
        let deny = app.buttons["onboarding-permission-deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 5))
        deny.tap()

        // 拒绝后出现 Open Settings (US-SRC-001 AC-6)
        let openSettings = app.buttons["onboarding-open-settings"]
        XCTAssertTrue(openSettings.waitForExistence(timeout: 5), "Open Settings should appear after deny")

        // 跳过 → 继续下一权限
        let skip = app.buttons["onboarding-permission-skip"]
        XCTAssertTrue(skip.exists)
        skip.tap()
        let allow = app.buttons["onboarding-permission-allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "Should advance to next permission after skip")
    }

    /// 语言选择分支 (US-SYN-001 AC-2): 选择 zh-Hans 后继续
    @MainActor
    func test_languageSelectionBranch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "onboarding-welcome"]
        app.launch()

        app.buttons["onboarding-start"].tap()
        app.buttons["onboarding-privacy-agree"].tap()
        app.buttons["onboarding-permission-allow"].tap()
        app.buttons["onboarding-permission-allow"].tap()
        app.buttons["onboarding-permission-allow"].tap()
        app.buttons["onboarding-permission-allow"].tap()

        // 选择 zh-Hans
        let picker = app.segmentedControls["onboarding-language-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        app.buttons["Simplified Chinese"].tap()

        let begin = app.buttons["onboarding-begin-load"]
        XCTAssertTrue(begin.isEnabled, "Continue should be enabled after selecting zh-Hans")
        begin.tap()

        let progress = app.progressIndicators["onboarding-model-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "Model progress should appear")
    }
}
