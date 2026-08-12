// ==========================================
// File: LocalizationAccessibilityUITests.swift
// Spec: docs/01-spec/用户故事与验收标准规格书.md → US-DIS-001 (unified app language),
//       US-DIS-003 (localized states), US-DIS-004 (accessibility)
// Task: 3F.10 - i18n, accessibility and production errors
// AC coverage: US-DIS-001 AC-1 (single App Language setting), US-RES-002 AC-3 (auto-pause toggle default ON)
// Architecture: AGENTS.md §9.1 (stable accessibility identifiers, no coordinates)
// Generated: 2026-08-12
// ==========================================

import XCTest

/// Localization/AX surface verification for 3F.10. Identifier-based queries only so the
/// journeys stay language-independent (labels resolve from the String Catalog).
final class LocalizationAccessibilityUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// US-DIS-001 AC-1: the Settings surface exposes exactly one App Language picker with
    /// the follow-system / zh-Hans / en-US options.
    @MainActor
    func test_settingsAppLanguagePicker() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-language", "en-US"]
        app.launch()

        app.tabBars.buttons["Settings"].tap()

        let picker = app.descendants(matching: .any)["settings-app-language"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "App Language picker must exist (US-DIS-001 AC-1)")

        picker.tap()
        XCTAssertTrue(app.buttons["Follow System"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Simplified Chinese"].exists)
        XCTAssertTrue(app.buttons["English"].exists)
    }

    /// US-RES-002 AC-3: the low-power auto-pause toggle exists in Settings and defaults ON.
    @MainActor
    func test_settingsLowPowerAutoPauseToggleDefaultOn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-language", "en-US"]
        app.launch()

        app.tabBars.buttons["Settings"].tap()

        let toggle = app.switches["settings-low-power-auto-pause"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "low-power auto-pause toggle must exist")
        XCTAssertEqual(toggle.value as? String, "1", "low-power auto-pause must default to ON (US-RES-002 AC-3)")
    }

    /// US-DIS-003 AC-1: tab-bar labels resolve from the String Catalog (English default locale).
    @MainActor
    func test_tabBarLabelsLocalized() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-skip-consent", "-ui-language", "en-US"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Search"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
    }
}
