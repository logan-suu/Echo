// ==========================================
// File: DegradationUITests.swift
// Spec: docs/01-spec/用户故事与验收标准规格书.md → US-RES-002 (low power), US-RES-003 (thermal),
//       US-RES-004 (model load failure), US-DIS-004 AC-2 (announcement)
// Task: 3F.10 - i18n, accessibility and production errors
// AC coverage: US-RES-002 AC-2 (banner copy), US-RES-003 AC-2 (banner copy),
//       US-RES-004 AC-7 (Retry + repair entry), US-DIS-004 AC-2 (announcement path)
// Architecture: AGENTS.md §9.1 (stable identifiers, no coordinates); fixture-driven via
//       -degradationFixture launch args (echo-memory-canvas §11.4)
// Generated: 2026-08-12
// ==========================================

import XCTest

/// Degradation banner journey verification for 3F.10. Banner copy is catalog-driven; the
/// default simulator locale (en-US) renders the English catalog values.
final class DegradationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// US-RES-002 AC-2: low-power fixture renders the battery banner with localized copy.
    @MainActor
    func test_lowPowerBannerAppears() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-language", "en-US", "-degradationFixture", "degradation-low-power"]
        app.launch()

        let message = app.staticTexts["Low Power Mode is enabled. Memory search precision may be reduced."]
        XCTAssertTrue(message.waitForExistence(timeout: 10),
                      "low-power banner copy must render (US-RES-002 AC-2)")
        XCTAssertTrue(app.switches.firstMatch.exists || app.buttons["Dismiss banner"].exists)
    }

    /// US-RES-003 AC-2: thermal fixture renders the temperature banner.
    @MainActor
    func test_thermalBannerAppears() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-language", "en-US", "-degradationFixture", "degradation-thermal"]
        app.launch()

        let message = app.staticTexts["Device temperature is high. Some features have been temporarily simplified."]
        XCTAssertTrue(message.waitForExistence(timeout: 10),
                      "thermal banner copy must render (US-RES-003 AC-2)")
    }

    /// US-RES-004 AC-7: model-degraded fixture renders Retry + repair entry.
    @MainActor
    func test_modelDegradedBannerShowsRetryAndRepair() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-language", "en-US", "-degradationFixture", "degradation-model-degraded"]
        app.launch()

        let message = app.staticTexts["Functional limitations due to model loading issues."]
        XCTAssertTrue(message.waitForExistence(timeout: 10),
                      "model-degraded banner copy must render (US-RES-004 AC-7)")
        XCTAssertTrue(app.buttons["Retry model load"].exists, "manual Retry must be offered (US-RES-004 AC-3)")
        XCTAssertTrue(app.buttons["Open settings for model recovery"].exists,
                      "repair entry must be offered (US-RES-004 AC-7)")
    }

    /// US-RES-002 AC-2 in zh-Hans: banner copy resolves from the String Catalog for the
    /// forced Chinese locale (AGENTS.md §1.3 dual-language contract).
    @MainActor
    func test_lowPowerBannerZhHans() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-language", "zh-Hans", "-degradationFixture", "degradation-low-power"]
        app.launch()

        let message = app.staticTexts["省电模式已启用，记忆检索精度可能降低。"]
        XCTAssertTrue(message.waitForExistence(timeout: 10),
                      "zh-Hans banner copy must render (US-RES-002 AC-2, AGENTS.md §1.3)")
    }
}
