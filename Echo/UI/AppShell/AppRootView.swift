// ==========================================
// 文件: AppRootView.swift
// 对应规格: docs/ui/echo-memory-canvas-style.md §3.3 (Task surfaces), docs/ui/architecture.md §3 (App Shell)
// 任务: 3.0 - App Shell: TabView + NavigationStack + DI 注入
//       3F.1 - Production composition (ADR-007 §决策-1/2/5)
// AC 覆盖: TabView 三大标签页 (Home/Search/Settings)，各含独立 NavigationStack; 启动状态门控
// 架构约束: 遵循 AGENTS.md §8.1, §10.1; echo-memory-canvas apple-native 基础; Task surface family (禁止 masonry)
// 生成时间: 2026-07-26, 2026-08-04 (Task 3F.1)
// ==========================================

import SwiftUI

// MARK: - AppRootView

/// Echo App 根视图 — TabView 容器 + 启动状态门控 (3F.1)
///
/// ## Surface Family: Task
/// - 使用系统 TabView + NavigationStack
/// - 绝对禁止 masonry 布局
/// - 遵循 echo-memory-canvas style tokens (semantic colors, SF Symbols, Dynamic Type)
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

    /// 应用自有 composition root (3F.1)
    @State private var composition = AppComposition.shared

    /// 引导流程 ViewModel — 首次启动五步引导 (Task 3.11)
    /// 3F.1 修复: 注入 composition.consentStore，同意即时持久化 (US-PRV-008 AC-4)
    @State private var onboardingViewModel = OnboardingViewModel(consentStore: AppComposition.shared.consentStore)

    /// 引导流程是否展示 (fullScreenCover, echo-memory-canvas §15.1)
    @State private var isOnboardingPresented = false

    /// 首次出现标记 — 控制 fixture 注入仅执行一次
    @State private var hasHandledLaunchArguments = false

    // MARK: - Body

    var body: some View {
        Group {
            switch composition.startupState {
            case .requiresConsent, .consentDeclined:
                onboardingGate

            case .modelUnavailable:
                unavailableGate(title: "Models Unavailable",
                                message: "Required models could not be loaded. Reinstall Echo to restore them.")

            case .routeUnavailable:
                unavailableGate(title: "Search Unavailable",
                                message: "The active index route is unavailable.")

            case .indexUnavailable:
                unavailableGate(title: "Index Unavailable",
                                message: "Memory index is not ready yet.")

            case .purgeBlocked:
                unavailableGate(title: "Action Blocked",
                                message: "The previous cleanup did not complete. Try again.")

            default:
                mainTabs
            }
        }
        .tint(Color.accentColor)
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
            viewModel.updateStartupState(composition.startupState)
        }
        .onChange(of: composition.startupState) { _, newState in
            viewModel.updateStartupState(newState)
        }
    }

    // MARK: - Onboarding Gate

    /// deny-by-default：未同意时展示引导 (US-PRV-008)。
    /// 生产路径经 EchoApp.task bootstrap 后进入此分支；测试用 `-ui-fixture onboarding-*` 直达。
    @ViewBuilder
    private var onboardingGate: some View {
        Color.clear
            .onAppear { isOnboardingPresented = true }
    }

    /// 不可用启动态占位（ADR-007 §决策-5）
    @ViewBuilder
    private func unavailableGate(title: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(Color.yellow)
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            Text(message)
                .font(.body)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    /// 引导完成后同步同意状态到 composition (US-PRV-008 AC-4)
    private func handleOnboardingCompleted() {
        Task {
            try? await composition.acceptConsent(consentVersion: 1, policyVersion: 1)
        }
    }

    // MARK: - Main Tabs

    /// 主 TabView — 仅 startupState == .ready 时展示
    private var mainTabs: some View {
        TabView(selection: $viewModel.selectedTab) {
            homeTab
                .tag(AppTab.home)

            searchTab
                .tag(AppTab.search)

            settingsTab
                .tag(AppTab.settings)
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

    // MARK: - Tab Definitions

    /// Home 标签页 — Discovery surface（后续 3.1 实现为内容卡片列表）
    @ViewBuilder
    private var homeTab: some View {
        NavigationStack {
            HomeView()
        }
        .tabItem {
            Label(AppTab.home.titleKey, systemImage: AppTab.home.systemImage)
        }
    }

    /// Search 标签页 — Discovery surface（后续 3.2 实现为搜索视图）
    @ViewBuilder
    private var searchTab: some View {
        NavigationStack {
            SearchView()
        }
        .tabItem {
            Label(AppTab.search.titleKey, systemImage: AppTab.search.systemImage)
        }
    }

    /// Settings 标签页 — Task surface（后续 3.4 实现为设置页面）
    @ViewBuilder
    private var settingsTab: some View {
        NavigationStack {
            SettingsView()
        }
        .tabItem {
            Label(AppTab.settings.titleKey, systemImage: AppTab.settings.systemImage)
        }
    }
}

// MARK: - Preview

#Preview {
    AppRootView()
}
