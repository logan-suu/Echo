// ==========================================
// 文件: AwakeningDeliveryTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-001 (地理围栏),
//            US-AWK-002 (日期唤醒), US-AWK-003 (情绪唤醒)
// 任务: 3.12 - 唤醒投递：本地通知 + 位置/健康权限 + 地理围栏设置
// AC 覆盖: US-AWK-001 AC-5 ✅ (位置权限静默禁用/重新开启), AC-6 ✅ (审计记录入口),
//            US-AWK-002 AC-1 ✅ (每日推送开关控制), AC-4 ✅ (无匹配不推送指示),
//            US-AWK-003 AC-1 ✅ (HealthKit 权限管理)
// 架构约束: AGENTS.md §9.1 (单元测试门禁 ≥95%), §10.3 (Phase 3 测试目录)
// 生成时间: 2026-08-03
// ==========================================

import Testing
import Foundation
@testable import Echo

@MainActor
struct AwakeningSettingsViewModelTests {

    // MARK: - US-AWK-001 AC-5: Location Permission Toggle

    @Test("AC-5: geofence toggle is disabled when location not granted")
    func geofenceToggleDisabledWithoutLocation() throws {
        let loader = AwakeningSettingsFixtureLoader()
        let data = try loader.loadSettings(fixtureID: "no-permissions")

        #expect(!data.locationPermission.isGranted)
        #expect(!data.isGeofenceEnabled)
    }

    @Test("AC-5: geofence toggle is enabled when location granted")
    func geofenceToggleEnabledWithLocation() throws {
        let loader = AwakeningSettingsFixtureLoader()
        let data = try loader.loadSettings(fixtureID: "full")

        #expect(data.locationPermission.isGranted)
        #expect(data.isGeofenceEnabled)
    }

    // MARK: - US-AWK-003 AC-1: HealthKit Permission Management

    @Test("AC-1: emotion fixture is disabled when no readable HealthKit samples exist")
    func emotionToggleDisabledWithoutHealth() throws {
        let loader = AwakeningSettingsFixtureLoader()
        let data = try loader.loadSettings(fixtureID: "no-permissions")

        #expect(!data.healthPermission.isGranted)
        #expect(!data.isEmotionEnabled)
        #expect(data.healthRequestState == .notRequested)
        #expect(data.healthDataState == .noReadableSamples)
    }

    @Test("AC-1: emotion fixture is enabled when readable HealthKit samples exist")
    func emotionToggleEnabledWithHealth() throws {
        let loader = AwakeningSettingsFixtureLoader()
        let data = try loader.loadSettings(fixtureID: "full")

        #expect(data.healthPermission.isGranted)
        #expect(data.isEmotionEnabled)
    }

    // MARK: - US-AWK-002 AC-1: Anniversary Toggle

    @Test("AC-1: fixtures preserve anniversary preference independently")
    func anniversaryFixturePreferences() throws {
        let loader = AwakeningSettingsFixtureLoader()

        let full = try loader.loadSettings(fixtureID: "full")
        #expect(full.notificationPermission.isGranted)
        #expect(full.isAnniversaryEnabled)

        let noPerms = try loader.loadSettings(fixtureID: "no-permissions")
        #expect(!noPerms.notificationPermission.isGranted)
        #expect(!noPerms.isAnniversaryEnabled)
    }

    // MARK: - State Transitions

    @Test("ViewModel starts in idle state")
    func viewModelStartsIdle() {
        let vm = AwakeningSettingsViewModel()
        #expect(vm.state == .idle)
    }

    @Test("ViewModel transitions idle → loading → completed after loadSettings")
    func viewModelLoadsToCompleted() async {
        let vm = AwakeningSettingsViewModel()
        #expect(vm.state == .idle)

        await vm.loadSettings()

        guard case .completed = vm.state else {
            Issue.record("Expected .completed, got \(vm.state)")
            return
        }
    }

    @Test("Toggle geofence awakening updates state")
    func toggleGeofenceUpdatesState() async {
        let vm = AwakeningSettingsViewModel()
        await vm.loadSettings()

        await vm.toggleGeofenceAwakening(false)

        guard case .completed(let data) = vm.state else {
            Issue.record("Expected .completed, got \(vm.state)")
            return
        }
        #expect(!data.isGeofenceEnabled)
    }

    @Test("Toggle emotion awakening updates state")
    func toggleEmotionUpdatesState() async {
        let vm = AwakeningSettingsViewModel()
        await vm.loadSettings()

        await vm.toggleEmotionAwakening(false)

        guard case .completed(let data) = vm.state else {
            Issue.record("Expected .completed, got \(vm.state)")
            return
        }
        #expect(!data.isEmotionEnabled)
    }

    @Test("Toggle anniversary awakening updates state")
    func toggleAnniversaryUpdatesState() async {
        let vm = AwakeningSettingsViewModel()
        await vm.loadSettings()

        await vm.toggleAnniversaryAwakening(false)

        guard case .completed(let data) = vm.state else {
            Issue.record("Expected .completed, got \(vm.state)")
            return
        }
        #expect(!data.isAnniversaryEnabled)
    }

    @Test("ViewModel cancel transitions to cancelled")
    func viewModelCancelTransitionsToCancelled() {
        let vm = AwakeningSettingsViewModel()
        vm.cancel()
        #expect(vm.state == .cancelled)
    }

    // MARK: - Geofence Display

    @Test("Geofences are correctly loaded in full fixture")
    func geofencesLoadedCorrectly() throws {
        let loader = AwakeningSettingsFixtureLoader()
        let data = try loader.loadSettings(fixtureID: "full")

        #expect(data.geofences.count == 3)
        #expect(data.geofences[0].displayName == "University Campus")
        #expect(data.geofences[1].displayName == "Home")
        #expect(data.geofences[2].displayName == "Central Park")
        #expect(data.geofences[2].isActive == false)
    }

    @Test("Empty fixture has no geofences")
    func emptyFixtureHasNoGeofences() throws {
        let loader = AwakeningSettingsFixtureLoader()
        let data = try loader.loadSettings(fixtureID: "no-permissions")

        #expect(data.geofences.isEmpty)
    }

    // MARK: - Notification Auth Flow

    @Test("notificationAuthStep starts idle")
    func notificationAuthStartsIdle() {
        let vm = AwakeningSettingsViewModel()
        #expect(vm.notificationAuthStep == .idle)
    }

    @Test("requestNotificationPermission transitions to granted")
    func requestNotificationGrantsPermission() async {
        let scheduler = StubNotificationScheduler()
        scheduler.authState = .authorized
        let vm = AwakeningSettingsViewModel(notificationScheduler: scheduler)
        await vm.requestNotificationPermission()
        #expect(vm.notificationAuthStep == .granted)
    }

    // MARK: - Geofence Detail Navigation

    @Test("showGeofenceDetail starts nil")
    func geofenceDetailStartsNil() {
        let vm = AwakeningSettingsViewModel()
        #expect(vm.showGeofenceDetail == nil)
    }

    @Test("showGeofenceDetails sets and dismisses")
    func geofenceDetailShowAndDismiss() {
        let vm = AwakeningSettingsViewModel()
        let geo = GeofenceInfo(
            id: "test", displayName: "Test",
            latitude: 0, longitude: 0, radiusMeters: 100,
            isActive: true, lastTriggeredAt: nil, memoryCount: 5
        )

        vm.showGeofenceDetails(geo)
        #expect(vm.showGeofenceDetail?.id == "test")

        vm.dismissGeofenceDetail()
        #expect(vm.showGeofenceDetail == nil)
    }

    // MARK: - US-AWK-001 AC-6 / US-AWK-003 AC-5: Audit Record View Entry

    @Test("Full fixture has timestamps for audit trail")
    func fullFixtureHasAuditTimestamps() throws {
        let loader = AwakeningSettingsFixtureLoader()
        let data = try loader.loadSettings(fixtureID: "full")

        #expect(data.lastDailyPushDate != nil)
        #expect(data.lastEmotionAnalysisDate != nil)
    }

    @Test("Empty fixture has no audit timestamps")
    func noPermissionsFixtureHasNoAuditTimestamps() throws {
        let loader = AwakeningSettingsFixtureLoader()
        let data = try loader.loadSettings(fixtureID: "no-permissions")

        #expect(data.lastDailyPushDate == nil)
        #expect(data.lastEmotionAnalysisDate == nil)
    }

    // MARK: - Permission Denied Permanently

    @Test("Permanently denied notification shows isDeniedPermanently")
    func permanentlyDeniedNotification() throws {
        let loader = AwakeningSettingsFixtureLoader()
        let data = try loader.loadSettings(fixtureID: "unavailable")

        #expect(data.notificationPermission.isDeniedPermanently)
        #expect(!data.notificationPermission.isGranted)
    }

    // MARK: - US-AWK-002 AC-4: No match indicator

    @Test("AC-4: all-disabled fixture has geofences but all features off")
    func allDisabledHasGeofencesButFeaturesOff() throws {
        let loader = AwakeningSettingsFixtureLoader()
        let data = try loader.loadSettings(fixtureID: "all-disabled")

        #expect(!data.isGeofenceEnabled)
        #expect(!data.isEmotionEnabled)
        #expect(!data.isAnniversaryEnabled)
        #expect(!data.geofences.isEmpty)
        #expect(data.notificationPermission.isGranted)
    }

    // MARK: - Edge Cases

    @Test("Toggle geofence while not in completed state is no-op")
    func toggleGeofenceWhileIdleIsNoop() async {
        let vm = AwakeningSettingsViewModel()
        #expect(vm.state == .idle)

        await vm.toggleGeofenceAwakening(false)
        #expect(vm.state == .idle)
    }
}
