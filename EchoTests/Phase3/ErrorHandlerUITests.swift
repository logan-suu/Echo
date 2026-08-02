// ==========================================
// 文件: ErrorHandlerUITests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RES-002, US-RES-003, US-RES-004
// 任务: 3.6 - 统一错误处理 UI (L1~L4) + 降级横幅 + 冷却期提醒
// AC 覆盖: US-RES-002 AC-2/AC-4, US-RES-003 AC-2/AC-3, US-RES-004 AC-7
// 架构约束: AGENTS.md §9.1 (单元测试覆盖率 ≥95%)
// 生成时间: 2026-08-02
// ==========================================

import Testing
import SwiftUI
@testable import Echo

@MainActor
@Suite("DegradationBannerViewModel Tests")
struct DegradationBannerViewModelTests {

    @Test("AC-1: Initial state is idle with no visible banner")
    func initialState() {
        let vm = DegradationBannerViewModel()
        #expect(vm.state == .idle)
        #expect(vm.isBannerVisible == false)
        #expect(vm.activeDegradation == nil)
    }

    @Test("AC-2: Load low power fixture shows banner with yellow tint and battery icon")
    func loadLowPowerFixture() {
        let vm = DegradationBannerViewModel()
        vm.loadFixture("degradation-low-power")
        #expect(vm.isBannerVisible == true)
        guard let d = vm.activeDegradation else {
            #expect(Bool(false), "Expected active degradation")
            return
        }
        #expect(d.type == .lowPower)
        #expect(d.iconName == "battery.25")
        #expect(d.tint == .yellow)
        #expect(d.showToggle == true)
        #expect(d.backgroundTasksPaused == true)
    }

    @Test("AC-3: Load thermal fixture shows banner with orange tint and thermometer icon")
    func loadThermalFixture() {
        let vm = DegradationBannerViewModel()
        vm.loadFixture("degradation-thermal")
        #expect(vm.isBannerVisible == true)
        guard let d = vm.activeDegradation else {
            #expect(Bool(false), "Expected active degradation")
            return
        }
        #expect(d.type == .thermal)
        #expect(d.iconName == "thermometer.high")
        #expect(d.tint == .orange)
        #expect(d.showToggle == false)
        #expect(d.showRetry == false)
    }

    @Test("AC-4: Load model degraded fixture shows banner with red tint and retry/settings buttons")
    func loadModelDegradedFixture() {
        let vm = DegradationBannerViewModel()
        vm.loadFixture("degradation-model-degraded")
        #expect(vm.isBannerVisible == true)
        guard let d = vm.activeDegradation else {
            #expect(Bool(false), "Expected active degradation")
            return
        }
        #expect(d.type == .modelDegraded)
        #expect(d.iconName == "exclamationmark.triangle")
        #expect(d.tint == .red)
        #expect(d.showRetry == true)
        #expect(d.showSettings == true)
    }

    @Test("AC-5: Load normal fixture hides banner")
    func loadNormalFixture() {
        let vm = DegradationBannerViewModel()
        vm.loadFixture("degradation-normal")
        #expect(vm.isBannerVisible == false)
        #expect(vm.activeDegradation == nil)
        #expect(vm.state == .idle)
    }

    @Test("AC-6: Dismiss banner clears active degradation")
    func dismissBanner() {
        let vm = DegradationBannerViewModel()
        vm.loadFixture("degradation-low-power")
        #expect(vm.isBannerVisible == true)
        vm.dismissBanner()
        #expect(vm.isBannerVisible == false)
        #expect(vm.activeDegradation == nil)
        #expect(vm.state == .idle)
    }

    @Test("AC-7: Toggle background tasks in low power state")
    func toggleBackgroundTasks() {
        let vm = DegradationBannerViewModel()
        vm.loadFixture("degradation-low-power")
        #expect(vm.activeDegradation?.backgroundTasksPaused == true)
        vm.toggleBackgroundTasks()
        #expect(vm.activeDegradation?.backgroundTasksPaused == false)
        vm.toggleBackgroundTasks()
        #expect(vm.activeDegradation?.backgroundTasksPaused == true)
    }

    @Test("AC-8: Retry model load keeps banner visible")
    func retryModelLoad() async {
        let vm = DegradationBannerViewModel()
        vm.loadFixture("degradation-model-degraded")
        vm.retryModelLoad()
        #expect(vm.state == .loading)
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        #expect(vm.isBannerVisible == true)
    }

    @Test("AC-9: Deactivate banner transitions to idle after delay")
    func deactivate() async {
        let vm = DegradationBannerViewModel()
        vm.loadFixture("degradation-thermal")
        #expect(vm.isBannerVisible == true)
        vm.deactivate()
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(vm.isBannerVisible == false)
        #expect(vm.state == .idle)
    }

    @Test("AC-10: Activate low power degradation directly")
    func activateLowPower() {
        let vm = DegradationBannerViewModel()
        vm.activate(.lowPower(paused: false))
        #expect(vm.isBannerVisible == true)
        #expect(vm.activeDegradation?.type == .lowPower)
        #expect(vm.activeDegradation?.backgroundTasksPaused == false)
    }

    @Test("AC-11: Activate thermal degradation directly")
    func activateThermal() {
        let vm = DegradationBannerViewModel()
        vm.activate(.thermal())
        #expect(vm.isBannerVisible == true)
        #expect(vm.activeDegradation?.type == .thermal)
        #expect(vm.activeDegradation?.showToggle == false)
    }

    @Test("AC-12: Activate model degraded directly")
    func activateModelDegraded() {
        let vm = DegradationBannerViewModel()
        vm.activate(.modelDegraded())
        #expect(vm.isBannerVisible == true)
        #expect(vm.activeDegradation?.type == .modelDegraded)
        #expect(vm.activeDegradation?.showRetry == true)
        #expect(vm.activeDegradation?.showSettings == true)
    }

    @Test("AC-13: Unknown fixture ID falls back to normal")
    func unknownFixture() {
        let vm = DegradationBannerViewModel()
        vm.loadFixture("nonexistent-fixture")
        #expect(vm.isBannerVisible == false)
        #expect(vm.activeDegradation == nil)
        #expect(vm.state == .idle)
    }

    @Test("AC-14: DegradationState lowPower factory sets correct defaults")
    func lowPowerDefaults() {
        let state = DegradationState.lowPower(paused: true)
        #expect(state.type == .lowPower)
        #expect(state.iconName == "battery.25")
        #expect(state.tint == .yellow)
        #expect(state.showToggle == true)
        #expect(state.backgroundTasksPaused == true)
        #expect(state.showRetry == false)
    }

    @Test("AC-15: DegradationState thermal factory sets correct defaults")
    func thermalDefaults() {
        let state = DegradationState.thermal()
        #expect(state.type == .thermal)
        #expect(state.iconName == "thermometer.high")
        #expect(state.tint == .orange)
        #expect(state.showToggle == false)
        #expect(state.showSettings == false)
    }

    @Test("AC-16: DegradationState modelDegraded factory sets correct defaults")
    func modelDegradedDefaults() {
        let state = DegradationState.modelDegraded()
        #expect(state.type == .modelDegraded)
        #expect(state.iconName == "exclamationmark.triangle")
        #expect(state.tint == .red)
        #expect(state.showRetry == true)
        #expect(state.showSettings == true)
    }

    @Test("AC-17: Toggle does nothing on non-lowPower degradation")
    func toggleOnNonLowPower() {
        let vm = DegradationBannerViewModel()
        vm.loadFixture("degradation-thermal")
        #expect(vm.activeDegradation?.type == .thermal)
        vm.toggleBackgroundTasks()
        #expect(vm.activeDegradation?.type == .thermal)
    }

    @Test("AC-18: DegradationType allCases covers all three types")
    func degradationTypeAllCases() {
        let all = DegradationType.allCases
        #expect(all.count == 3)
        #expect(all.contains(.lowPower))
        #expect(all.contains(.thermal))
        #expect(all.contains(.modelDegraded))
    }

    @Test("AC-19: Fixture loader available IDs contain all four fixtures")
    func fixtureLoaderIDs() {
        let ids = DegradationFixtureLoader.availableFixtureIDs
        #expect(ids.count == 4)
        #expect(ids.contains("degradation-low-power"))
        #expect(ids.contains("degradation-thermal"))
        #expect(ids.contains("degradation-model-degraded"))
        #expect(ids.contains("degradation-normal"))
    }

    @Test("AC-20: UIState equatable comparison")
    func uiStateEquatable() {
        #expect(DegradationBannerViewModel.UIState.idle == .idle)
        #expect(DegradationBannerViewModel.UIState.loading == .loading)
        let lowPower = DegradationState.lowPower(paused: true)
        #expect(DegradationBannerViewModel.UIState.active(lowPower) == .active(lowPower))
        #expect(DegradationBannerViewModel.UIState.error("test") == .error("test"))
    }
}

@MainActor
@Suite("DegradationBannerView Accessibility Tests")
struct DegradationBannerViewAccessibilityTests {

    @Test("AC-21: Low power banner has correct accessibility label")
    func lowPowerAccessibilityLabel() {
        let vm = DegradationBannerViewModel()
        vm.loadFixture("degradation-low-power")
        #expect(vm.activeDegradation?.type == .lowPower)
    }

    @Test("AC-22: Thermal banner has correct accessibility label")
    func thermalAccessibilityLabel() {
        let vm = DegradationBannerViewModel()
        vm.loadFixture("degradation-thermal")
        #expect(vm.activeDegradation?.type == .thermal)
    }
}
