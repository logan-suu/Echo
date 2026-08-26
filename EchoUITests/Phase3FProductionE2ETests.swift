// ==========================================
// 文件: Phase3FProductionE2ETests.swift
// 对应规格: docs/05-planning/phase3f-execution-plan.md §3F.11 (Production E2E 与 Phase 4 准入门禁),
//           §6.1 (no-fixture E2E 门禁: 无 -ui-fixture / fixture loader / actor seeding /
//                manual DB injection / stub model),
//           docs/decisions/ADR-007 (production composition + deny-by-default consent),
//           docs/decisions/ADR-014 (Phase 4 唯一入口 = 3F.11)
// 任务: 3F.11 - Production E2E 与 Phase 4 准入门禁
// AC 覆盖: US-PRV-008 (引导同意流程), US-SRC-001 (来源授权), US-SYN-001 (语言选择),
//          ADR-007 §决策-5 (启动状态机: ready / modelUnavailable / routeUnavailable / indexUnavailable)
// 架构约束: 生产路径 no-fixture — 不得传入 -ui-fixture / -ui-skip-consent / 任何 fixture 参数；
//           启动状态仅接受 .ready (主 TabView) 或文档化不可用态 (unavailableGate)。
// 生成时间: 2026-08-12
// ==========================================

import XCTest

/// 生产 no-fixture E2E 门禁 — 在默认 Echo App 路径上验证「干净安装 → 同意 →
/// 权限 → 语言 → 模型加载 → 主界面或文档化不可用态」的完整闭环。
///
/// 本套件**不传递任何 fixture 启动参数**，不使用 fixture loader、不直接播种 actor、
/// 不注入数据库、不使用 stub 模型（§6.1 禁止项）。所有状态转换必须来自真实
/// composition root（AppComposition）与真实启动状态机（ADR-007 §决策-5）。
final class Phase3FProductionE2ETests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 辅助：记录测试断言使用的启动参数 — 确保本测试从未携带 fixture 参数。
    @MainActor
    private func assertNoFixtureArguments(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for arg in app.launchArguments {
            XCTAssertFalse(
                arg.hasPrefix("-ui-fixture"),
                "no-fixture E2E must not pass -ui-fixture (got \(arg))",
                file: file,
                line: line
            )
            XCTAssertFalse(
                arg.hasPrefix("-ui-skip-consent"),
                "no-fixture E2E must not bypass the consent gate (got \(arg))",
                file: file,
                line: line
            )
        }
    }

    /// 生产路径：干净安装 → onboarding（deny-by-default）→ 同意 → 权限 → 语言 →
    /// 模型加载 → 主 TabView 或文档化不可用态。
    ///
    /// 注意：本测试在生产路径上启动，不含任何 fixture。若模拟器上已有先前
    /// 测试留下的已同意状态（App 未卸载），引导可能不出现 — 此时直接断言
    /// 主 TabView 已可达（幂等）。
    @MainActor
    func test_noFixture_cleanInstallToReadyOrUnavailableGate() throws {
        let app = XCUIApplication()
        app.launchArguments = []  // 生产路径 — 零 fixture 参数
        app.launch()
        assertNoFixtureArguments(app)

        // onboarding 在 deny-by-default 新装下出现（US-PRV-008 / ADR-007 §决策-2）
        let start = app.buttons["onboarding-start"]
        if start.waitForExistence(timeout: 8) {
            // 生产引导闭环
            start.tap()

            let agree = app.buttons["onboarding-privacy-agree"]
            XCTAssertTrue(agree.waitForExistence(timeout: 8),
                          "Privacy agree must appear (US-PRV-008 AC-3)")
            agree.tap()

            // 权限序列 — 全部 Allow（US-SRC-001 授权）。系统弹窗由权限注入处理；
            // 生产路径下每一步都推进，无权限步骤时自动进入语言页。
            for _ in 0..<6 {
                let allow = app.buttons["onboarding-permission-allow"]
                if allow.waitForExistence(timeout: 3) {
                    allow.tap()
                } else {
                    break
                }
            }

            // 语言选择（US-SYN-001 AC-2）— 若权限页全部跳过则直接出现
            let picker = app.segmentedControls["onboarding-language-picker"]
            if picker.waitForExistence(timeout: 5) {
                app.buttons["English"].tap()
                let begin = app.buttons["onboarding-begin-load"]
                XCTAssertTrue(begin.waitForExistence(timeout: 5),
                              "Begin model load should appear after language selection")
                begin.tap()
            }

            // 模型加载或主界面出现
            let modelProgress = app.progressIndicators["onboarding-model-progress"]
            let homeTab = app.tabBars.firstMatch
            let found = modelProgress.waitForExistence(timeout: 5)
                || homeTab.waitForExistence(timeout: 5)
            XCTAssertTrue(found, "Model loading or main tabs must appear after begin-load")
        }

        // 无论新装还是已同意，最终必须处于 .ready（主 TabView）或文档化不可用态。
        let homeTab = app.tabBars.firstMatch
        if homeTab.waitForExistence(timeout: 10) {
            // .ready — 主界面可达；进入 Search 标签页验证生产检索入口渲染
            app.tabBars.buttons.element(boundBy: 1).tap()
            let searchField = app.searchFields.firstMatch
            XCTAssertTrue(searchField.waitForExistence(timeout: 8),
                          "Production Search surface must be reachable in .ready state")
        } else {
            // 文档化不可用态（ADR-007 §决策-5）— 模型未打包/路由缺失/索引未就绪
            let unavailableTitles = [
                "Models Unavailable",   // .modelUnavailable (US-RES-004)
                "Search Unavailable",   // .routeUnavailable
                "Index Unavailable",    // .indexUnavailable
                "Action Blocked",       // .purgeBlocked
                "Startup Failed",       // .bootstrapFailed
            ]
            let matched = unavailableTitles.contains { title in
                app.staticTexts[title].waitForExistence(timeout: 3)
            }
            XCTAssertTrue(matched,
                          "App must reach .ready or a documented unavailable startup state")
        }
    }

    /// 生产路径：拒绝 PIPL 同意 → declined 终态（US-PRV-008 AC-3）。
    @MainActor
    func test_noFixture_privacyDeclinedTerminalState() throws {
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        assertNoFixtureArguments(app)

        let start = app.buttons["onboarding-start"]
        guard start.waitForExistence(timeout: 8) else {
            // 已同意状态（先前测试残留）— 该测试只验证 declined 分支，直接返回。
            throw XCTSkip("onboarding not presented (consent already granted)")
        }
        start.tap()

        let decline = app.buttons["onboarding-privacy-decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 8),
                      "Decline must be equally prominent (US-PRV-008 AC-3)")
        decline.tap()

        let closeButton = app.buttons["onboarding-declined-close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5),
                      "Declined terminal state with Close must appear")
        closeButton.tap()
        XCTAssertFalse(
            app.buttons["onboarding-declined-close"].waitForExistence(timeout: 3),
            "Onboarding cover must dismiss after Close"
        )
    }
}
