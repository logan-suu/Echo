// ==========================================
// 文件: DegradationBannerViewModel.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RES-002 (低电量模式降级),
//            US-RES-003 (设备过热降级), US-RES-004 (模型加载失败),
//            docs/ui/echo-memory-canvas-style.md §11.4 (降级横幅), §7.2 (Task surface),
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.6 - 统一错误处理 UI (L1~L4) + 降级横幅 + 冷却期提醒
// AC 覆盖: US-RES-002 AC-2 ✅ (低电量 Banner), AC-4 ✅ (退出低电量自动消失),
//          US-RES-003 AC-2 ✅ (过热 Banner), AC-3 ✅ (热状态恢复自动消失),
//          US-RES-004 AC-7 ✅ (模型降级 Banner + 重试/设置按钮)
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum), §8.2 (idle→loading→completed),
//           docs/ui/architecture.md §6~7 (适配器契约), §2.5 (不保存第二份领域真相)
// 生成时间: 2026-08-02
// ==========================================

import SwiftUI
import Foundation

enum DegradationType: String, Sendable, Equatable, CaseIterable {
    case lowPower
    case thermal
    case modelDegraded
}

struct DegradationState: Sendable, Equatable {
    var type: DegradationType
    var message: String
    var iconName: String
    var tint: Color
    var showToggle: Bool
    var backgroundTasksPaused: Bool
    var showRetry: Bool
    var showSettings: Bool

    static func lowPower(paused: Bool) -> Self {
        Self(
            type: .lowPower,
            message: "Low Power Mode is enabled. Memory search precision may be reduced.",
            iconName: "battery.25",
            tint: .yellow,
            showToggle: true,
            backgroundTasksPaused: paused,
            showRetry: false,
            showSettings: false
        )
    }

    static func thermal() -> Self {
        Self(
            type: .thermal,
            message: "Device temperature is high. Some features have been temporarily simplified.",
            iconName: "thermometer.high",
            tint: .orange,
            showToggle: false,
            backgroundTasksPaused: false,
            showRetry: false,
            showSettings: false
        )
    }

    static func modelDegraded() -> Self {
        Self(
            type: .modelDegraded,
            message: "Functional limitations due to model loading issues.",
            iconName: "exclamationmark.triangle",
            tint: .red,
            showToggle: false,
            backgroundTasksPaused: false,
            showRetry: true,
            showSettings: true
        )
    }
}

@MainActor
@Observable
final class DegradationBannerViewModel {
    enum UIState: Equatable {
        case idle
        case loading
        case active(DegradationState)
        case error(String)
    }

    private(set) var state: UIState = .idle
    private(set) var isBannerVisible: Bool = false
    private(set) var activeDegradation: DegradationState?

    private var dismissTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    func loadFixture(_ fixtureID: String) {
        state = .loading
        let fixture = DegradationFixtureLoader.load(fixtureID)
        if let degradation = fixture.degradation {
            activeDegradation = degradation
            isBannerVisible = true
            state = .active(degradation)
        } else {
            activeDegradation = nil
            isBannerVisible = false
            state = .idle
        }
    }

    func activate(_ degradation: DegradationState) {
        state = .loading
        activeDegradation = degradation
        isBannerVisible = true
        state = .active(degradation)
    }

    func dismissBanner() {
        retryTask?.cancel()
        dismissTask?.cancel()
        isBannerVisible = false
        activeDegradation = nil
        state = .idle
    }

    func toggleBackgroundTasks() {
        guard activeDegradation?.type == .lowPower, var current = activeDegradation else { return }
        current.backgroundTasksPaused.toggle()
        activeDegradation = current
        state = .active(current)
    }

    func retryModelLoad() {
        retryTask?.cancel()
        state = .loading
        retryTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            state = .active(.modelDegraded())
        }
    }

    func deactivate() {
        retryTask?.cancel()
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            isBannerVisible = false
            activeDegradation = nil
            state = .idle
        }
    }

    deinit {
        // dismissTask cleanup deferred — nonisolated deinit cannot access @MainActor state
    }
}
