// ==========================================
// 文件: AppViewModel.swift
// 对应规格: AGENTS.md §8.1 (ViewModel 契约), docs/ui/architecture.md §6 (ViewModel 契约),
//            docs/01-spec/用户故事与验收标准规格书.md → US-DIS-001 (统一语言), US-SET-001
// 任务: 3.0 - App Shell: TabView + NavigationStack + DI 注入
//       3F.1 - Production composition (ADR-007 §决策-1/2)
//       3F.10 - LanguageCenter unified app language (US-DIS-001 AC-1~5, AGENTS.md §1.3)
// AC 覆盖: App Shell 依赖注入容器, selectedTab 状态管理, startupState 透传,
//          US-DIS-001 AC-1~5 ✅ (single App Language setting, UI+AI sync, follow-system mapping,
//          immediate effect, .languageUnified audit)
// 架构约束: 遵循 AGENTS.md §8.1 (ViewModel 契约: @MainActor + @Observable + state enum), §10.1 (ViewModels 目录)
// 生成时间: 2026-07-26, 2026-08-04 (Task 3F.1), 2026-08-12 (Task 3F.10 LanguageCenter)
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

    /// 错误等级 — 映射 Core AGENTS.md §4.4 L1~L4 错误分级契约
    ///
    /// | 等级 | 映射 | 系统行为 | 用户感知 |
    /// |------|------|---------|---------|
    /// | l1Transient | L1 瞬态 | 指数退避重试 3 次，失败升级 L2 | 无提示 |
    /// | l2Recoverable | L2 可恢复 | 写入 PendingOperations，仅手动重试 | Toast + 重试按钮 |
    /// | l3Blocking | L3 阻断 | 停止功能，引导跳转系统设置 | 全屏引导页 |
    /// | l4Conflict | L4 数据冲突 | 标记 conflict，手动合并 UI | Banner + 冲突入口 |
    ///
    /// 当前 App Shell 预留；3.11+ 在 Core 接入时由 Adapter do/catch 统一映射。
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

    deinit {}

    // MARK: - Actions

    /// 切换标签页
    func selectTab(_ tab: AppTab) {
        selectedTab = tab
    }
}

// MARK: - Language Center (US-DIS-001 / US-SET-001, AGENTS.md §1.3)

/// Unified app language control: one setting drives both UI strings and AI preferredLanguage.
/// zh-Hans/en-US only; Traditional Chinese and dialects map to zh-Hans with a one-time notice.
@MainActor
@Observable
final class LanguageCenter {
    enum AppLanguageSelection: String, CaseIterable, Sendable {
        case followSystem
        case zhHans
        case enUS
    }

    static let shared = LanguageCenter()

    private static let selectionKey = "echo.language.selection"
    private static let resolvedKey = "echo.language.resolved"
    private static let mappingNoticeKey = "echo.language.mappingNoticePresented"

    private(set) var selection: AppLanguageSelection = .followSystem
    private(set) var resolvedLanguage: String = "zh-Hans"
    private(set) var didPresentMappingNotice: Bool = false

    let requiresRestart: Bool = false

    private let noticeStore: UserDefaults

    init(noticeStore: UserDefaults = .standard) {
        self.noticeStore = noticeStore
        if let raw = noticeStore.string(forKey: Self.selectionKey),
           let stored = AppLanguageSelection(rawValue: raw) {
            selection = stored
        }
        if let resolved = noticeStore.string(forKey: Self.resolvedKey),
           resolved == "zh-Hans" || resolved == "en-US" {
            resolvedLanguage = resolved
        } else {
            // US-DIS-001 AC-3: default follows the system language (non-zh/en systems → zh-Hans)
            resolvedLanguage = Self.resolve(.followSystem, systemLanguage: Self.systemLanguageIdentifier())
        }
        #if DEBUG
        // Test-only hook for deterministic UI runs. It is not compiled into Release.
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-ui-language"), idx + 1 < args.count,
           args[idx + 1] == "zh-Hans" || args[idx + 1] == "en-US" {
            resolvedLanguage = args[idx + 1]
        }
        #endif
    }

    deinit {}

    nonisolated static func systemLanguageIdentifier() -> String {
        Locale.current.identifier
    }

    var locale: Locale {
        Locale(identifier: resolvedLanguage)
    }

    func apply(
        _ newSelection: AppLanguageSelection,
        systemLanguage: String,
        privacyActor: PrivacyActor
    ) async throws {
        let resolved = Self.resolve(newSelection, systemLanguage: systemLanguage)
        selection = newSelection
        resolvedLanguage = resolved
        noticeStore.set(newSelection.rawValue, forKey: Self.selectionKey)
        noticeStore.set(resolved, forKey: Self.resolvedKey)

        if newSelection == .followSystem,
           Self.requiresMappingNotice(systemLanguage: systemLanguage),
           !noticeStore.bool(forKey: Self.mappingNoticeKey) {
            didPresentMappingNotice = true
            noticeStore.set(true, forKey: Self.mappingNoticeKey)
        } else {
            didPresentMappingNotice = false
        }

        let policy = await privacyActor.getPolicy()
        let updated = UserPolicy(
            preferredLanguage: resolved,
            authorizedSourceTypes: policy.authorizedSourceTypes,
            policyVersion: policy.policyVersion
        )
        try await privacyActor.updatePolicy(updated)

        try await privacyActor.writeAuditLog(
            eventType: .languageUnified,
            traceID: UUID().uuidString,
            policyVersion: policy.policyVersion,
            success: true,
            sourceLanguage: resolved
        )
    }

    nonisolated static func resolve(_ selection: AppLanguageSelection, systemLanguage: String) -> String {
        switch selection {
        case .zhHans:
            return "zh-Hans"

        case .enUS:
            return "en-US"

        case .followSystem:
            return systemLanguage.lowercased().hasPrefix("en") ? "en-US" : "zh-Hans"
        }
    }

    nonisolated static func requiresMappingNotice(systemLanguage: String) -> Bool {
        let lower = systemLanguage.lowercased()
        if lower.hasPrefix("en") || lower.hasPrefix("zh-hans") { return false }
        return true
    }

    func resetOneTimeNoticeForTesting() {
        noticeStore.removeObject(forKey: Self.mappingNoticeKey)
        didPresentMappingNotice = false
    }

    func resetResolvedForTesting() {
        didPresentMappingNotice = false
    }
}

// MARK: - Localized String Resolution

/// Resolves catalog keys against the active app language (US-DIS-001 AC-4 immediate effect).
/// Uses explicit .lproj bundle lookup: String(localized:locale:) only affects formatting,
/// not localization choice, so the locale-specific sub-bundle is loaded directly.
enum EchoStrings {
    nonisolated static func tr(_ key: String, locale: Locale) -> String {
        EchoLocalization.localized(key, locale: locale)
    }

    @MainActor
    static func tr(_ key: String) -> String {
        tr(key, locale: LanguageCenter.shared.locale)
    }
}
