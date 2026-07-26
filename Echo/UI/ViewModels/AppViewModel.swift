// ==========================================
// 文件: AppViewModel.swift
// 对应规格: AGENTS.md §8.1 (ViewModel 契约), docs/ui/architecture.md §6 (ViewModel 契约)
// 任务: 3.0 - App Shell: TabView + NavigationStack + DI 注入
// AC 覆盖: App Shell 依赖注入容器，selectedTab 状态管理
// 架构约束: 遵循 AGENTS.md §8.1 (ViewModel 契约: @MainActor + @Observable + state enum), §10.1 (ViewModels 目录)
// 生成时间: 2026-07-26
// ==========================================

import SwiftUI

// MARK: - Tab Enum

/// App Shell 标签页标识
enum AppTab: String, CaseIterable, Sendable {
    case home
    case search
    case settings

    var titleKey: String {
        switch self {
        case .home:     return "Home"
        case .search:   return "Search"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home:     return "house.fill"
        case .search:   return "magnifyingglass"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - AppViewModel

/// App 级 ViewModel — 管理根导航状态与依赖注入
///
/// ## Surface Family: Task
/// - 布局: 使用系统 TabView + NavigationStack
/// - Masonry: 禁止
/// - 样式: 遵循 echo-memory-canvas（apple-native 基础）
///
/// ## 职责
/// - selectedTab: 根标签页切换状态
/// - 不保存第二份领域真相
/// - 不直接访问 Core Actor
@MainActor
@Observable
final class AppViewModel {

    // MARK: - Tab State

    /// 当前选中的标签页
    var selectedTab: AppTab = .home

    // MARK: - UI State

    /// App 级状态（遵循 AGENTS.md §8.1 state enum 模式）
    enum AppState: Equatable, Sendable {
        case idle
        case loading
        case ready
        case error(ErrorLevel)
    }

    /// 错误等级（映射 Core L1~L4）
    enum ErrorLevel: Equatable, Sendable {
        case l1Transient
        case l2Recoverable
        case l3Blocking
        case l4Conflict
    }

    var appState: AppState = .idle

    // MARK: - Initialization

    init() {
        // App Shell 初始化时不执行任何 Core 操作
        // 后续任务 (3.11 引导流程) 将通过 action 方法触发首次设置
    }

    // MARK: - Actions

    /// 切换标签页
    func selectTab(_ tab: AppTab) {
        selectedTab = tab
    }
}
