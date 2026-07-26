// ==========================================
// 文件: AppRootView.swift
// 对应规格: docs/ui/echo-memory-canvas-style.md §3.3 (Task surfaces), docs/ui/architecture.md §3 (App Shell)
// 任务: 3.0 - App Shell: TabView + NavigationStack + DI 注入
// AC 覆盖: TabView 三大标签页 (Home/Search/Settings)，各含独立 NavigationStack
// 架构约束: 遵循 AGENTS.md §8.1, §10.1; echo-memory-canvas apple-native 基础; Task surface family (禁止 masonry)
// 生成时间: 2026-07-26
// ==========================================

import SwiftUI

// MARK: - AppRootView

/// Echo App 根视图 — TabView 容器
///
/// ## Surface Family: Task
/// - 使用系统 TabView + NavigationStack
/// - 绝对禁止 masonry 布局
/// - 遵循 echo-memory-canvas style tokens (semantic colors, SF Symbols, Dynamic Type)
///
/// ## 架构映射
/// - App Shell: 根导航 + 依赖装配
/// - ViewModel: AppViewModel (DI 容器)
/// - 数据流: User Action → ViewModel.selectTab() → TabView 切换
struct AppRootView: View {

    // MARK: - State

    /// App 级 ViewModel（DI 容器），由 EchoApp 注入
    @State private var viewModel = AppViewModel()

    // MARK: - Body

    var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            homeTab
                .tag(AppTab.home)

            searchTab
                .tag(AppTab.search)

            settingsTab
                .tag(AppTab.settings)
        }
        .tint(Color.accentColor)
    }

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
