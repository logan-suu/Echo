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
// Runtime status: system permissions/regions are live. Preference toggles fail visibly until a
// production awakening-preference boundary exists; deterministic mutation is fixture-only.
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum: idle/loading/completed/error/cancelled),
//           §4.2 (仅持有不可变引用), docs/ui/architecture.md §6~7 (适配器契约),
//           §2.5 (Adapter 不保存第二份领域真相), echo-memory-canvas apple-native 基础
// 生成时间: 2026-08-03
// ==========================================

import SwiftUI
import Foundation
import UIKit

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
    private(set) var isFixtureBacked = false

    var showGeofenceDetail: GeofenceInfo?
    private var loadTask: Task<Void, Never>?

    private let fixtureLoader: AwakeningSettingsFixtureLoader

    /// 3F.8: 系统适配器 — 真实权限状态与地理围栏来源（ADR-012 决策-2/3）。
    /// 生产装配注入 live 适配器；fixture 驱动测试保持 nil 走 fixture 路径。
    private let locationProvider: (any LocationProviding)?
    private let healthStore: (any HealthStoreServing)?
    private let notificationScheduler: (any NotificationScheduling)?

    init(
        fixtureLoader: AwakeningSettingsFixtureLoader = .shared,
        locationProvider: (any LocationProviding)? = nil,
        healthStore: (any HealthStoreServing)? = nil,
        notificationScheduler: (any NotificationScheduling)? = nil
    ) {
        self.fixtureLoader = fixtureLoader
        self.locationProvider = locationProvider
        self.healthStore = healthStore
        self.notificationScheduler = notificationScheduler
    }

    deinit {}

    func loadSettings() async {
        state = .loading
        do {
            // 3F.8: 有 live 适配器时读取真实系统状态，否则回退 fixture（Preview/测试）
            if let data = await loadLiveData() {
                isFixtureBacked = false
                state = .completed(data)
                return
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            let data = try fixtureLoader.loadSettings()
            isFixtureBacked = true
            state = .completed(data)
        } catch {
            state = .error(.l2Recoverable(error.localizedDescription))
        }
    }

    /// 从真实系统适配器读取权限与围栏状态（ADR-012 决策-2）。
    private func loadLiveData() async -> AwakeningSettingsData? {
        guard locationProvider != nil || healthStore != nil || notificationScheduler != nil else {
            return nil
        }
        let notification: AwakeningPermissionInfo
        if let notificationScheduler {
            let auth = await notificationScheduler.currentAuthorizationState()
            notification = AwakeningPermissionInfo(
                identifier: "notification",
                displayName: "Notifications",
                systemImage: auth == .authorized ? "bell.badge.fill" : "bell.slash.fill",
                isGranted: auth == .authorized,
                isDeniedPermanently: auth == .denied,
                description: "Echo sends awakening notifications for memories at places, on anniversaries, and when your mood changes."
            )
        } else {
            notification = AwakeningPermissionInfo(
                identifier: "notification",
                displayName: "Notifications",
                systemImage: "bell.fill",
                isGranted: false,
                isDeniedPermanently: false,
                description: "Allow Echo to send you awakening notifications when memories surface."
            )
        }

        let location: AwakeningPermissionInfo
        if let locationProvider {
            let auth = await locationProvider.currentAuthorizationState()
            let granted = auth == .authorizedWhenInUse || auth == .authorizedAlways
            location = AwakeningPermissionInfo(
                identifier: "location",
                displayName: "Location",
                systemImage: granted ? "location.fill" : "location.slash.fill",
                isGranted: granted,
                isDeniedPermanently: auth == .denied || auth == .restricted,
                description: "Used for geofence-based memory awakening when you arrive at meaningful places."
            )
        } else {
            location = AwakeningPermissionInfo(
                identifier: "location",
                displayName: "Location",
                systemImage: "location.fill",
                isGranted: false,
                isDeniedPermanently: false,
                description: "Location access enables geofence-based memory delivery."
            )
        }

        let health: AwakeningPermissionInfo
        if let healthStore {
            let auth = await healthStore.currentAuthorizationState()
            health = AwakeningPermissionInfo(
                identifier: "health",
                displayName: "Health",
                systemImage: auth == .authorized ? "heart.fill" : "heart.slash.fill",
                isGranted: auth == .authorized,
                isDeniedPermanently: auth == .denied,
                description: "Used for emotion-based awakening to surface joyful memories when mood is low."
            )
        } else {
            health = AwakeningPermissionInfo(
                identifier: "health",
                displayName: "Health",
                systemImage: "heart.fill",
                isGranted: false,
                isDeniedPermanently: false,
                description: "Health data access enables mood-based memory delivery."
            )
        }

        let geofences: [GeofenceInfo]
        if let locationProvider {
            geofences = await locationProvider.monitoredRegions().map { region in
                GeofenceInfo(
                    id: region.identifier,
                    displayName: region.identifier,
                    latitude: region.latitude,
                    longitude: region.longitude,
                    radiusMeters: region.radiusMeters,
                    isActive: true,
                    lastTriggeredAt: nil,
                    memoryCount: 0
                )
            }
        } else {
            geofences = []
        }

        return AwakeningSettingsData(
            notificationPermission: notification,
            locationPermission: location,
            healthPermission: health,
            isGeofenceEnabled: geofences.isEmpty ? false : true,
            isEmotionEnabled: health.isGranted,
            isAnniversaryEnabled: notification.isGranted,
            geofences: geofences,
            lastDailyPushDate: nil,
            lastEmotionAnalysisDate: nil
        )
    }

    func toggleGeofenceAwakening(_ enabled: Bool) {
        guard case .completed(var data) = state else { return }
        guard isFixtureBacked else {
            state = .error(.l2Recoverable(
                "Geofence awakening settings are unavailable because no production preference boundary is connected."
            ))
            return
        }
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
        guard isFixtureBacked else {
            state = .error(.l2Recoverable(
                "Emotion awakening settings are unavailable because no production preference boundary is connected."
            ))
            return
        }
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
        guard isFixtureBacked else {
            state = .error(.l2Recoverable(
                "Anniversary awakening settings are unavailable because no production preference boundary is connected."
            ))
            return
        }
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
        if let notificationScheduler {
            // 3F.11 fix: 真实通知授权（ADR-012 决策-2/3）
            let auth = await notificationScheduler.requestAuthorization()
            notificationAuthStep = (auth == .authorized) ? .granted : .denied
        } else {
            // Missing system wiring must not masquerade as granted authorization.
            notificationAuthStep = .denied
        }
        await loadSettings()
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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
