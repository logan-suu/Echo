// ==========================================
// 文件: AppShellTests.swift
// 对应规格: AGENTS.md §8.1 (ViewModel 契约), docs/ui/architecture.md §6 (ViewModel 契约), docs/ui/echo-memory-canvas-style.md §3.3
// 任务: 3.0 - App Shell: TabView + NavigationStack + DI 注入
// AC 覆盖: AppViewModel selectedTab 状态管理, AppTab 枚举匹配 SF Symbols
// 测试目标: AppViewModel + AppTab 单元测试
// 生成时间: 2026-07-26
// ==========================================

import Testing
@testable import Echo

// MARK: - AppTab Tests

@MainActor
struct AppTabTests {

    @Test("AppTab allCases should contain exactly home, search, settings")
    func testAppTab_allCases() async throws {
        let cases = AppTab.allCases
        #expect(cases.count == 3)
        #expect(cases.contains(.home))
        #expect(cases.contains(.search))
        #expect(cases.contains(.settings))
    }

    @Test("AppTab home should have correct SF Symbol and title")
    func testAppTab_home_properties() async throws {
        #expect(AppTab.home.systemImage == "house.fill")
        #expect(AppTab.home.titleKey == "Home")
    }

    @Test("AppTab search should have correct SF Symbol and title")
    func testAppTab_search_properties() async throws {
        #expect(AppTab.search.systemImage == "magnifyingglass")
        #expect(AppTab.search.titleKey == "Search")
    }

    @Test("AppTab settings should have correct SF Symbol and title")
    func testAppTab_settings_properties() async throws {
        #expect(AppTab.settings.systemImage == "gearshape.fill")
        #expect(AppTab.settings.titleKey == "Settings")
    }

    @Test("AppTab Sendable conformance")
    func testAppTab_sendable() async throws {
        let tab = AppTab.home
        let task = Task { @Sendable in
            return tab
        }
        let result = await task.value
        #expect(result == .home)
    }
}

// MARK: - AppViewModel Tests

@MainActor
struct AppViewModelTests {

    @Test("AppViewModel should initialize with home tab selected and idle state")
    func testAppViewModel_defaultState() async throws {
        let viewModel = AppViewModel()
        #expect(viewModel.selectedTab == .home)
        #expect(viewModel.appState == .idle)
    }

    @Test("AppViewModel should update selectedTab when selectTab is called")
    func testAppViewModel_selectTab() async throws {
        let viewModel = AppViewModel()

        viewModel.selectTab(.search)
        #expect(viewModel.selectedTab == .search)

        viewModel.selectTab(.settings)
        #expect(viewModel.selectedTab == .settings)

        viewModel.selectTab(.home)
        #expect(viewModel.selectedTab == .home)
    }

    @Test("AppViewModel AppState enum should have correct cases")
    func testAppViewModel_appState_cases() async throws {
        // Verify all expected states exist
        let idleState: AppViewModel.AppState = .idle
        let loadingState: AppViewModel.AppState = .loading
        let readyState: AppViewModel.AppState = .ready
        let errorState: AppViewModel.AppState = .error(.l1Transient)

        #expect(idleState == .idle)
        #expect(loadingState == .loading)
        #expect(readyState == .ready)
        #expect(errorState != .ready)
    }

    @Test("AppViewModel ErrorLevel should have all four levels")
    func testAppViewModel_errorLevel_cases() async throws {
        let l1 = AppViewModel.ErrorLevel.l1Transient
        let l2 = AppViewModel.ErrorLevel.l2Recoverable
        let l3 = AppViewModel.ErrorLevel.l3Blocking
        let l4 = AppViewModel.ErrorLevel.l4Conflict

        #expect(l1 != l2)
        #expect(l2 != l3)
        #expect(l3 != l4)
    }

    @Test("AppViewModel should be @Observable (check property change behavior)")
    func testAppViewModel_observable() async throws {
        let viewModel = AppViewModel()
        let initialTab = viewModel.selectedTab

        viewModel.selectTab(.settings)
        #expect(viewModel.selectedTab != initialTab)
        #expect(viewModel.selectedTab == .settings)
    }
}
