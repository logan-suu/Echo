// ==========================================
// File: 4.0f_ProgressivePermissionFlowTests.swift
// Spec: docs/01-spec/用户故事与验收标准规格书.md → US-PRV-008, US-SRC-001,
//       US-AWK-001, US-AWK-002, US-AWK-003
// Task: 4.0f - Progressive permissions and first-run production flow
// AC coverage: AC-1 consent persistence gate; AC-2 optional Photos request;
//              AC-3 persisted awakening preferences; AC-4 independent notifications;
//              AC-5 staged location; AC-6 honest HealthKit read semantics
// Architecture: AGENTS.md §4.2, §8.1; ADR-018
// Generated: 2026-09-04
// ==========================================

import Foundation
import Testing
import UserNotifications
@testable import Echo

@MainActor
private final class ProgressivePhotoRequesterSpy: OnboardingPermissionRequesting {
    var result: OnboardingPhotoAccessState = .authorized
    private(set) var requestCount = 0

    func request(_ permission: OnboardingPermission) async -> Bool {
        requestCount += 1
        return result.allowsAccess
    }

    func requestPhotos() async -> OnboardingPhotoAccessState {
        requestCount += 1
        return result
    }
}

@MainActor
private final class ProgressiveLocationSpy: LocationProviding {
    var state: LocationAuthState = .notDetermined
    private(set) var whenInUseRequests = 0
    private(set) var alwaysRequests = 0
    private let stream = AsyncStream<GeofenceEvent> { $0.finish() }

    var eventStream: AsyncStream<GeofenceEvent> { stream }

    func currentAuthorizationState() async -> LocationAuthState { state }
    func requestWhenInUseAuthorization() async -> LocationAuthState {
        whenInUseRequests += 1
        state = .authorizedWhenInUse
        return state
    }
    func requestAlwaysAuthorization() async -> LocationAuthState {
        alwaysRequests += 1
        state = .authorizedAlways
        return state
    }
    func startMonitoring(region: GeofenceRegion) async throws {}
    func stopMonitoring(regionIdentifier: String) async {}
    func monitoredRegions() async -> [GeofenceRegion] { [] }
}

@MainActor
private final class ProgressiveNotificationSpy: NotificationScheduling {
    var state: NotificationAuthState = .notDetermined
    private(set) var requestCount = 0

    func currentAuthorizationState() async -> NotificationAuthState { state }
    func requestAuthorization() async -> NotificationAuthState {
        requestCount += 1
        return state
    }
    func schedule(_ content: EchoNotificationContent, at date: Date) async -> String? { nil }
    func cancel(identifier: String) async {}
}

private actor ProgressiveHealthSpy: HealthStoreServing {
    var available = true
    var requestResult: HealthAuthorizationRequestResult = .completed
    var samples: [MinimizedHealthSample] = []
    private(set) var requestCount = 0
    private(set) var fetchCount = 0

    nonisolated func isHealthDataAvailable() -> Bool { true }
    func currentAuthorizationState() async -> HealthAuthState { .notDetermined }
    func requestAuthorization() async -> HealthAuthState { .notDetermined }
    func requestReadAuthorization() async -> HealthAuthorizationRequestResult {
        requestCount += 1
        return requestResult
    }
    func fetchHRVSamples(in window: ClosedRange<Date>?) async throws -> [MinimizedHealthSample] {
        fetchCount += 1
        return samples
    }
    func counts() -> (requests: Int, fetches: Int) { (requestCount, fetchCount) }
}

@Suite("ProgressivePermissionFlowTests", .serialized)
@MainActor
struct ProgressivePermissionFlowTests {
    private func makeDatabase() async throws -> (DatabaseManager, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-4.0f-\(UUID().uuidString).sqlite")
        let db = DatabaseManager(databaseURL: url)
        try await db.open()
        return (db, url)
    }

    @Test("AC-1: failed consent persistence blocks every protected permission request")
    func consentFailureBlocksPermissions() async throws {
        let (db, _) = try await makeDatabase()
        let consent = ConsentStoreActor(db: db, privacyActor: .shared)
        await consent.setConsentWriteFault(true)
        let photos = ProgressivePhotoRequesterSpy()
        let viewModel = OnboardingViewModel(consentStore: consent, permissionRequester: photos)

        viewModel.start()
        viewModel.acceptPrivacy()
        await viewModel.waitForConsentPersistence()

        #expect(viewModel.viewState == .consentPersistError)
        #expect(photos.requestCount == 0)
        #expect(await consent.hasConsented() == false)
    }

    @Test("AC-1: retry advances only after consent is durable")
    func consentRetryRequiresDurableWrite() async throws {
        let (db, _) = try await makeDatabase()
        let consent = ConsentStoreActor(db: db, privacyActor: .shared)
        await consent.setConsentWriteFault(true)
        let viewModel = OnboardingViewModel(consentStore: consent)
        viewModel.start()
        viewModel.acceptPrivacy()
        await viewModel.waitForConsentPersistence()
        await consent.setConsentWriteFault(false)

        viewModel.retryConsentPersistence()
        await viewModel.waitForConsentPersistence()

        #expect(viewModel.viewState == .permissions(0))
        let relaunched = ConsentStoreActor(db: db, privacyActor: .shared)
        try await relaunched.loadState()
        #expect(await relaunched.hasConsented())
    }

    @Test("AC-2: onboarding exposes Photos only and Not Now makes no system request")
    func photosOnlyAndNotNowIsSilent() {
        let photos = ProgressivePhotoRequesterSpy()
        let viewModel = OnboardingViewModel(permissionRequester: photos)
        viewModel.start()
        viewModel.acceptPrivacy()

        #expect(viewModel.permissionSteps.map(\.id) == ["photos"])
        viewModel.skipOptionalPhotos()
        #expect(viewModel.viewState == .language)
        #expect(photos.requestCount == 0)
    }

    @Test("AC-2: limited Photos access is an honest successful state")
    func limitedPhotosAdvances() async {
        let photos = ProgressivePhotoRequesterSpy()
        photos.result = .limited
        let viewModel = OnboardingViewModel(permissionRequester: photos)
        viewModel.start()
        viewModel.acceptPrivacy()

        viewModel.allowPermission()
        await viewModel.waitForPermissionRequest()

        #expect(viewModel.photoAccessState == .limited)
        #expect(viewModel.viewState == .language)
        #expect(photos.requestCount == 1)
    }

    @Test("AC-3: awakening preferences survive a new actor instance")
    func preferencesPersistAcrossRelaunch() async throws {
        let (db, _) = try await makeDatabase()
        let first = AwakeningPreferenceActor(db: db)
        try await first.setGeofenceEnabled(true)
        try await first.setEmotionEnabled(true)
        try await first.setAnniversaryEnabled(true)
        try await first.setNotificationDeliveryEnabled(true)
        try await first.setHealthRequestState(.requestCompleted)

        let relaunched = AwakeningPreferenceActor(db: db)
        let value = try await relaunched.load()
        #expect(value.geofenceEnabled)
        #expect(value.emotionEnabled)
        #expect(value.anniversaryEnabled)
        #expect(value.notificationDeliveryEnabled)
        #expect(value.healthRequestState == .requestCompleted)
    }

    @Test("AC-3: full consent revocation purges awakening preferences")
    func consentRevocationPurgesPreferences() async throws {
        let (db, _) = try await makeDatabase()
        let preferences = AwakeningPreferenceActor(db: db)
        try await preferences.setGeofenceEnabled(true)
        try await preferences.setNotificationDeliveryEnabled(true)
        let consent = ConsentStoreActor(db: db, privacyActor: .shared)
        try await consent.acceptConsent(consentVersion: 1, policyVersion: 1)

        _ = try await consent.revokeConsent()

        #expect(try await preferences.load() == .defaults)
    }

    @Test("AC-4/5/6: loading settings reads snapshots without requesting permissions")
    func loadingSettingsNeverPrompts() async throws {
        let (db, _) = try await makeDatabase()
        let preferences = AwakeningPreferenceActor(db: db)
        let location = ProgressiveLocationSpy()
        let notifications = ProgressiveNotificationSpy()
        let health = ProgressiveHealthSpy()
        let viewModel = AwakeningSettingsViewModel(
            locationProvider: location,
            healthStore: health,
            notificationScheduler: notifications,
            preferenceStore: preferences
        )

        await viewModel.loadSettings()

        #expect(location.whenInUseRequests == 0)
        #expect(location.alwaysRequests == 0)
        #expect(notifications.requestCount == 0)
        #expect(await health.counts().requests == 0)
    }

    @Test("AC-4: anniversary preference is independent from notification authorization")
    func anniversaryDoesNotRequestNotifications() async throws {
        let (db, _) = try await makeDatabase()
        let preferences = AwakeningPreferenceActor(db: db)
        let notifications = ProgressiveNotificationSpy()
        notifications.state = .denied
        let viewModel = AwakeningSettingsViewModel(
            notificationScheduler: notifications,
            preferenceStore: preferences
        )
        await viewModel.loadSettings()

        await viewModel.toggleAnniversaryAwakening(true)

        #expect((try await preferences.load()).anniversaryEnabled)
        #expect(notifications.requestCount == 0)
    }

    @Test("AC-4: provisional and ephemeral notification states allow local delivery")
    func notificationAuthorizationMappingIncludesDeliveryStates() {
        #expect(LocalNotificationAdapter.map(.provisional) == .provisional)
        #expect(LocalNotificationAdapter.map(.ephemeral) == .ephemeral)
        #expect(NotificationAuthState.provisional.allowsDelivery)
        #expect(NotificationAuthState.ephemeral.allowsDelivery)
    }

    @Test("AC-5: location requests are staged by two explicit actions")
    func locationAuthorizationIsStaged() async throws {
        let (db, _) = try await makeDatabase()
        let preferences = AwakeningPreferenceActor(db: db)
        let location = ProgressiveLocationSpy()
        let viewModel = AwakeningSettingsViewModel(
            locationProvider: location,
            preferenceStore: preferences
        )
        await viewModel.loadSettings()

        await viewModel.toggleGeofenceAwakening(true)
        #expect(location.whenInUseRequests == 1)
        #expect(location.alwaysRequests == 0)
        #expect((try await preferences.load()).geofenceEnabled)

        await viewModel.requestBackgroundLocationPermission()
        #expect(location.alwaysRequests == 1)
    }

    @Test("AC-6: completed HealthKit request with no readable samples remains honest")
    func healthRequestDoesNotClaimReadAuthorization() async throws {
        let (db, _) = try await makeDatabase()
        let preferences = AwakeningPreferenceActor(db: db)
        let health = ProgressiveHealthSpy()
        let viewModel = AwakeningSettingsViewModel(
            healthStore: health,
            preferenceStore: preferences
        )
        await viewModel.loadSettings()

        await viewModel.toggleEmotionAwakening(true)

        guard case .completed(let data) = viewModel.state else {
            Issue.record("Expected completed settings state")
            return
        }
        #expect(data.healthRequestState == .requestCompleted)
        #expect(data.healthDataState == .noReadableSamples)
        #expect(data.healthPermission.isGranted == false)
        #expect((try await preferences.load()).emotionEnabled)
    }
}
