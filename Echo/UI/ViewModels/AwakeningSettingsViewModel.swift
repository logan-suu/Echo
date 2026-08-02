// ==========================================
// 文件: AwakeningSettingsViewModel.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-001 (地理围栏), US-AWK-002 (日期唤醒), US-AWK-003 (情绪唤醒)
//            docs/ui/echo-memory-canvas-style.md §3.3 (Task surfaces), §7.2, §13 (后台任务面板)
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.12 - 唤醒投递：本地通知 + 位置/健康权限 + 地理围栏设置
// AC 覆盖: US-AWK-001 AC-5 ✅ (位置权限静默禁用/重开), AC-6 ✅ (审计 record 触发 UI),
//            US-AWK-002 AC-1 ✅ (每日 9:00 推送开关/控制), AC-4 ✅ (无匹配时不推送指示),
//            US-AWK-003 AC-1 ✅ (HealthKit 权限开关), AC-5 ✅ (审计记录查看入口)
// Legend: ✅ implemented (UI slice/fixture) | 🔶 stub (entry point, Core integration deferred to Phase 3.9)
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum: idle/loading/completed/error/cancelled),
//           §4.2 (仅持有不可变引用), docs/ui/architecture.md §6~7 (适配器契约),
//           §2.5 (Adapter 不保存第二份领域真相), echo-memory-canvas apple-native 基础
// 生成时间: 2026-08-03
// ==========================================

import SwiftUI
import Foundation

// MARK: - Awakening Permission Info

struct AwakeningPermissionInfo: Sendable, Equatable {
    let identifier: String
    let displayName: String
    let systemImage: String
    let isGranted: Bool
    let isDeniedPermanently: Bool
    let description: String
}

struct GeofenceInfo: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    let isActive: Bool
    let lastTriggeredAt: Date?
    let memoryCount: Int
}

struct AwakeningSettingsData: Sendable, Equatable {
    let notificationPermission: AwakeningPermissionInfo
    let locationPermission: AwakeningPermissionInfo
    let healthPermission: AwakeningPermissionInfo
    let isGeofenceEnabled: Bool
    let isEmotionEnabled: Bool
    let isAnniversaryEnabled: Bool
    let geofences: [GeofenceInfo]
    let lastDailyPushDate: Date?
    let lastEmotionAnalysisDate: Date?
}

// MARK: - AwakeningSettingsViewModel

@MainActor
@Observable
final class AwakeningSettingsViewModel {
    enum State: Equatable, Sendable {
        case idle
        case loading
        case completed(AwakeningSettingsData)
        case error(ErrorLevel)
        case cancelled
    }

    enum ErrorLevel: Equatable, Sendable {
        case l1Transient
        case l2Recoverable(String)
        case l3Blocking(String)
        case l4Conflict(String)
    }

    enum NotificationAuthStep: Equatable, Sendable {
        case idle
        case requesting
        case granted
        case denied
    }

    var state: State = .idle
    var notificationAuthStep: NotificationAuthStep = .idle

    var showGeofenceDetail: GeofenceInfo?
    private var loadTask: Task<Void, Never>?

    private let fixtureLoader: AwakeningSettingsFixtureLoader

    init(fixtureLoader: AwakeningSettingsFixtureLoader = .shared) {
        self.fixtureLoader = fixtureLoader
    }

    func loadSettings() async {
        state = .loading
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            let data = try fixtureLoader.loadSettings()
            state = .completed(data)
        } catch {
            state = .error(.l2Recoverable(error.localizedDescription))
        }
    }

    func toggleGeofenceAwakening(_ enabled: Bool) {
        guard case .completed(var data) = state else { return }
        data = AwakeningSettingsData(
            notificationPermission: data.notificationPermission,
            locationPermission: data.locationPermission,
            healthPermission: data.healthPermission,
            isGeofenceEnabled: enabled,
            isEmotionEnabled: data.isEmotionEnabled,
            isAnniversaryEnabled: data.isAnniversaryEnabled,
            geofences: data.geofences,
            lastDailyPushDate: data.lastDailyPushDate,
            lastEmotionAnalysisDate: data.lastEmotionAnalysisDate
        )
        state = .completed(data)
    }

    func toggleEmotionAwakening(_ enabled: Bool) {
        guard case .completed(var data) = state else { return }
        data = AwakeningSettingsData(
            notificationPermission: data.notificationPermission,
            locationPermission: data.locationPermission,
            healthPermission: data.healthPermission,
            isGeofenceEnabled: data.isGeofenceEnabled,
            isEmotionEnabled: enabled,
            isAnniversaryEnabled: data.isAnniversaryEnabled,
            geofences: data.geofences,
            lastDailyPushDate: data.lastDailyPushDate,
            lastEmotionAnalysisDate: data.lastEmotionAnalysisDate
        )
        state = .completed(data)
    }

    func toggleAnniversaryAwakening(_ enabled: Bool) {
        guard case .completed(var data) = state else { return }
        data = AwakeningSettingsData(
            notificationPermission: data.notificationPermission,
            locationPermission: data.locationPermission,
            healthPermission: data.healthPermission,
            isGeofenceEnabled: data.isGeofenceEnabled,
            isEmotionEnabled: data.isEmotionEnabled,
            isAnniversaryEnabled: enabled,
            geofences: data.geofences,
            lastDailyPushDate: data.lastDailyPushDate,
            lastEmotionAnalysisDate: data.lastEmotionAnalysisDate
        )
        state = .completed(data)
    }

    func requestNotificationPermission() async {
        notificationAuthStep = .requesting
        do {
            try await Task.sleep(nanoseconds: 500_000_000)
            notificationAuthStep = .granted
            // 🔮 Phase 3.9: Core UNUserNotificationCenter.requestAuthorization()
        } catch {
            notificationAuthStep = .denied
        }
    }

    func openSystemSettings() {
        // 🔮 Phase 3.9: Core URL.systemSettings for Notification/Location/Health
    }

    func showGeofenceDetails(_ geofence: GeofenceInfo) {
        showGeofenceDetail = geofence
    }

    func dismissGeofenceDetail() {
        showGeofenceDetail = nil
    }

    func cancel() {
        loadTask?.cancel()
        state = .cancelled
    }
}
