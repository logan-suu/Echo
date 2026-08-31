// ==========================================
// 文件: OnboardingFixtureLoader.swift
// i18n: User-facing literals are backed by Localizable.xcstrings (zh-Hans + en-US).
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-PRV-008 (PIPL 隐私同意 AC-1~3),
//            US-SRC-001 AC-6 (首次授权 iCloud 下载提示 + Open Settings),
//            US-SYN-001 AC-2 (语言选择 + 繁体映射提示)
//            docs/ui/echo-memory-canvas-style.md §15 (引导流程), §3.3 (Task surfaces),
//            UIAutomation/Fixtures/README.md (Fixture 规范),
//            docs/ui/testing-and-artifacts.md §2.1 (fixture 可确定性解码)
// 任务: 3.11 - 引导流程：欢迎页 + PIPL 隐私同意 + 权限序列 + 语言选择 + 首次模型加载
// AC 覆盖: US-PRV-008 AC-1 ✅ (隐私摘要), AC-2 ✅ (目的/方式/种类/保留期限/本地处理声明),
//          AC-3 ✅ (同意/拒绝同等醒目), US-SRC-001 AC-6 ✅ (iCloud 提示 + Open Settings),
//          US-SYN-001 AC-2 ✅ (zh-Hans/en-US 选择 + 映射提示), 首次模型加载进度 ✅ (4 模型确定性 fixture)
//          契约 fixture IDs: onboarding-welcome / onboarding-privacy-consent / onboarding-permissions /
//                            onboarding-permission-denied / onboarding-language /
//                            onboarding-model-loading / onboarding-completed / onboarding-declined
// 架构约束: 确定性、离线、可复现; 不访问网络或生产数据库 (docs/ui/architecture.md §3 Fixture Loader);
//           fixture ID 必须与 UIAutomation/Fixtures/onboarding/*.json 对齐
// 生成时间: 2026-08-03
// ==========================================

import Foundation

/// 引导流程当前步骤 (echo-memory-canvas §15 五步 + declined 退出)。
enum OnboardingStep: String, CaseIterable, Sendable, Equatable {
    /// Step 1 欢迎页 (§15.2)
    case welcome
    /// Step 2 PIPL 隐私同意 (§15.3)
    case privacyConsent
    /// Step 3 权限序列 (§15.4)
    case permissions
    /// 权限被拒绝 → 显示"前往设置" (§15.4 拒绝后)
    case permissionDenied
    /// Step 4 语言选择 (§15.5)
    case language
    /// Step 5 首次模型加载 (§15.6)
    case modelLoading
    /// 引导完成 → 进入主界面
    case completed
    /// 用户拒绝 PIPL 同意 → 退出状态 (US-PRV-008 AC-3)
    case declined
}

/// 权限步骤 — 照片→通知→位置→健康 (echo-memory-canvas §15.4)。
struct OnboardingPermission: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let purpose: String
    let systemImage: String
    /// 照片步骤的 iCloud 下载提示 (US-SRC-001 AC-6)
    var icloudHint: String?
    /// iCloud 提示中的"前往设置"按钮文案 (US-SRC-001 AC-6)
    var openSettingsLabel: String?
}

/// 确定性引导流程 Fixture — Preview / 单元测试 / Live Sim Review 注入。
enum OnboardingFixtureLoader {
    /// 根据 fixture ID 返回确定性 ``OnboardingFixture``。
    /// 无效 ID 返回 welcome fixture（不抛错，保持确定性降级）。
    static func load(_ fixtureID: String) -> OnboardingFixture {
        switch fixtureID {
        case "onboarding-privacy-consent":
            return OnboardingFixture(
                currentStep: .privacyConsent,
                privacyConsent: .undecided,
                permissionIndex: 0,
                permissionSteps: permissionSteps,
                privacySummary: privacySummary,
                declinedMessage: nil,
                selectedLanguage: nil,
                mappingHintVisible: false
            )

        case "onboarding-permissions":
            return OnboardingFixture(
                currentStep: .permissions,
                privacyConsent: .agreed,
                permissionIndex: 0,
                permissionSteps: permissionSteps,
                privacySummary: privacySummary,
                declinedMessage: nil,
                selectedLanguage: nil,
                mappingHintVisible: false
            )

        case "onboarding-permission-denied":
            return OnboardingFixture(
                currentStep: .permissionDenied,
                privacyConsent: .agreed,
                permissionIndex: 0,
                permissionSteps: permissionSteps,
                privacySummary: privacySummary,
                declinedMessage: deniedMessage,
                selectedLanguage: nil,
                mappingHintVisible: false
            )

        case "onboarding-language":
            return OnboardingFixture(
                currentStep: .language,
                privacyConsent: .agreed,
                permissionIndex: permissionSteps.count,
                permissionSteps: permissionSteps,
                privacySummary: privacySummary,
                declinedMessage: nil,
                selectedLanguage: nil,
                mappingHintVisible: false
            )

        case "onboarding-model-loading":
            return OnboardingFixture(
                currentStep: .modelLoading,
                privacyConsent: .agreed,
                permissionIndex: permissionSteps.count,
                permissionSteps: permissionSteps,
                privacySummary: privacySummary,
                declinedMessage: nil,
                selectedLanguage: "en-US",
                mappingHintVisible: false
            )

        case "onboarding-completed":
            return OnboardingFixture(
                currentStep: .completed,
                privacyConsent: .agreed,
                permissionIndex: permissionSteps.count,
                permissionSteps: permissionSteps,
                privacySummary: privacySummary,
                declinedMessage: nil,
                selectedLanguage: "en-US",
                mappingHintVisible: false
            )

        case "onboarding-declined":
            return OnboardingFixture(
                currentStep: .declined,
                privacyConsent: .declined,
                permissionIndex: 0,
                permissionSteps: permissionSteps,
                privacySummary: privacySummary,
                declinedMessage: deniedMessage,
                selectedLanguage: nil,
                mappingHintVisible: false
            )

        default:
            return OnboardingFixture(
                currentStep: .welcome,
                privacyConsent: .undecided,
                permissionIndex: 0,
                permissionSteps: permissionSteps,
                privacySummary: privacySummary,
                declinedMessage: nil,
                selectedLanguage: nil,
                mappingHintVisible: false
            )
        }
    }

    /// 全部已注册 fixture ID
    static var availableFixtureIDs: [String] {
        [
            "onboarding-welcome",
            "onboarding-privacy-consent",
            "onboarding-permissions",
            "onboarding-permission-denied",
            "onboarding-language",
            "onboarding-model-loading",
            "onboarding-completed",
            "onboarding-declined",
        ]
    }

    // MARK: - Deterministic Data

    /// 隐私同意状态 (US-PRV-008)
    enum PrivacyConsent: Sendable, Equatable {
        case undecided
        case agreed
        case declined
    }

    /// PIPL 隐私政策摘要 — 目的/方式/种类/保留期限/本地处理声明 (US-PRV-008 AC-2)
    static var privacySummary: String {
        OnboardingContentDefaults.privacySummary
    }

    /// 权限拒绝提示 (US-SRC-001 AC-6 情境下照片被拒)
    static var deniedMessage: String {
        OnboardingContentDefaults.deniedMessage
    }

    /// 权限序列 — 照片→通知→位置→健康 (echo-memory-canvas §15.4)
    static var permissionSteps: [OnboardingPermission] {
        OnboardingContentDefaults.permissionSteps
    }

    /// 支持的语言 (US-SYN-001 AC-2)
    static let supportedLanguages: [String] = ["zh-Hans", "en-US"]

    /// 繁体/方言映射提示 (US-SYN-001 AC-2) — 首次启动提示一次
    static let mappingHint: String = OnboardingContentDefaults.mappingHint
}

/// 确定性引导流程 fixture 载荷 — 由 fixture loader 返回，驱动引导步骤状态。
struct OnboardingFixture: Sendable {
    let currentStep: OnboardingStep
    let privacyConsent: OnboardingFixtureLoader.PrivacyConsent
    let permissionIndex: Int
    let permissionSteps: [OnboardingPermission]
    let privacySummary: String
    var declinedMessage: String?
    let selectedLanguage: String?
    let mappingHintVisible: Bool
}
