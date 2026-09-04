// ==========================================
// 文件: AwakeningSettingsFixtureLoader.swift
// i18n: Awakening permission/location/permission display strings are hardcoded English. String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-001, US-AWK-002, US-AWK-003
//            docs/ui/architecture.md §3 (组件边界 — Fixture Loader: Preview/测试环境加载确定性数据)
// 任务: 3.12 - 唤醒投递：本地通知 + 位置/健康权限 + 地理围栏设置
// 架构约束: AGENTS.md §10.1, echo-memory-canvas apple-native 基础,
//            Fixture Loader 禁止访问网络/生产数据库 (docs/ui/architecture.md §3)
// 生成时间: 2026-08-03
// ==========================================

import Foundation

final class AwakeningSettingsFixtureLoader: Sendable {
    static let shared = AwakeningSettingsFixtureLoader()

    enum FixtureError: Error {
        case fixtureNotFound
        case invalidData
    }

    func loadSettings(fixtureID: String? = nil) throws -> AwakeningSettingsData {
        let id = fixtureID ?? "default"

        switch id {
        case "default", "full":
            return try loadFullFixture()
        case "unavailable":
            return try loadUnavailableFixture()
        case "no-permissions":
            return try loadNoPermissionsFixture()
        case "all-disabled":
            return try loadAllDisabledFixture()
        default:
            throw FixtureError.fixtureNotFound
        }
    }

    private func loadFullFixture() throws -> AwakeningSettingsData {
        AwakeningSettingsData(
            notificationPermission: AwakeningPermissionInfo(
                identifier: "notification",
                displayName: "Notifications",
                systemImage: "bell.badge.fill",
                isGranted: true,
                isDeniedPermanently: false,
                description: "Echo sends awakening notifications for memories at places, on anniversaries, and when your mood changes."
            ),
            locationPermission: AwakeningPermissionInfo(
                identifier: "location",
                displayName: "Location",
                systemImage: "location.fill",
                isGranted: true,
                isDeniedPermanently: false,
                description: "Used for geofence-based memory awakening when you arrive at meaningful places."
            ),
            healthPermission: AwakeningPermissionInfo(
                identifier: "health",
                displayName: "Health",
                systemImage: "heart.fill",
                isGranted: true,
                isDeniedPermanently: false,
                description: "Used for emotion-based awakening to surface joyful memories when mood is low."
            ),
            isGeofenceEnabled: true,
            isEmotionEnabled: true,
            isAnniversaryEnabled: true,
            geofences: [
                GeofenceInfo(
                    id: "geo-campus",
                    displayName: "University Campus",
                    latitude: 37.7749,
                    longitude: -122.4194,
                    radiusMeters: 500,
                    isActive: true,
                    lastTriggeredAt: Date().addingTimeInterval(-86400 * 3),
                    memoryCount: 47
                ),
                GeofenceInfo(
                    id: "geo-home",
                    displayName: "Home",
                    latitude: 37.7849,
                    longitude: -122.4094,
                    radiusMeters: 200,
                    isActive: true,
                    lastTriggeredAt: Date().addingTimeInterval(-86400 * 7),
                    memoryCount: 156
                ),
                GeofenceInfo(
                    id: "geo-park",
                    displayName: "Central Park",
                    latitude: 37.7600,
                    longitude: -122.4300,
                    radiusMeters: 800,
                    isActive: false,
                    lastTriggeredAt: Date().addingTimeInterval(-86400 * 14),
                    memoryCount: 23
                )
            ],
            lastDailyPushDate: Date().addingTimeInterval(-86400),
            lastEmotionAnalysisDate: Date().addingTimeInterval(-3600 * 6),
            healthRequestState: .requestCompleted,
            healthDataState: .samplesAvailable
        )
    }

    private func loadUnavailableFixture() throws -> AwakeningSettingsData {
        AwakeningSettingsData(
            notificationPermission: AwakeningPermissionInfo(
                identifier: "notification",
                displayName: "Notifications",
                systemImage: "bell.slash.fill",
                isGranted: false,
                isDeniedPermanently: true,
                description: "Notifications are disabled in system settings. Enable them to receive awakening alerts."
            ),
            locationPermission: AwakeningPermissionInfo(
                identifier: "location",
                displayName: "Location",
                systemImage: "location.slash.fill",
                isGranted: false,
                isDeniedPermanently: false,
                description: "Location access is required for geofence awakening."
            ),
            healthPermission: AwakeningPermissionInfo(
                identifier: "health",
                displayName: "Health",
                systemImage: "heart.slash.fill",
                isGranted: false,
                isDeniedPermanently: false,
                description: "Health data access enables emotion-based memory awakening."
            ),
            isGeofenceEnabled: false,
            isEmotionEnabled: false,
            isAnniversaryEnabled: false,
            geofences: [],
            lastDailyPushDate: nil,
            lastEmotionAnalysisDate: nil,
            healthRequestState: .unsupported,
            healthDataState: .unavailable
        )
    }

    private func loadNoPermissionsFixture() throws -> AwakeningSettingsData {
        AwakeningSettingsData(
            notificationPermission: AwakeningPermissionInfo(
                identifier: "notification",
                displayName: "Notifications",
                systemImage: "bell.fill",
                isGranted: false,
                isDeniedPermanently: false,
                description: "Allow Echo to send you awakening notifications when memories surface."
            ),
            locationPermission: AwakeningPermissionInfo(
                identifier: "location",
                displayName: "Location",
                systemImage: "location.fill",
                isGranted: false,
                isDeniedPermanently: false,
                description: "Location access enables geofence-based memory delivery."
            ),
            healthPermission: AwakeningPermissionInfo(
                identifier: "health",
                displayName: "Health",
                systemImage: "heart.fill",
                isGranted: false,
                isDeniedPermanently: false,
                description: "Health data access enables mood-based memory delivery."
            ),
            isGeofenceEnabled: false,
            isEmotionEnabled: false,
            isAnniversaryEnabled: false,
            geofences: [],
            lastDailyPushDate: nil,
            lastEmotionAnalysisDate: nil,
            healthRequestState: .notRequested,
            healthDataState: .noReadableSamples
        )
    }

    private func loadAllDisabledFixture() throws -> AwakeningSettingsData {
        AwakeningSettingsData(
            notificationPermission: AwakeningPermissionInfo(
                identifier: "notification",
                displayName: "Notifications",
                systemImage: "bell.badge.fill",
                isGranted: true,
                isDeniedPermanently: false,
                description: "Echo sends awakening notifications for memories at places, on anniversaries, and when your mood changes."
            ),
            locationPermission: AwakeningPermissionInfo(
                identifier: "location",
                displayName: "Location",
                systemImage: "location.fill",
                isGranted: true,
                isDeniedPermanently: false,
                description: "Used for geofence-based memory awakening when you arrive at meaningful places."
            ),
            healthPermission: AwakeningPermissionInfo(
                identifier: "health",
                displayName: "Health",
                systemImage: "heart.fill",
                isGranted: true,
                isDeniedPermanently: false,
                description: "Used for emotion-based awakening to surface joyful memories when mood is low."
            ),
            isGeofenceEnabled: false,
            isEmotionEnabled: false,
            isAnniversaryEnabled: false,
            geofences: [
                GeofenceInfo(
                    id: "geo-campus",
                    displayName: "University Campus",
                    latitude: 37.7749,
                    longitude: -122.4194,
                    radiusMeters: 500,
                    isActive: true,
                    lastTriggeredAt: Date().addingTimeInterval(-86400 * 3),
                    memoryCount: 47
                )
            ],
            lastDailyPushDate: Date().addingTimeInterval(-86400 * 2),
            lastEmotionAnalysisDate: Date().addingTimeInterval(-3600 * 6),
            healthRequestState: .requestCompleted,
            healthDataState: .samplesAvailable
        )
    }
}
