// ==========================================
// File: AwakeningSettingsViewModel.swift
// Spec: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-001/002/003
//       docs/decisions/ADR-018-progressive-permission-orchestration.md
// Task: 4.0f - Progressive permissions and first-run production flow
// AC coverage: AC-3 persisted preferences; AC-4 independent notifications;
//              AC-5 staged location; AC-6 honest HealthKit request/data states
// Architecture: AGENTS.md §8.1 (@MainActor @Observable), §4.2 (value boundaries)
// Generated: 2026-09-04
// ==========================================

import Foundation
import SwiftUI
import UIKit

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
    let healthRequestState: HealthRequestState
    let healthDataState: HealthDataState

    init(
        notificationPermission: AwakeningPermissionInfo,
        locationPermission: AwakeningPermissionInfo,
        healthPermission: AwakeningPermissionInfo,
        isGeofenceEnabled: Bool,
        isEmotionEnabled: Bool,
        isAnniversaryEnabled: Bool,
        geofences: [GeofenceInfo],
        lastDailyPushDate: Date?,
        lastEmotionAnalysisDate: Date?,
        healthRequestState: HealthRequestState = .notRequested,
        healthDataState: HealthDataState = .noReadableSamples
    ) {
        self.notificationPermission = notificationPermission
        self.locationPermission = locationPermission
        self.healthPermission = healthPermission
        self.isGeofenceEnabled = isGeofenceEnabled
        self.isEmotionEnabled = isEmotionEnabled
        self.isAnniversaryEnabled = isAnniversaryEnabled
        self.geofences = geofences
        self.lastDailyPushDate = lastDailyPushDate
        self.lastEmotionAnalysisDate = lastEmotionAnalysisDate
        self.healthRequestState = healthRequestState
        self.healthDataState = healthDataState
    }
}

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

    private let fixtureLoader: AwakeningSettingsFixtureLoader
    private let locationProvider: (any LocationProviding)?
    private let healthStore: (any HealthStoreServing)?
    private let notificationScheduler: (any NotificationScheduling)?
    private let preferenceStore: AwakeningPreferenceActor?

    init(
        fixtureLoader: AwakeningSettingsFixtureLoader = .shared,
        locationProvider: (any LocationProviding)? = nil,
        healthStore: (any HealthStoreServing)? = nil,
        notificationScheduler: (any NotificationScheduling)? = nil,
        preferenceStore: AwakeningPreferenceActor? = nil
    ) {
        self.fixtureLoader = fixtureLoader
        self.locationProvider = locationProvider
        self.healthStore = healthStore
        self.notificationScheduler = notificationScheduler
        self.preferenceStore = preferenceStore
    }

    func loadSettings() async {
        state = .loading
        do {
            if let data = try await loadLiveData() {
                isFixtureBacked = false
                state = .completed(data)
                return
            }
            try await Task.sleep(for: .milliseconds(300))
            state = .completed(try fixtureLoader.loadSettings())
            isFixtureBacked = true
        } catch is CancellationError {
            state = .cancelled
        } catch {
            state = .error(.l2Recoverable(error.localizedDescription))
        }
    }

    private func loadLiveData() async throws -> AwakeningSettingsData? {
        guard locationProvider != nil || healthStore != nil || notificationScheduler != nil || preferenceStore != nil else {
            return nil
        }
        let preferences = try await preferenceStore?.load() ?? .defaults

        let notificationState = await notificationScheduler?.currentAuthorizationState() ?? .notDetermined
        let notification = AwakeningPermissionInfo(
            identifier: "notification",
            displayName: "Notifications",
            systemImage: notificationState.allowsDelivery ? "bell.badge.fill" : "bell.slash.fill",
            isGranted: notificationState.allowsDelivery,
            isDeniedPermanently: notificationState == .denied,
            description: "Local notification delivery is optional and independent from in-app awakening cards."
        )

        let locationState = await locationProvider?.currentAuthorizationState() ?? .notDetermined
        let locationGranted = locationState == .authorizedWhenInUse || locationState == .authorizedAlways
        let location = AwakeningPermissionInfo(
            identifier: "location",
            displayName: "Location",
            systemImage: locationGranted ? "location.fill" : "location.slash.fill",
            isGranted: locationGranted,
            isDeniedPermanently: locationState == .denied || locationState == .restricted,
            description: locationState == .authorizedWhenInUse
                ? "While Using access is enabled. Allow background location separately for terminated-app awakening."
                : "Location access enables geofence awakening."
        )

        let healthAvailable = healthStore?.isHealthDataAvailable() ?? false
        var healthDataState: HealthDataState = healthAvailable ? .noReadableSamples : .unavailable
        if healthAvailable, preferences.healthRequestState == .requestCompleted, let healthStore {
            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end
            let samples = try await healthStore.fetchHRVSamples(in: start...end)
            healthDataState = samples.isEmpty ? .noReadableSamples : .samplesAvailable
        }
        let health = AwakeningPermissionInfo(
            identifier: "health",
            displayName: "Health",
            systemImage: healthDataState == .samplesAvailable ? "heart.fill" : "heart",
            isGranted: false,
            isDeniedPermanently: false,
            description: Self.healthDescription(
                requestState: preferences.healthRequestState,
                dataState: healthDataState
            )
        )

        let regions = await locationProvider?.monitoredRegions() ?? []
        let geofences = regions.map {
            GeofenceInfo(
                id: $0.identifier,
                displayName: $0.identifier,
                latitude: $0.latitude,
                longitude: $0.longitude,
                radiusMeters: $0.radiusMeters,
                isActive: true,
                lastTriggeredAt: nil,
                memoryCount: 0
            )
        }

        return AwakeningSettingsData(
            notificationPermission: notification,
            locationPermission: location,
            healthPermission: health,
            isGeofenceEnabled: preferences.geofenceEnabled,
            isEmotionEnabled: preferences.emotionEnabled,
            isAnniversaryEnabled: preferences.anniversaryEnabled,
            geofences: geofences,
            lastDailyPushDate: nil,
            lastEmotionAnalysisDate: nil,
            healthRequestState: healthAvailable ? preferences.healthRequestState : .unsupported,
            healthDataState: healthDataState
        )
    }

    private static func healthDescription(requestState: HealthRequestState, dataState: HealthDataState) -> String {
        switch (requestState, dataState) {
        case (_, .unavailable), (.unsupported, _):
            "Health data is unavailable on this device."
        case (.notRequested, _):
            "You can optionally ask HealthKit for HRV read access. Echo cannot inspect the read authorization choice."
        case (.requestCompleted, .samplesAvailable):
            "Readable HRV samples are available for local emotion context."
        case (.requestCompleted, .noReadableSamples):
            "No readable HRV samples are available. Echo uses local query and feeling history instead."
        }
    }

    func toggleGeofenceAwakening(_ enabled: Bool) async {
        guard case .completed(let current) = state else { return }
        if isFixtureBacked {
            state = .completed(copy(current, geofence: enabled))
            return
        }
        do {
            var canEnable = !enabled
            if enabled, let locationProvider {
                var auth = await locationProvider.currentAuthorizationState()
                if auth == .notDetermined {
                    auth = await locationProvider.requestWhenInUseAuthorization()
                }
                canEnable = auth == .authorizedWhenInUse || auth == .authorizedAlways
            }
            if canEnable { try await preferenceStore?.setGeofenceEnabled(enabled) }
            await loadSettings()
        } catch {
            state = .error(.l2Recoverable(error.localizedDescription))
        }
    }

    func requestBackgroundLocationPermission() async {
        guard case .completed = state, let locationProvider else { return }
        _ = await locationProvider.requestAlwaysAuthorization()
        await loadSettings()
    }

    func toggleEmotionAwakening(_ enabled: Bool) async {
        guard case .completed(let current) = state else { return }
        if isFixtureBacked {
            state = .completed(copy(current, emotion: enabled))
            return
        }
        do {
            if enabled, let healthStore {
                guard healthStore.isHealthDataAvailable() else {
                    try await preferenceStore?.setHealthRequestState(.unsupported)
                    try await preferenceStore?.setEmotionEnabled(false)
                    await loadSettings()
                    return
                }
                let existing = try await preferenceStore?.load() ?? .defaults
                if existing.healthRequestState == .notRequested {
                    let result = await healthStore.requestReadAuthorization()
                    guard result == .completed else {
                        if result == .unsupported {
                            try await preferenceStore?.setHealthRequestState(.unsupported)
                        }
                        await loadSettings()
                        return
                    }
                    try await preferenceStore?.setHealthRequestState(.requestCompleted)
                }
            }
            try await preferenceStore?.setEmotionEnabled(enabled)
            await loadSettings()
        } catch {
            state = .error(.l2Recoverable(error.localizedDescription))
        }
    }

    func toggleAnniversaryAwakening(_ enabled: Bool) async {
        guard case .completed(let current) = state else { return }
        if isFixtureBacked {
            state = .completed(copy(current, anniversary: enabled))
            return
        }
        do {
            try await preferenceStore?.setAnniversaryEnabled(enabled)
            await loadSettings()
        } catch {
            state = .error(.l2Recoverable(error.localizedDescription))
        }
    }

    func requestNotificationPermission() async {
        notificationAuthStep = .requesting
        guard let notificationScheduler else {
            notificationAuthStep = .denied
            return
        }
        let auth = await notificationScheduler.requestAuthorization()
        notificationAuthStep = auth.allowsDelivery ? .granted : .denied
        try? await preferenceStore?.setNotificationDeliveryEnabled(auth.allowsDelivery)
        await loadSettings()
    }

    private func copy(
        _ data: AwakeningSettingsData,
        geofence: Bool? = nil,
        emotion: Bool? = nil,
        anniversary: Bool? = nil
    ) -> AwakeningSettingsData {
        AwakeningSettingsData(
            notificationPermission: data.notificationPermission,
            locationPermission: data.locationPermission,
            healthPermission: data.healthPermission,
            isGeofenceEnabled: geofence ?? data.isGeofenceEnabled,
            isEmotionEnabled: emotion ?? data.isEmotionEnabled,
            isAnniversaryEnabled: anniversary ?? data.isAnniversaryEnabled,
            geofences: data.geofences,
            lastDailyPushDate: data.lastDailyPushDate,
            lastEmotionAnalysisDate: data.lastEmotionAnalysisDate,
            healthRequestState: data.healthRequestState,
            healthDataState: data.healthDataState
        )
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func showGeofenceDetails(_ geofence: GeofenceInfo) { showGeofenceDetail = geofence }
    func dismissGeofenceDetail() { showGeofenceDetail = nil }
    func cancel() { state = .cancelled }
}
