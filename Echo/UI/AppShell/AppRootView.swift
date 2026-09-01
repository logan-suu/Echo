// ==========================================
// File: AppRootView.swift
// Specification: docs/ui/echo-memory-canvas-style.md §3.3; docs/ui/architecture.md §3
// Tasks: 3.0 (AppShell), 3F.1 (production composition), 4.0 (Balanced Canvas host)
// AC coverage: native TabView, per-tab NavigationStack, startup gates, shared profile host
// Architecture: AGENTS.md §8.1, §10.1, §17.2; AppShell hosts all surface families
// Generated: 2026-07-26; updated: 2026-08-31 (Task 4.0)
// ==========================================

import SwiftUI

// MARK: - AppRootView

/// Echo's system-native navigation host and startup gate.
///
/// AppShell is not a fourth content surface. It hosts Discovery, Focus, and Task
/// destinations while retaining the platform TabView, NavigationStack, toolbar,
/// search, and modal behaviors.
///
/// ## 启动门控 (ADR-007 §决策-1/2/5)
/// - .requiresConsent / .consentDeclined → 展示引导流程 (deny-by-default)
/// - .modelUnavailable / .routeUnavailable / .indexUnavailable → 对应不可用态
/// - .ready → 展示 TabView
///
/// ## 架构映射
/// - App Shell: 根导航 + 依赖装配
/// - ViewModel: AppViewModel (DI 容器)
/// - 数据流: AppComposition.startupState → AppRootView 门控
struct AppRootView: View {
    // MARK: - State

    /// App 级 ViewModel（DI 容器），由 EchoApp 注入
    @State private var viewModel = AppViewModel()

    /// Unified app language (US-DIS-001, 3F.10): drives .environment(\.locale) so every
    /// Text(LocalizedStringKey) re-resolves immediately on switch (AC-4, no restart).
    @State private var languageCenter = LanguageCenter.shared

    /// 应用自有 composition root (3F.1)
    @State private var composition = AppComposition.shared

    /// Onboarding ViewModel - first-launch flow (Task 3.11).
    /// 3F.1 fix: inject composition.consentStore so Agree persists consent immediately (US-PRV-008 AC-4)
    @State private var onboardingViewModel = OnboardingViewModel(
        consentStore: AppComposition.shared.consentStore,
        modelLoader: AppComposition.shared.modelLoader
    )

    /// Whether onboarding is presented (fullScreenCover, echo-memory-canvas §15.1)
    @State private var isOnboardingPresented = false

    /// First-appear flag - controls one-shot fixture injection
    @State private var hasHandledLaunchArguments = false

    /// Consent save failed on onboarding completion (surfaced instead of silently proceeding)
    @State private var consentPersistError = false

    // MARK: - Body

    var body: some View {
        Group {
            if consentPersistError {
                // Consent write failed on onboarding completion: surface instead of silently proceeding
                unavailableGate(title: EchoStrings.tr("Consent Not Saved"),
                                message: EchoStrings.tr("Your consent could not be saved. Restart Echo to try again."))
            } else {
                switch composition.startupState {
                case .requiresConsent:
                    onboardingGate

                case .consentDeclined:
                    // Declined consent is terminal: show a denial placeholder instead of
                    // re-presenting the onboarding cover (avoids the Close dead-loop)
                    unavailableGate(title: EchoStrings.tr("Consent Declined"),
                                    message: EchoStrings.tr("Echo cannot process your memories without consent. Reopen Echo to review the privacy policy."))

                case .modelUnavailable:
                    unavailableGate(title: EchoStrings.tr("Models Unavailable"),
                                    message: EchoStrings.tr("Required models could not be loaded. Reinstall Echo to restore them."))

                case .routeUnavailable:
                    unavailableGate(title: EchoStrings.tr("Search Unavailable"),
                                    message: EchoStrings.tr("The active index route is unavailable."))

                case .indexUnavailable:
                    unavailableGate(title: EchoStrings.tr("Index Unavailable"),
                                    message: EchoStrings.tr("Memory index is not ready yet."))

                case .purgeBlocked:
                    unavailableGate(title: EchoStrings.tr("Action Blocked"),
                                    message: EchoStrings.tr("The previous cleanup did not complete. Try again."))

                case .bootstrapFailed:
                    unavailableGate(title: EchoStrings.tr("Startup Failed"),
                                    message: EchoStrings.tr("Echo could not initialize its local storage. Reinstall Echo or restart the device."))

                default:
                    mainTabs
                }
            }
        }
        .echoAppShell()
        .environment(\.locale, languageCenter.locale)
        // iOS 18.x 无 TranslationSession 公开构造器 — 隐藏 host view 常驻获取 session (PR #61 review B-1)
        .background {
            TranslationSessionHostView()
        }
        .fullScreenCover(isPresented: $isOnboardingPresented) {
            OnboardingView(viewModel: onboardingViewModel,
                           onCompleted: {
                               isOnboardingPresented = false
                               handleOnboardingCompleted()
                           },
                           onDeclined: {
                               isOnboardingPresented = false
                               composition.declineConsent()
                           })
        }
        .onAppear {
            handleFirstAppear()
        }
    }

    // MARK: - Onboarding Gate

    /// deny-by-default: show onboarding while consent is required (US-PRV-008).
    /// Production reaches this branch via EchoApp.task bootstrap; tests use `-ui-fixture onboarding-*`.
    @ViewBuilder
    private var onboardingGate: some View {
        Color.clear
            .onAppear { isOnboardingPresented = true }
    }

    /// Shared blocking presentation for unavailable startup states.
    @ViewBuilder
    private func unavailableGate(title: String, message: String) -> some View {
        EchoContainer(level: .emphasized) {
            EchoStatusPresentation(
                role: .blocking,
                systemImage: "exclamationmark.triangle",
                title: title,
                message: message
            )
        }
        .frame(maxWidth: 560)
        .padding(EchoSpacingToken.section.points)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EchoColorToken.canvasBackground.color)
    }

    /// Sync consent into composition when onboarding completes (US-PRV-008 AC-4)
    private func handleOnboardingCompleted() {
        Task {
            do {
                if let language = onboardingViewModel.selectedLanguage {
                    let selection: LanguageCenter.AppLanguageSelection = language == "zh-Hans" ? .zhHans : .enUS
                    try await languageCenter.apply(
                        selection,
                        systemLanguage: LanguageCenter.systemLanguageIdentifier(),
                        privacyActor: composition.privacyActor
                    )
                }
                try await composition.acceptConsent(consentVersion: 1, policyVersion: 1)
            } catch {
                // Never swallow: surface the failed consent save instead of proceeding silently
                consentPersistError = true
            }
        }
    }

    // MARK: - Main Tabs

    /// Native iOS 18 tabs, shown only when startup has reached a usable state.
    private var mainTabs: some View {
        TabView(selection: $viewModel.selectedTab) {
            Tab(value: AppTab.home) {
                NavigationStack {
                    HomeView()
                }
            } label: {
                Label(
                    EchoStrings.tr(AppTab.home.titleKey),
                    systemImage: AppTab.home.systemImage
                )
            }

            Tab(value: AppTab.search) {
                NavigationStack {
                    SearchView()
                }
            } label: {
                Label(
                    EchoStrings.tr(AppTab.search.titleKey),
                    systemImage: AppTab.search.systemImage
                )
            }

            Tab(value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            } label: {
                Label(
                    EchoStrings.tr(AppTab.settings.titleKey),
                    systemImage: AppTab.settings.systemImage
                )
            }
        }
    }

    // MARK: - Launch Argument Fixture Injection

    /// 首次出现时处理启动参数 fixture 注入。
    ///
    /// 支持 `-ui-fixture onboarding-*` 确定性导航到引导流程 (XCUITest / Live Sim Review)。
    /// 生产构建（#if DEBUG 排除）无任何注入逻辑。
    private func handleFirstAppear() {
        guard !hasHandledLaunchArguments else { return }
        hasHandledLaunchArguments = true
        #if DEBUG
        handleLaunchArguments()
        #endif
    }

    #if DEBUG
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-skip-onboarding") {
            return
        }
        guard let idx = args.firstIndex(of: "-ui-fixture"), idx + 1 < args.count else { return }
        let fixtureID = args[idx + 1]

        if fixtureID.hasPrefix("onboarding-") {
            onboardingViewModel.loadFixture(fixtureID)
            isOnboardingPresented = true
        }
    }
    #endif

}

// MARK: - Preview

#Preview {
    AppRootView()
}
