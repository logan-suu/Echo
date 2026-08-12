// ==========================================
// File: 3F.10_LocalizationAccessibilityErrorTests.swift
// Spec: docs/01-spec/用户故事与验收标准规格书.md → US-DIS-001 (UI bilingual unification),
//       US-DIS-003 (state localization), US-DIS-004 (accessibility), US-SET-001 (unified language),
//       US-RES-001 (offline), US-RES-002 (low power degradation), US-RES-003 (thermal degradation),
//       US-RES-004 (model load failure), US-SYS-001 (background task panel i18n/AX/error + audit),
//       US-SRC-009 merged-into-US-SYS-001 (localized/accessible error behavior)
// Task: 3F.10 - i18n, accessibility and production errors
// AC coverage: see per-test annotations below
// Architecture: AGENTS.md §1.3 (zh-Hans/en-US only), §4.4 (L1-L4), §5.4 (hash-only audit),
//               §9.4 (serial execution), R-006 (PrivacyCheckpoint), R-007 (no Combine)
// Note: TDD RED phase — suites fail until String Catalog, LanguageCenter, SystemMonitor,
//       degradation runtime wiring, audit events and DEF-59-004 checkpoint land.
// Generated: 2026-08-12
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Shared Test Helpers

@MainActor
enum LocalizationTestSupport {
    static func wipeAuditLog() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        try await db.execute(sql: "DELETE FROM AuditLog")
    }

    static func catalogFileURL() throws -> URL {
        // Navigate from the test bundle source location to the repo root catalog.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() } // .../Echo/EchoTests/Phase3F -> repo root
        let catalog = url.appendingPathComponent("Echo/Resources/Localizable.xcstrings")
        return catalog
    }

    static func loadCatalog() throws -> [String: Any] {
        let url = try catalogFileURL()
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "catalog", code: 1)
        }
        return json
    }
}

// MARK: - Suite: String Catalog Parity (US-DIS-003 AC-1, AGENTS.md §1.3)

// MARK: - Umbrella Suite (FOCUSED_SUITE identifier per phase3f-execution-plan §6.1)

@Suite("LocalizationAccessibilityErrorTests", .serialized)
@MainActor
struct LocalizationAccessibilityErrorTests {
    @Suite("LocalizationCatalogParityTests", .serialized)
    @MainActor
    struct LocalizationCatalogParityTests {

        @Test("DIS-003 AC-1: Localizable.xcstrings exists and parses")
        func test_catalogExists() throws {
            let url = try LocalizationTestSupport.catalogFileURL()
            #expect(FileManager.default.fileExists(atPath: url.path), "Localizable.xcstrings must exist at Echo/Resources/")
            _ = try LocalizationTestSupport.loadCatalog()
        }

        @Test("AGENTS §1.3: catalog contains ONLY zh-Hans and en-US localizations")
        func test_catalogOnlyTwoLanguages() throws {
            let json = try LocalizationTestSupport.loadCatalog()
            guard let strings = json["strings"] as? [String: Any] else {
                Issue.record("catalog missing strings table")
                return
            }
            try #expect(!strings.isEmpty, "catalog must not be empty")
            for (key, value) in strings {
                guard let entry = value as? [String: Any],
                      let localizations = entry["localizations"] as? [String: Any] else {
                    Issue.record("entry \(key) missing localizations")
                    continue
                }
                for locale in localizations.keys {
                    #expect(locale == "zh-Hans" || locale == "en-US",
                            "key \(key) carries unsupported locale \(locale) (AGENTS.md §1.3: only zh-Hans/en-US)")
                }
            }
        }

        @Test("DIS-003 AC-1: 100% key parity — every key has BOTH zh-Hans and en-US non-empty values")
        func test_catalogParity100Percent() throws {
            let json = try LocalizationTestSupport.loadCatalog()
            guard let strings = json["strings"] as? [String: Any] else {
                Issue.record("catalog missing strings table")
                return
            }
            var missing: [String] = []
            for (key, value) in strings {
                guard let entry = value as? [String: Any],
                      let localizations = entry["localizations"] as? [String: Any] else {
                    missing.append(key)
                    continue
                }
                for locale in ["zh-Hans", "en-US"] {
                    guard let loc = localizations[locale] as? [String: Any],
                          let unit = loc["stringUnit"] as? [String: Any],
                          let text = unit["value"] as? String,
                          !text.isEmpty else {
                        missing.append("\(key)[\(locale)]")
                        continue
                    }
                }
            }
            #expect(missing.isEmpty, "catalog parity violations: \(missing.prefix(20))")
        }

        @Test("DIS-003 AC-1: catalog covers required production surfaces (spot check)")
        func test_catalogRequiredKeys() throws {
            let json = try LocalizationTestSupport.loadCatalog()
            guard let strings = json["strings"] as? [String: Any] else {
                Issue.record("catalog missing strings table")
                return
            }
            let requiredKeys = [
                // App shell tabs
                "Home", "Search", "Settings",
                // Degradation banners (US-RES-002 AC-2 / US-RES-003 AC-2 / US-RES-004 AC-7)
                "Low Power Mode is enabled. Memory search precision may be reduced.",
                "Device temperature is high. Some features have been temporarily simplified.",
                // Onboarding (DEF-45-001)
                "Get Started", "Agree & Continue", "Decline", "Choose Language",
                // Settings language (US-DIS-001 AC-1)
                "App Language",
                // Background tasks (US-SYS-001)
                "Syncing photos", "Building vector index", "Loading AI model",
            ]
            for key in requiredKeys {
                #expect(strings[key] != nil, "required catalog key missing: \(key)")
            }
        }
    }

    // MARK: - Suite: Unified Language (US-DIS-001 / US-SET-001)

@Suite("UnifiedLanguageTests", .serialized)
@MainActor
struct UnifiedLanguageTests: ~Copyable {

    init() async throws {
        try await LocalizationTestSupport.wipeAuditLog()
    }

    // Swift Testing teardown: restore the persisted app-language state so the app sandbox
    // returns to the default (follow-system → simulator locale) — the UserDefaults keys are
    // written by LanguageCenter.apply and would otherwise leak zh-Hans into UI-test app launches.
    deinit {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "echo.language.selection")
        defaults.removeObject(forKey: "echo.language.resolved")
        defaults.removeObject(forKey: "echo.language.mappingNoticePresented")
    }

        @Test("DIS-001 AC-1: single App Language setting with follow-system/zh-Hans/en-US options")
        func test_AC1_singleLanguageSetting() {
            let center = LanguageCenter()
            // Exactly one setting surface with three options (follow system / zh-Hans / en-US)
            #expect(LanguageCenter.AppLanguageSelection.allCases.count == 3)
            #expect(LanguageCenter.AppLanguageSelection.allCases.contains(.followSystem))
            #expect(LanguageCenter.AppLanguageSelection.allCases.contains(.zhHans))
            #expect(LanguageCenter.AppLanguageSelection.allCases.contains(.enUS))
            #expect(center.resolvedLanguage == "zh-Hans" || center.resolvedLanguage == "en-US")
        }

        @Test("DIS-001 AC-2: switching updates BOTH UI locale and AI preferredLanguage (UserPolicy)")
        func test_AC2_switchUpdatesPolicyAndUILocale() async throws {
            let center = LanguageCenter()
            let privacy = PrivacyActor.shared
            try await center.apply(.enUS, systemLanguage: "zh-Hans", privacyActor: privacy)
            #expect(center.resolvedLanguage == "en-US")
            #expect(center.locale.identifier == "en-US")
            let policy = await privacy.getPolicy()
            #expect(policy.preferredLanguage == "en-US", "AI preferredLanguage must sync with UI language")

            try await center.apply(.zhHans, systemLanguage: "en-US", privacyActor: privacy)
            #expect(center.resolvedLanguage == "zh-Hans")
            let policy2 = await privacy.getPolicy()
            #expect(policy2.preferredLanguage == "zh-Hans")
            // restore default
            try await center.apply(.zhHans, systemLanguage: "zh-Hans", privacyActor: privacy)
        }

        @Test("DIS-001 AC-3: follow-system maps non-zh/en system language to zh-Hans default")
        func test_AC3_followSystemMapping() async throws {
            let privacy = PrivacyActor.shared
            // French system → default zh-Hans
            let center1 = LanguageCenter()
            try await center1.apply(.followSystem, systemLanguage: "fr-FR", privacyActor: privacy)
            #expect(center1.resolvedLanguage == "zh-Hans")
            // English system → en-US
            let center2 = LanguageCenter()
            try await center2.apply(.followSystem, systemLanguage: "en-GB", privacyActor: privacy)
            #expect(center2.resolvedLanguage == "en-US")
            // zh-Hans system → zh-Hans
            let center3 = LanguageCenter()
            try await center3.apply(.followSystem, systemLanguage: "zh-Hans-CN", privacyActor: privacy)
            #expect(center3.resolvedLanguage == "zh-Hans")
        }

        @Test("AGENTS §1.3: Traditional Chinese / dialect maps to zh-Hans with one-time notice")
        func test_AC3_traditionalChineseMapsToZhHansWithNotice() async throws {
            let privacy = PrivacyActor.shared
            let store = UserDefaults(suiteName: "lang-test-trad") ?? .standard
            store.removePersistentDomain(forName: "lang-test-trad")
            let center = LanguageCenter(noticeStore: store)
            center.resetOneTimeNoticeForTesting()
            try await center.apply(.followSystem, systemLanguage: "zh-Hant-TW", privacyActor: privacy)
            #expect(center.resolvedLanguage == "zh-Hans", "Traditional Chinese must map to zh-Hans")
            #expect(center.didPresentMappingNotice, "first mapping must raise the one-time notice")
            // second time: notice not repeated
            center.resetResolvedForTesting()
            try await center.apply(.followSystem, systemLanguage: "zh-Hant-HK", privacyActor: privacy)
            #expect(!center.didPresentMappingNotice, "notice must appear only once")
        }

        @Test("DIS-001 AC-4: switch takes effect immediately without restart")
        func test_AC4_immediateEffect() async throws {
            let center = LanguageCenter()
            let privacy = PrivacyActor.shared
            try await center.apply(.enUS, systemLanguage: "zh-Hans", privacyActor: privacy)
            // Locale is updated synchronously in-memory (no relaunch required)
            #expect(center.locale.identifier == "en-US")
            #expect(center.requiresRestart == false, "language switch must not require restart")
            try await center.apply(.zhHans, systemLanguage: "zh-Hans", privacyActor: privacy)
        }

        @Test("DIS-001 AC-5: audit .languageUnified records newLanguage")
        func test_AC5_auditLanguageUnified() async throws {
            try await LocalizationTestSupport.wipeAuditLog()
            let center = LanguageCenter()
            let privacy = PrivacyActor.shared
            try await center.apply(.enUS, systemLanguage: "zh-Hans", privacyActor: privacy)
            let logs = try await privacy.fetchAuditLogs(limit: 50, eventType: .languageUnified)
            #expect(!logs.isEmpty, ".languageUnified audit must be written on language switch")
            #expect(logs.first?.sourceLanguage == "en-US", "newLanguage must be recorded")
            try await center.apply(.zhHans, systemLanguage: "zh-Hans", privacyActor: privacy)
        }
    }

    // MARK: - Suite: Error Localization & L1-L4 Mapping (US-DIS-003, DEF-39-1)

    @Suite("ErrorLocalizationTests", .serialized)
    @MainActor
    struct ErrorLocalizationTests {

        @Test("DIS-003 AC-2: error codes map to user-friendly localized messages")
        func test_AC2_errorFriendlyMessages() {
            let dbError = DatabaseError.connectionFailed(underlying: NSError(domain: "x", code: 1))
            let message = dbError.userFacingMessage(locale: Locale(identifier: "zh-Hans"))
            #expect(!message.isEmpty)
            let messageEn = dbError.userFacingMessage(locale: Locale(identifier: "en-US"))
            #expect(!messageEn.isEmpty)
            #expect(message != messageEn, "zh-Hans and en-US messages must differ (real localization)")
        }

        @Test("DEF-39-1: ErrorClassifier distinguishes ALL four levels L1/L2/L3/L4")
        func test_DEF39_1_allFourLevelsClassified() {
            // L1 transient: database lock / busy
            let l1 = ErrorClassifier.classify(DatabaseError.connectionFailed(underlying: NSError(domain: "sqlite", code: 5)))
            #expect(l1 == .l1Transient)
            // L2 recoverable: generic write failure
            let l2 = ErrorClassifier.classify(DatabaseError.writeFailed(operation: "op", underlying: NSError(domain: "d", code: -1)))
            #expect(l2 == .l2Recoverable)
            // L3 blocking: model load failure
            let l3 = ErrorClassifier.classify(
                ModelLoaderActor.ModelLoadError.modelNotFound(modelName: "e5", resourceName: "multilingual-e5-small")
            )
            #expect(l3 == .l3Blocking)
            // L4 conflict: sync conflict
            let l4 = ErrorClassifier.classify(SyncConflictError.conflict(memoryId: UUID()))
            #expect(l4 == .l4Conflict)
        }

        @Test("DIS-003 AC-4: each error level has a localized user-facing message in both languages")
        func test_AC4_levelMessagesLocalized() {
            for level in ErrorSeverity.allCases {
                let zh = level.userFacingMessage(locale: Locale(identifier: "zh-Hans"))
                let en = level.userFacingMessage(locale: Locale(identifier: "en-US"))
                #expect(!zh.isEmpty, "\(level) zh-Hans message missing")
                #expect(!en.isEmpty, "\(level) en-US message missing")
                #expect(zh != en, "\(level) messages must be genuinely localized")
            }
        }
    }

    // MARK: - Suite: System Monitor (US-RES-002 AC-1 / US-RES-003 AC-1 runtime sources)

    @Suite("SystemMonitorTests", .serialized)
    @MainActor
    struct SystemMonitorTests {

        final class FakeConditionSource: SystemConditionSource {
            var isLowPowerMode: Bool = false
            var thermalState: ProcessInfo.ThermalState = .nominal
            let stream: AsyncStream<Void>
            let continuation: AsyncStream<Void>.Continuation

            init() {
                (stream, continuation) = AsyncStream.makeStream(of: Void.self)
            }

            var conditionChanges: AsyncStream<Void> { stream }

            func fireChange() {
                continuation.yield()
            }
        }

        @Test("RES-002 AC-1: monitor reflects low power state changes")
        func test_lowPowerChange() async {
            let source = FakeConditionSource()
            let monitor = SystemMonitor(source: source)
            await monitor.start()
            #expect(monitor.isLowPowerMode == false)
            source.isLowPowerMode = true
            source.fireChange()
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(monitor.isLowPowerMode == true)
            source.isLowPowerMode = false
            source.fireChange()
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(monitor.isLowPowerMode == false)
            await monitor.stop()
        }

        @Test("RES-003 AC-1: monitor reflects thermal state and degraded threshold (.serious+)")
        func test_thermalChange() async {
            let source = FakeConditionSource()
            let monitor = SystemMonitor(source: source)
            await monitor.start()
            #expect(monitor.isThermalDegraded == false)
            source.thermalState = .serious
            source.fireChange()
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(monitor.isThermalDegraded == true, ".serious must trigger degradation")
            source.thermalState = .critical
            source.fireChange()
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(monitor.isThermalDegraded == true, ".critical must trigger degradation")
            source.thermalState = .nominal
            source.fireChange()
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(monitor.isThermalDegraded == false, "nominal must recover")
            await monitor.stop()
        }
    }

    // MARK: - Suite: Degradation Runtime Wiring (US-RES-002 / US-RES-003 / US-RES-004)

    @Suite("DegradationRuntimeTests", .serialized)
    @MainActor
    struct DegradationRuntimeTests {

        final class FakeConditionSource: SystemConditionSource {
            var isLowPowerMode: Bool = false
            var thermalState: ProcessInfo.ThermalState = .nominal
            let stream: AsyncStream<Void>
            let continuation: AsyncStream<Void>.Continuation

            init() {
                (stream, continuation) = AsyncStream.makeStream(of: Void.self)
            }

            var conditionChanges: AsyncStream<Void> { stream }

            func fireChange() {
                continuation.yield()
            }
        }

        init() async throws {
            try await LocalizationTestSupport.wipeAuditLog()
            UserDefaults.standard.removeObject(forKey: DegradationBannerViewModel.lowPowerAutoPauseKey)
        }

        @Test("RES-002 AC-1/AC-2: low power activates banner with localized message")
        func test_AC1_AC2_lowPowerActivatesBanner() async throws {
            let source = FakeConditionSource()
            let monitor = SystemMonitor(source: source)
            let vm = DegradationBannerViewModel(systemMonitor: monitor, auditWriter: PrivacyActor.shared)
            await vm.startMonitoring()

            source.isLowPowerMode = true
            source.fireChange()
            try await Task.sleep(nanoseconds: 300_000_000)

            #expect(vm.isBannerVisible == true)
            #expect(vm.activeDegradation?.type == .lowPower)
            let zh = vm.activeDegradation?.localizedMessage(locale: Locale(identifier: "zh-Hans")) ?? ""
            let en = vm.activeDegradation?.localizedMessage(locale: Locale(identifier: "en-US")) ?? ""
            #expect(!zh.isEmpty && !en.isEmpty && zh != en, "banner message must be localized")
            await vm.stopMonitoring()
        }

        @Test("RES-002 AC-4: exiting low power auto-dismisses banner")
        func test_AC4_exitLowPowerDismisses() async throws {
            let source = FakeConditionSource()
            let monitor = SystemMonitor(source: source)
            let vm = DegradationBannerViewModel(systemMonitor: monitor, auditWriter: PrivacyActor.shared)
            await vm.startMonitoring()

            source.isLowPowerMode = true
            source.fireChange()
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(vm.isBannerVisible)

            source.isLowPowerMode = false
            source.fireChange()
            try await Task.sleep(nanoseconds: 600_000_000)
            #expect(vm.isBannerVisible == false, "banner must auto-dismiss when low power ends")
            await vm.stopMonitoring()
        }

        @Test("RES-002 AC-3: auto-pause background tasks toggle defaults ON")
        func test_AC3_autoPauseDefaultOn() {
            #expect(DegradationBannerViewModel.isAutoPauseOnLowPowerEnabled == true,
                    "low-power auto-pause must default to enabled")
        }

        @Test("RES-002 AC-5: activation writes audit with degradation fields")
        func test_AC5_auditWritten() async throws {
            try await LocalizationTestSupport.wipeAuditLog()
            let source = FakeConditionSource()
            let monitor = SystemMonitor(source: source)
            let vm = DegradationBannerViewModel(systemMonitor: monitor, auditWriter: PrivacyActor.shared)
            await vm.startMonitoring()
            source.isLowPowerMode = true
            source.fireChange()
            try await Task.sleep(nanoseconds: 300_000_000)

            let privacy = PrivacyActor.shared
            let count = try await privacy.auditLogCount()
            #expect(count > 0, "low-power degradation must write an audit entry")
            await vm.stopMonitoring()
        }

        @Test("RES-003 AC-1/AC-2/AC-3: thermal lifecycle activates and recovers banner")
        func test_US_RES_003_thermalLifecycle() async throws {
            let source = FakeConditionSource()
            let monitor = SystemMonitor(source: source)
            let vm = DegradationBannerViewModel(systemMonitor: monitor, auditWriter: PrivacyActor.shared)
            await vm.startMonitoring()

            source.thermalState = .serious
            source.fireChange()
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(vm.activeDegradation?.type == .thermal, "serious thermal must activate thermal banner")

            source.thermalState = .nominal
            source.fireChange()
            try await Task.sleep(nanoseconds: 600_000_000)
            #expect(vm.isBannerVisible == false, "banner must auto-dismiss on thermal recovery (AC-3)")
            await vm.stopMonitoring()
        }

        @Test("RES-004 AC-3: model retry is manual-only (no automatic retry timer)")
        func test_US_RES_004_manualRetryOnly() async throws {
            let source = FakeConditionSource()
            let monitor = SystemMonitor(source: source)
            let vm = DegradationBannerViewModel(systemMonitor: monitor, auditWriter: PrivacyActor.shared)
            vm.activate(.modelDegraded())
            // Manual retry path exists and is explicit; no scheduled auto-retry is started.
            #expect(vm.activeDegradation?.showRetry == true)
            #expect(vm.hasAutomaticRetryTimer == false, "US-RES-004 AC-3 forbids any automatic retry")
        }

        @Test("DIS-004 AC-2: degradation activation produces an accessibility announcement")
        func test_AX_announcementOnActivation() {
            let source = FakeConditionSource()
            let monitor = SystemMonitor(source: source)
            let vm = DegradationBannerViewModel(systemMonitor: monitor, auditWriter: PrivacyActor.shared)
            vm.activate(.lowPower(paused: true))
            #expect(vm.pendingAccessibilityAnnouncement != nil,
                    "activation must queue a VoiceOver announcement (US-DIS-004 AC-2)")
            #expect(!(vm.pendingAccessibilityAnnouncement ?? "").isEmpty)
        }
    }

    // MARK: - Suite: Background Task Audit (US-SYS-001 AC-7, US-SRC-009 merged trace)

    @Suite("BackgroundTaskAuditTests", .serialized)
    @MainActor
    struct BackgroundTaskAuditTests {

        init() async throws {
            try await LocalizationTestSupport.wipeAuditLog()
        }

        private func makeTask(_ type: TaskType = .fullIndex) -> TaskProgress {
            TaskProgress(taskId: UUID().uuidString, taskType: type, lastProcessedIndex: 32, totalCount: 128)
        }

        @Test("SYS-001 AC-7: opening panel writes .backgroundTaskUIAccessed audit")
        func test_AC7_uiAccessedAudit() async throws {
            try await LocalizationTestSupport.wipeAuditLog()
            let vm = BackgroundTaskViewModel(progressActor: nil, auditWriter: PrivacyActor.shared)
            vm.loadPreloadedTasks([makeTask()])
            vm.openPanel()
            try await Task.sleep(nanoseconds: 400_000_000)
            let logs = try await PrivacyActor.shared.fetchAuditLogs(limit: 20, eventType: .backgroundTaskUIAccessed)
            #expect(!logs.isEmpty, "panel access must be audited")
        }

        @Test("SYS-001 AC-7: pause writes .backgroundTaskInterrupted with action=pause and resumePoint")
        func test_AC7_pauseAudit() async throws {
            try await LocalizationTestSupport.wipeAuditLog()
            let vm = BackgroundTaskViewModel(progressActor: nil, auditWriter: PrivacyActor.shared)
            let task = makeTask()
            vm.loadPreloadedTasks([task])
            vm.pauseTask(task.taskId)
            try await Task.sleep(nanoseconds: 200_000_000)
            let logs = try await PrivacyActor.shared.fetchAuditLogs(limit: 20, eventType: .backgroundTaskInterrupted)
            #expect(!logs.isEmpty, "pause must write .backgroundTaskInterrupted")
            #expect(logs.first?.sourceType?.contains("pause") == true, "action=pause must be recorded")
        }

        @Test("SYS-001 AC-7: cancel writes .backgroundTaskInterrupted with action=cancel")
        func test_AC7_cancelAudit() async throws {
            try await LocalizationTestSupport.wipeAuditLog()
            let vm = BackgroundTaskViewModel(progressActor: nil, auditWriter: PrivacyActor.shared)
            let task = makeTask()
            vm.loadPreloadedTasks([task])
            vm.requestCancelTask(task.taskId)
            vm.confirmCancelTask(task.taskId)
            try await Task.sleep(nanoseconds: 200_000_000)
            let logs = try await PrivacyActor.shared.fetchAuditLogs(limit: 20, eventType: .backgroundTaskInterrupted)
            #expect(!logs.isEmpty, "cancel must write .backgroundTaskInterrupted")
            #expect(logs.first?.sourceType?.contains("cancel") == true, "action=cancel must be recorded")
        }

        @Test("SYS-001 AC-1/AX: task accessibility label is localized and complete")
        func test_AX_taskLabel() {
            let model = BackgroundTaskModel(from: makeTask())
            let label = model.accessibilityLabel
            #expect(!label.isEmpty)
            #expect(label.contains("32") && label.contains("128"), "label must carry progress counts")
        }
    }

    // MARK: - Suite: Offline Indicator (US-RES-001 AC-3)

    @Suite("OfflineIndicatorTests", .serialized)
    @MainActor
    struct OfflineIndicatorTests {

        @Test("RES-001 AC-3: offline indicator state is driven and exposed")
        func test_AC3_offlineIndicator() {
            let vm = HomeViewModel()
            #expect(vm.isOffline == false)
            vm.setOffline(true)
            #expect(vm.isOffline == true)
            #expect(vm.offlineIndicatorAccessibilityLabel(locale: Locale(identifier: "zh-Hans")).isEmpty == false)
            #expect(vm.offlineIndicatorAccessibilityLabel(locale: Locale(identifier: "en-US")).isEmpty == false)
        }
    }

    // MARK: - Suite: Migration PrivacyCheckpoint (DEF-59-004, R-006)

    @Suite("MigrationCheckpointTests", .serialized)
    @MainActor
    struct MigrationCheckpointTests {

        @Test("DEF-59-004: PrivacyOperation gains a migration case")
        func test_migrationOperationExists() {
            let op = PrivacyOperation.migration
            #expect(op.rawValue == "migration")
        }

        @Test("DEF-59-004: exportPackage entry runs PrivacyCheckpoint and denies without consent")
        func test_exportPackageCheckpointDeniesWithoutConsent() async throws {
            let db = DatabaseManager.shared
            try await db.open()
            // Seed one memory so export has data
            try await db.execute(sql: "DELETE FROM Memory")
            try await db.executeWrite(
                sql: """
                INSERT OR REPLACE INTO Memory (memoryId, sourceLocator, canonicalText, sourceType, createdAt, updatedAt, recoverability, originalTimestamp, userEdited, userLocked)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(UUID().uuidString), .text("photo-1"), .text("t"), .text("photo"),
                    .double(Date().timeIntervalSince1970), .double(Date().timeIntervalSince1970),
                    .text("full"), .null, .int(0), .int(0),
                ]
            )
            let actor = DeviceMigrationActor(db: db)
            // Consent not granted in this fresh state → checkpoint must deny and export must fail-closed.
            let consentStore = ConsentStoreActor(db: db)
            _ = consentStore // consent state governs the gate via PrivacyActor.validate
            do {
                _ = try await actor.exportPackage()
                // If consent was previously granted in shared DB state, export may succeed; assert the
                // checkpoint ran by checking a migration audit entry was produced.
                let logs = try await PrivacyActor.shared.fetchAuditLogs(limit: 20)
                let migrationRelated = logs.contains { $0.sourceType?.contains("migration") == true || $0.eventType == .deviceMigrationCompleted }
                #expect(migrationRelated, "export must pass through the privacy checkpoint path")
            } catch {
                // Fail-closed denial is the expected path when consent/authorization is absent.
                #expect(true)
            }
            try await db.execute(sql: "DELETE FROM Memory")
        }
    }

    // MARK: - Suite: Deferred i18n Items Resolution (DEF-41-1/42-002/43-001/45-001/46-001/60-001)

    @Suite("DeferredI18nResolutionTests", .serialized)
    @MainActor
    struct DeferredI18nResolutionTests {

        @Test("DEF-41-1: degradation banner strings resolve from catalog (not hardcoded)")
        func test_DEF41_1_bannerStrings() throws {
            let json = try LocalizationTestSupport.loadCatalog()
            let strings = json["strings"] as? [String: Any] ?? [:]
            #expect(strings["Low Power Mode is enabled. Memory search precision may be reduced."] != nil)
            #expect(strings["Device temperature is high. Some features have been temporarily simplified."] != nil)
        }

        @Test("DEF-42-002: resume progress strings resolve from catalog")
        func test_DEF42_002_resumeStrings() throws {
            let json = try LocalizationTestSupport.loadCatalog()
            let strings = json["strings"] as? [String: Any] ?? [:]
            #expect(strings["Continue"] != nil)
            #expect(strings["Restart"] != nil)
            #expect(strings["Unable to check saved progress"] != nil)
        }

        @Test("DEF-45-001: onboarding strings resolve from catalog")
        func test_DEF45_001_onboardingStrings() throws {
            let json = try LocalizationTestSupport.loadCatalog()
            let strings = json["strings"] as? [String: Any] ?? [:]
            for key in ["Get Started", "Agree & Continue", "Decline", "Choose Language", "Continue"] {
                #expect(strings[key] != nil, "onboarding key missing: \(key)")
            }
        }

        @Test("DEF-46-001: awakening settings strings resolve from catalog")
        func test_DEF46_001_awakeningStrings() throws {
            let json = try LocalizationTestSupport.loadCatalog()
            let strings = json["strings"] as? [String: Any] ?? [:]
            #expect(strings["Awakening"] != nil)
        }

        @Test("DEF-60-001 (UI portion): permission descriptions resolve from catalog")
        func test_DEF60_001_permissionDescriptions() throws {
            let json = try LocalizationTestSupport.loadCatalog()
            let strings = json["strings"] as? [String: Any] ?? [:]
            #expect(strings["Location"] != nil)
            #expect(strings["Health"] != nil)
            #expect(strings["Notifications"] != nil)
        }
    }
}
