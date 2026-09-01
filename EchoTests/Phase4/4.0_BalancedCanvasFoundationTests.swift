// ==========================================
// File: 4.0_BalancedCanvasFoundationTests.swift
// Spec: docs/ui/echo-memory-canvas-style.md §§1-4, 8-9
// Task: 4.0 - Balanced Canvas design system and AppShell foundation
// AC coverage: AC-1 (contracts), AC-2 (shared tokens/components),
//              AC-3 (Apple-native AppShell), AC-4 (AX/i18n/motion)
// Architecture: AGENTS.md §17.1-17.2; docs/ui/architecture.md §§3, 8
// Generated: 2026-08-31
// ==========================================

import Foundation
import SwiftUI
import Testing
@testable import Echo

@Suite("BalancedCanvasFoundationTests", .serialized)
@MainActor
struct BalancedCanvasFoundationTests {
    @Test("AC-1: DesignProfile identity and supported families match approved contract")
    func test_AC1_designProfileIdentity() {
        let profile = EchoDesignProfile.balancedCanvas

        #expect(profile.id == "echo-memory-canvas")
        #expect(profile.baseProfile == "apple-native")
        #expect(profile.version == "1.2.0")
        #expect(Set(profile.supportedSurfaceFamilies) == Set(EchoSurfaceFamily.allCases))
        #expect(EchoAppShellContract.hostedSurfaceFamilies == Set(EchoSurfaceFamily.allCases))
    }

    @Test("AC-1: DesignProfile, Surface schema, instance and policy agree semantically")
    func test_AC1_contractsParseAndAgree() throws {
        let profileInstance = try loadJSON("UIAutomation/Contracts/instances/design-profile-echo-memory-canvas.json")
        let profileSchema = try loadJSON("UIAutomation/Contracts/schemas/design-profile-v1.json")
        let surfaceSchema = try loadJSON("UIAutomation/Contracts/schemas/surface-v1.json")
        let policy = try loadJSON("UIAutomation/Policies/acceptance-policy.json")

        #expect(profileInstance["$schema"] as? String == profileSchema["$id"] as? String)
        #expect(profileInstance["profileId"] as? String == EchoDesignProfile.balancedCanvas.id)
        #expect(profileInstance["baseProfile"] as? String == EchoDesignProfile.balancedCanvas.baseProfile)
        #expect(surfaceSchema["$id"] as? String == "https://echo-ui-automation/schemas/contracts/surface/v1")

        let profileProperties = try #require(profileSchema["properties"] as? [String: Any])
        let schemaReference = try #require(profileProperties["$schema"] as? [String: Any])
        #expect(schemaReference["const"] as? String == profileSchema["$id"] as? String)

        let gates = try #require(policy["verification_gates"] as? [String: Any])
        let appWide = try #require(gates["app_wide_visual_profile"] as? [String: Any])
        let familyRules = try #require(gates["surface_family_rules"] as? [String: Any])
        let warmAccentGate = try #require(gates["warm_accent_pair"] as? [String: Any])
        #expect(appWide["required"] as? Bool == true)
        #expect(familyRules["required"] as? Bool == true)
        #expect(warmAccentGate["required"] as? Bool == true)

        let visualLanguage = try #require(profileInstance["globalVisualLanguage"] as? [String: Any])
        let warmAccent = try #require(visualLanguage["warmAccent"] as? [String: Any])
        #expect(warmAccent["assetName"] as? String == "AccentColor")
        #expect(warmAccent["onAssetName"] as? String == "OnAccentColor")
        #expect(warmAccent["lightSRGB"] as? String == "#A64B32")
        #expect(warmAccent["darkSRGB"] as? String == "#E08A68")
        #expect(warmAccent["onLightSRGB"] as? String == "#FFFFFF")
        #expect(warmAccent["onDarkSRGB"] as? String == "#1C1C1E")

        let approvalPoints = try #require(policy["approval_points"] as? [String: Any])
        let deliveryApproval = try #require(approvalPoints["fixed_delivery_approval"] as? [String: Any])
        #expect(deliveryApproval["requires_human"] as? Bool == true)
        #expect(deliveryApproval["auto_approve"] as? Bool == false)
    }

    @Test("AC-2: semantic token APIs cover the approved visual language")
    func test_AC2_semanticTokens() {
        #expect(Set(EchoTypographyToken.allCases) == [
            .title, .subtitle, .body, .metadata, .caption, .action,
        ])
        #expect(EchoSpacingToken.compact.points == 8)
        #expect(EchoSpacingToken.normal.points == 12)
        #expect(EchoSpacingToken.grouped.points == 16)
        #expect(EchoSpacingToken.section.points == 20)
        #expect(Set(EchoColorToken.allCases) == [
            .primaryText,
            .secondaryText,
            .canvasBackground,
            .groupedBackground,
            .cardBackground,
            .fill,
            .separator,
            .warmAccent,
            .onWarmAccent,
            .success,
            .warning,
            .blocking,
            .conflict,
        ])
        #expect(EchoRadiusToken.image.points == 12)
        #expect(EchoRadiusToken.card.points == 16)
        #expect(EchoRadiusToken.groupedContainer.points == 20)
        #expect(Set(EchoContainerLevel.allCases) == [.canvas, .section, .card, .emphasized])
        #expect(Set(EchoStatusRole.allCases) == [.informational, .success, .warning, .blocking, .conflict])
        #expect(Set(EchoActionRole.allCases) == [.primary, .secondary, .destructive, .recovery])
    }

    @Test("AC-2: shared components are constructible without feature-domain style switches")
    func test_AC2_sharedComponentsConstruct() {
        _ = EchoSectionHeader(title: "Section", subtitle: "Supporting context")
        _ = EchoContainer(level: .card) { Text("Content") }
        _ = EchoMetadataGroup { Text("Metadata") }
        _ = EchoStatusPresentation(
            role: .informational,
            systemImage: "info.circle",
            title: "Status",
            message: "Status detail"
        )
        _ = EchoActionButtonStyle(role: .primary)
        #expect(Bool(true))
    }

    @Test("AC-2: approved warm accent assets and action foreground are materialized")
    func test_AC2_warmAccentPairMaterialized() throws {
        let accent = try loadJSON("Echo/Assets.xcassets/AccentColor.colorset/Contents.json")
        let onAccent = try loadJSON("Echo/Assets.xcassets/OnAccentColor.colorset/Contents.json")

        try assertColorAsset(
            accent,
            light: ["red": "0.650980", "green": "0.294118", "blue": "0.196078"],
            dark: ["red": "0.878431", "green": "0.541176", "blue": "0.407843"]
        )
        try assertColorAsset(
            onAccent,
            light: ["red": "1.000000", "green": "1.000000", "blue": "1.000000"],
            dark: ["red": "0.109804", "green": "0.109804", "blue": "0.117647"]
        )
        #expect(contrastRatio(foreground: [1, 1, 1], background: [166 / 255, 75 / 255, 50 / 255]) >= 4.5)
        #expect(
            contrastRatio(
                foreground: [28 / 255, 28 / 255, 30 / 255],
                background: [224 / 255, 138 / 255, 104 / 255]
            ) >= 4.5
        )

        let foundation = try loadSource("Echo/UI/SharedComponents/EchoDesignFoundation.swift")
        let components = try loadSource("Echo/UI/SharedComponents/EchoSharedComponents.swift")
        #expect(foundation.contains("case onWarmAccent"))
        #expect(foundation.contains("Color(\"OnAccentColor\")"))
        #expect(components.contains("EchoColorToken.onWarmAccent.color"))
    }

    @Test("AC-3: AppShell contract preserves Apple-native system containers")
    func test_AC3_appShellContract() {
        #expect(EchoAppShellContract.designProfileID == "echo-memory-canvas")
        #expect(EchoAppShellContract.usesNativeTabView)
        #expect(EchoAppShellContract.usesPerTabNavigationStack)
        #expect(EchoAppShellContract.usesNativeToolbarSearchAndModalChrome)
        #expect(!EchoAppShellContract.isContentSurface)
    }

    @Test("AC-3: AppRootView uses the iOS 18 native tab API and profile host")
    func test_AC3_appRootViewUsesNativeContainers() throws {
        let source = try loadSource("Echo/UI/AppShell/AppRootView.swift")

        #expect(source.contains("Tab(value:"))
        #expect(source.contains("NavigationStack"))
        #expect(source.contains(".echoAppShell()"))
        #expect(!source.contains(".tabItem"))
    }

    @Test("AC-4: accessibility policies adapt contrast and Reduce Motion")
    func test_AC4_accessibilityPolicies() {
        #expect(EchoAccessibilityPolicy.borderWidth(increasedContrast: false) == 1)
        #expect(EchoAccessibilityPolicy.borderWidth(increasedContrast: true) == 2)
        #expect(EchoAccessibilityPolicy.allowsMotion(reduceMotion: false))
        #expect(!EchoAccessibilityPolicy.allowsMotion(reduceMotion: true))
    }

    @Test("AC-4: shared components use Dynamic Type and accessibility environments")
    func test_AC4_sharedComponentAccessibilityWiring() throws {
        let source = try loadSource("Echo/UI/SharedComponents/EchoSharedComponents.swift")

        #expect(source.contains("EchoTypographyToken"))
        #expect(!source.contains(".font(.system(size:"))
        #expect(source.contains(".accessibilityElement(children: .combine)"))
        #expect(source.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(source.contains(".accessibilityHidden(true)"))
        #expect(source.contains("@Environment(\\.colorSchemeContrast)"))
        #expect(source.contains("@Environment(\\.accessibilityReduceMotion)"))
    }

    @Test("AC-4: AppShell labels have complete zh-Hans and en-US catalog values")
    func test_AC4_appShellLocalizationParity() throws {
        let catalog = try loadJSON("Echo/Resources/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])

        for key in ["Home", "Search", "Settings"] {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for locale in ["zh-Hans", "en-US"] {
                let localization = try #require(localizations[locale] as? [String: Any])
                let unit = try #require(localization["stringUnit"] as? [String: Any])
                let value = try #require(unit["value"] as? String)
                #expect(!value.isEmpty, "\(key) is missing \(locale)")
            }
        }
    }

    private func loadJSON(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func loadSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private var repositoryRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            root.deleteLastPathComponent()
        }
        return root
    }

    private func assertColorAsset(
        _ asset: [String: Any],
        light: [String: String],
        dark: [String: String]
    ) throws {
        let colors = try #require(asset["colors"] as? [[String: Any]])
        #expect(colors.count == 2)

        let lightColor = try #require(colors.first?["color"] as? [String: Any])
        let lightComponents = try #require(lightColor["components"] as? [String: String])
        #expect(lightComponents["red"] == light["red"])
        #expect(lightComponents["green"] == light["green"])
        #expect(lightComponents["blue"] == light["blue"])

        let darkEntry = try #require(colors.last)
        let appearances = try #require(darkEntry["appearances"] as? [[String: String]])
        #expect(appearances == [["appearance": "luminosity", "value": "dark"]])
        let darkColor = try #require(darkEntry["color"] as? [String: Any])
        let darkComponents = try #require(darkColor["components"] as? [String: String])
        #expect(darkComponents["red"] == dark["red"])
        #expect(darkComponents["green"] == dark["green"])
        #expect(darkComponents["blue"] == dark["blue"])
    }

    private func contrastRatio(foreground: [Double], background: [Double]) -> Double {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ components: [Double]) -> Double {
        let linear = components.map { component in
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
