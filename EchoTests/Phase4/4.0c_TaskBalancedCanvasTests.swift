// ==========================================
// File: 4.0c_TaskBalancedCanvasTests.swift
// Specification: docs/05-planning/开发计划安排文档.md → Task 4.0c
// Task: 4.0c - Task Balanced Canvas for settings, onboarding and runtime status
// AC coverage: AC-1 (Task contracts), AC-2 (shared visual identity),
//              AC-3 (Apple-native containers), AC-4 (truthful states),
//              AC-5 (accessibility and motion), AC-6 (v1 contract references)
// Architecture: AGENTS.md §17.2 (Task surfaces use system containers and never masonry)
// Generated: 2026-09-02
// ==========================================

import Foundation
import Testing
@testable import Echo

@Suite("TaskBalancedCanvasTests", .serialized)
@MainActor
struct TaskBalancedCanvasTests {
    private let surfaces: [(path: String, id: String, layout: String)] = [
        ("settings", "settings", "form"),
        ("onboarding", "onboarding", "form"),
        ("awakening-settings", "awakening-settings", "form"),
        ("background-tasks", "background-tasks", "sheet"),
        ("degradation-banner", "degradation-banner", "single_column"),
        ("resume-progress", "resume-progress-prompt", "alert"),
    ]

    @Test("AC-1: all six Task surfaces use Balanced Canvas without masonry")
    func test_AC1_taskSurfaceContracts() throws {
        for surface in surfaces {
            let contract = try loadJSON("UIAutomation/Contracts/instances/\(surface.path)-surface.json")
            #expect(contract["designProfileId"] as? String == "echo-memory-canvas")
            #expect(contract["surfaceFamily"] as? String == "task")
            #expect(contract["layoutMode"] as? String == surface.layout)
            #expect(contract["masonryEnabled"] as? Bool == false)
            #expect((contract["relatedStories"] as? [String])?.isEmpty == false)
        }
    }

    @Test("AC-2: all six Task views consume the shared visual identity")
    func test_AC2_taskViewsUseSharedVisualIdentity() throws {
        for path in taskViewPaths {
            let source = try loadSource(path)
            #expect(source.contains("@Environment(\\.echoDesignProfile)"))
            #expect(source.contains("EchoContainer") || source.contains("EchoStatusPresentation"))
            #expect(source.contains("EchoActionButtonStyle"))
            #expect(source.contains("EchoColorToken.groupedBackground.color"))
            #expect(!source.contains("LazyVGrid"))
            #expect(!source.contains("DiscoveryMasonry"))
        }
    }

    @Test("AC-3: Task information architecture remains Apple-native")
    func test_AC3_systemContainersRemainNative() throws {
        #expect(try loadSource("Echo/UI/Settings/SettingsView.swift").contains("Form {"))
        #expect(try loadSource("Echo/UI/Onboarding/OnboardingView.swift").contains("TabView(selection:"))
        #expect(try loadSource("Echo/UI/Awakening/AwakeningSettingsView.swift").contains("Form {"))
        #expect(try loadSource("Echo/UI/BackgroundTask/BackgroundTaskPanelView.swift").contains("List {"))
        #expect(try loadSource("Echo/UI/ResumeProgress/ResumeProgressPromptView.swift").contains(".confirmationDialog("))
    }

    @Test("AC-4: consent, migration, schedule and resume copy remain truthful")
    func test_AC4_truthfulPresentationBoundaries() throws {
        let onboarding = try loadSource("Echo/UI/Onboarding/OnboardingView.swift")
        let settings = try loadSource("Echo/UI/Settings/SettingsView.swift")
        let awakening = try loadSource("Echo/UI/Awakening/AwakeningSettingsView.swift")
        let resume = try loadSource("Echo/UI/ResumeProgress/ResumeProgressViewModel.swift")
        let plan = try loadSource("docs/05-planning/开发计划安排文档.md")
        let style = try loadSource("docs/ui/echo-memory-canvas-style.md")
        let uiReadme = try loadSource("docs/ui/README.md")
        let uiArchitecture = try loadSource("docs/ui/architecture.md")

        #expect(onboarding.components(separatedBy: ".buttonStyle(consentActionStyle)").count - 1 == 2)
        #expect(settings.contains("encrypted Echo migration package"))
        #expect(settings.contains("Original media stays in its system source and is not exported"))
        #expect(!awakening.contains("Daily 9:00 AM"))
        #expect(!awakening.contains("runs daily at 9:00 AM"))
        #expect(resume.contains("Task continuation is unavailable because no production task reconstruction boundary is connected."))
        #expect(resume.contains("Task restart is unavailable because no production task launcher is connected."))
        #expect(!plan.contains("重启恢复的基本闭环"))
        #expect(!style.contains("照片→通知→位置→健康"))
        #expect(settings.contains("title: EchoStrings.tr(\"Unable to Load Settings\")"))
        #expect(settings.contains("message: EchoStrings.tr(\"Please try again.\")"))
        let resumePrompt = try loadSource("Echo/UI/ResumeProgress/ResumeProgressPromptView.swift")
        #expect(resumePrompt.contains("title: EchoStrings.tr(\"Unable to check saved progress\")"))
        #expect(uiReadme.contains("最后同步**："))
        #expect(uiArchitecture.contains("`DeviceMigrationActor` 负责编排"))
        #expect(uiArchitecture.contains("`DeviceMigrationService.exportPackage` / `importPackage`"))
        #expect(uiArchitecture.contains("禁止使用 `PhotoSearchMigrationActor`"))
    }

    @Test("AC-5: custom Task motion respects Reduce Motion")
    func test_AC5_motionAndAccessibilityPolicy() throws {
        let onboarding = try loadSource("Echo/UI/Onboarding/OnboardingView.swift")
        let degradation = try loadSource("Echo/UI/Degradation/DegradationBannerView.swift")

        #expect(onboarding.contains("EchoAccessibilityPolicy.allowsMotion"))
        #expect(degradation.contains("EchoAccessibilityPolicy.allowsMotion"))
        #expect(onboarding.contains("accessibilityReduceMotion"))
        #expect(degradation.contains("accessibilityReduceMotion"))
    }

    @Test("AC-6: Task state, action and journey contracts are v1-compatible and fully resolved")
    func test_AC6_taskContractGraphResolves() throws {
        let directory = repositoryRoot.appendingPathComponent("UIAutomation/Contracts/instances")
        let filenames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var declaredActionIDs = Set<String>()
        var referencedActionIDs = Set<String>()

        for surface in surfaces {
            let surfaceContract = try loadJSON("UIAutomation/Contracts/instances/\(surface.path)-surface.json")
            let stateIDs = try #require(surfaceContract["states"] as? [String])
            let stateFiles = filenames.filter { $0.hasPrefix("\(surface.path)-state-") }
            var statesByID: [String: [String: Any]] = [:]
            for filename in stateFiles {
                let state = try loadJSON("UIAutomation/Contracts/instances/\(filename)")
                if let stateID = state["stateId"] as? String {
                    statesByID[stateID] = state
                }
            }

            for stateID in stateIDs {
                let state = try #require(statesByID[stateID])
                #expect(state["$schema"] as? String == "https://echo-ui-automation/schemas/contracts/state/v1")
                #expect(state["surfaceId"] as? String == surface.id)
                #expect(state["stateId"] as? String == stateID)
                #expect(state["dataConditions"] is [String: Any])
                let actions = try #require(state["allowedActions"] as? [String])
                referencedActionIDs.formUnion(actions)
                #expect(isV1Compatible(state["version"] as? String))
            }
            #expect(Set(statesByID.keys) == Set(stateIDs))

            let actionFiles = filenames.filter { $0.hasPrefix("\(surface.path)-action-") }
            for filename in actionFiles {
                let action = try loadJSON("UIAutomation/Contracts/instances/\(filename)")
                #expect(action["$schema"] as? String == "https://echo-ui-automation/schemas/contracts/action/v1")
                let actionID = try #require(action["actionId"] as? String)
                declaredActionIDs.insert(actionID)
                #expect(action["source"] is String)
                #expect(action["targetIntent"] is String)
                #expect(isV1Compatible(action["version"] as? String))
            }

            let journeyFiles = filenames.filter { $0.hasPrefix("\(surface.path)-journey-") }
            for filename in journeyFiles {
                let journey = try loadJSON("UIAutomation/Contracts/instances/\(filename)")
                #expect(journey["$schema"] as? String == "https://echo-ui-automation/schemas/contracts/journey/v1")
                #expect(journey["preconditionFixtures"] is [String])
                #expect(isV1Compatible(journey["version"] as? String))
                let steps = try #require(journey["steps"] as? [[String: Any]])
                for (index, step) in steps.enumerated() {
                    #expect(step["surfaceId"] as? String == surface.id)
                    #expect(stateIDs.contains(step["stateId"] as? String ?? ""))
                    if let actionID = step["actionId"] as? String {
                        referencedActionIDs.insert(actionID)
                    } else {
                        #expect(index == steps.indices.last)
                    }
                }
            }
        }

        #expect(referencedActionIDs.isSubset(of: declaredActionIDs))
        #expect(declaredActionIDs.isSubset(of: referencedActionIDs))

        #expect(isV1Compatible("1.0.0"))
        #expect(isV1Compatible("1.12.3"))
        #expect(!isV1Compatible("1"))
        #expect(!isV1Compatible("1.alpha"))
        #expect(!isV1Compatible("1.0.0.0"))

        for schema in ["surface", "state", "action", "journey"] {
            let contract = try loadJSON("UIAutomation/Contracts/schemas/\(schema)-v1.json")
            let required = try #require(contract["required"] as? [String])
            #expect(required.contains("version"))
        }

        let awakeningError = try loadJSON(
            "UIAutomation/Contracts/instances/awakening-settings-state-error.json"
        )
        #expect(awakeningError["allowedActions"] as? [String] == ["awakening.retry"])
        let awakeningRetry = try loadJSON(
            "UIAutomation/Contracts/instances/awakening-settings-action-retry.json"
        )
        #expect(awakeningRetry["targetIntent"] as? String == "AwakeningSettingsViewModel.loadSettings()")
        let awakeningSurface = try loadJSON(
            "UIAutomation/Contracts/instances/awakening-settings-surface.json"
        )
        let awakeningOutputs = try #require(awakeningSurface["outputs"] as? [String: Any])
        let awakeningTargets = try #require(awakeningOutputs["interactionTargets"] as? String)
        #expect(awakeningTargets.contains("Task 4.0f"))

        let deleteAction = try loadJSON(
            "UIAutomation/Contracts/instances/settings-action-startDeleteData.json"
        )
        let deleteOutcome = try #require(deleteAction["expectedOutcome"] as? String)
        #expect(deleteOutcome.contains("not available"))

        let closeAction = try loadJSON(
            "UIAutomation/Contracts/instances/background-tasks-action-close.json"
        )
        #expect(closeAction["targetIntent"] as? String == "BackgroundTaskViewModel.closePanel()")
        let backgroundSource = try loadSource("Echo/UI/BackgroundTask/BackgroundTaskPanelView.swift")
        #expect(backgroundSource.contains("viewModel.closePanel()"))

        let settingsAction = try loadJSON(
            "UIAutomation/Contracts/instances/degradation-banner-action-openSettings.json"
        )
        #expect(settingsAction["targetIntent"] as? String == "DegradationBannerView.openSystemSettings()")
        let degradationSource = try loadSource("Echo/UI/Degradation/DegradationBannerView.swift")
        #expect(degradationSource.contains("private func openSystemSettings()"))

        let onboardingSurface = try loadJSON(
            "UIAutomation/Contracts/instances/onboarding-surface.json"
        )
        let onboardingOutputs = try #require(onboardingSurface["outputs"] as? [String: Any])
        let visibleContent = try #require(onboardingOutputs["visibleContent"] as? String)
        #expect(visibleContent.contains(
            "privacy consent -> optional Connect Photos choice -> language"
        ))

        let validator = try loadSource("Scripts/validate_accessibility_contracts.py")
        #expect(validator.contains("null actionId is allowed only on the final step"))

        let acceptancePolicy = try loadJSON("UIAutomation/Policies/acceptance-policy.json")
        let gates = try #require(acceptancePolicy["verification_gates"] as? [String: Any])
        #expect(gates["task_truthfulness"] == nil)
        for (gateID, taskID) in [
            ("task_presentation_truthfulness", "4.0c"),
            ("task_progressive_permissions", "4.0f"),
            ("task_recovery_truthfulness", "4.0g"),
        ] {
            let gate = try #require(gates[gateID] as? [String: Any])
            #expect(gate["applicableTaskIds"] as? [String] == [taskID])
            #expect(gate["requiredAssertions"] is [String: Any])
        }
    }

    private var taskViewPaths: [String] {
        [
            "Echo/UI/Settings/SettingsView.swift",
            "Echo/UI/Onboarding/OnboardingView.swift",
            "Echo/UI/Awakening/AwakeningSettingsView.swift",
            "Echo/UI/BackgroundTask/BackgroundTaskPanelView.swift",
            "Echo/UI/Degradation/DegradationBannerView.swift",
            "Echo/UI/ResumeProgress/ResumeProgressPromptView.swift",
        ]
    }

    private func isV1Compatible(_ version: String?) -> Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "1" else { return false }
        return parts.dropFirst().allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private func loadJSON(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func loadSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private var repositoryRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }
}
