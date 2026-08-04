// ==========================================
// 文件: SettingsViewModelTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-004/008/009,
//            US-PRV-002/005, US-RES-004, US-SET-002/003, US-FBK-002
// 任务: 3.4 - SettingsView + SettingsViewModel
// AC 覆盖: US-SRC-004 AC-1/AC-2, US-SRC-008 AC-1, US-SRC-009 AC-1/AC-2,
//            US-PRV-002 AC-1, US-PRV-005 AC-1/AC-2/AC-4, US-RES-004 AC-2,
//            US-SET-002 AC-1, US-SET-003 AC-1/AC-3, US-FBK-002 AC-5
// 测试层级: 单元测试（Adapter/ViewModel 状态映射）
// 生成时间: 2026-08-02
// ==========================================

import Testing
import Foundation
@testable import Echo

@MainActor
struct SettingsViewModelTests {

    @Test func stateFlowIdleToCompleted() async throws {
        let vm = SettingsViewModel()
        #expect(vm.state == .idle)

        await vm.loadSettings()

        guard case .completed(let sections) = vm.state else {
            Issue.record("Expected .completed, got \(vm.state)")
            return
        }

        #expect(sections.dataSources.count == 3)
        #expect(sections.dataSources.first(where: { $0.id == "photo" })?.isAuthorized == true)
        #expect(sections.dataSources.first(where: { $0.id == "photo" })?.itemCount == 1247)
        #expect(sections.storage.indexCount == 1247)
    }

    @Test func dataSourcesIncludePhotosNotesVoice() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()

        guard case .completed(let sections) = vm.state else { Issue.record("Expected .completed"); return }
        let ids = sections.dataSources.map(\.id)
        #expect(ids.contains("photo"))
        #expect(ids.contains("note"))
        #expect(ids.contains("voice"))
    }

    @Test func storageOverviewHasAllFields() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        guard case .completed(let sections) = vm.state else { Issue.record("Expected .completed"); return }
        #expect(sections.storage.indexCount == 1247)
        #expect(!sections.storage.vectorStoreSize.isEmpty)
        #expect(!sections.storage.cacheSize.isEmpty)
        #expect(!sections.storage.databaseSize.isEmpty)
    }

    @Test func modelStatusAllLoaded() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        guard case .completed(let sections) = vm.state else { Issue.record("Expected .completed"); return }
        #expect(sections.modelStatus.totalModels == 6)
        #expect(sections.modelStatus.loadedCount == 6)
        #expect(sections.modelStatus.failedCount == 0)
        #expect(sections.modelStatus.isDegraded == false)
    }

    @Test func excludedItemsCount() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        guard case .completed(let sections) = vm.state else { Issue.record("Expected .completed"); return }
        #expect(sections.excludedCount == 12)
    }

    @Test func feedbackCountPresent() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        guard case .completed(let sections) = vm.state else { Issue.record("Expected .completed"); return }
        #expect(sections.feedbackCount == 8)
    }

    @Test func pendingOpsCountZero() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        guard case .completed(let sections) = vm.state else { Issue.record("Expected .completed"); return }
        #expect(sections.pendingOpsCount == 0)
    }

    @Test func resetFeedbackConfirmationToggle() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        #expect(vm.showResetFeedbackConfirmation == false)
        vm.resetAllFeedback()
        #expect(vm.showResetFeedbackConfirmation == true)
        await vm.confirmResetFeedback()
        #expect(vm.showResetFeedbackConfirmation == false)
    }

    @Test func clearCacheConfirmationToggle() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        #expect(vm.showClearCacheConfirmation == false)
        vm.clearCache()
        #expect(vm.showClearCacheConfirmation == true)
        await vm.confirmClearCache()
        #expect(vm.showClearCacheConfirmation == false)
    }

    @Test func deleteDataConfirmationFlag() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        #expect(vm.showDeleteDataConfirmation == false)
        vm.showDeleteDataConfirmation = true
        #expect(vm.showDeleteDataConfirmation == true)
        vm.showDeleteDataConfirmation = false
        #expect(vm.showDeleteDataConfirmation == false)
    }

    @Test func retryTransitionsLoadingToCompleted() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        guard case .completed = vm.state else { Issue.record("Expected .completed"); return }
        await vm.retry()
        guard case .completed = vm.state else { Issue.record("Expected .completed after retry"); return }
    }

    @Test func toggleSyncDefaultOn() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        #expect(vm.isSyncingEnabled == true)
        vm.toggleSync(false)
        #expect(vm.isSyncingEnabled == false)
        vm.toggleSync(true)
        #expect(vm.isSyncingEnabled == true)
    }

    @Test func togglePeriodicScanDefaultOff() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        #expect(vm.isPeriodicScanEnabled == false)
        vm.togglePeriodicScan(true)
        #expect(vm.isPeriodicScanEnabled == true)
    }

    @Test func initialStateIsIdle() {
        let vm = SettingsViewModel()
        #expect(vm.state == .idle)
    }

    @Test func cancelState() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        vm.cancel()
        guard case .cancelled = vm.state else { Issue.record("Expected .cancelled"); return }
    }

    @Test func exportAuditLogTriggersFlag() async throws {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        #expect(vm.showExportInProgress == false)
        vm.exportAuditLog()
        #expect(vm.showExportInProgress == true)
    }

    // MARK: - 3F.1: Revoke consent (US-PRV-008 AC-5, ADR-007 §决策-3)

    @Test func requestRevokeConsentShowsConfirmation() async throws {
        let vm = SettingsViewModel()
        #expect(vm.showRevokeConsentConfirmation == false)
        vm.requestRevokeConsent()
        #expect(vm.showRevokeConsentConfirmation == true)
    }

    @Test func confirmRevokeConsentWithoutCompositionReportsUnavailable() async throws {
        let vm = SettingsViewModel(composition: nil)
        vm.requestRevokeConsent()
        await vm.confirmRevokeConsent()
        guard case .error(.l2Recoverable(let message)) = vm.state else {
            Issue.record("Expected l2Recoverable error, got \(vm.state)")
            return
        }
        #expect(message.contains("unavailable"))
    }

    @Test func confirmRevokeConsentWithCompositionTriggersPurge() async throws {
        let db = DatabaseManager.shared
        let privacy = PrivacyActor(db: db)
        try await db.open()
        try await db.execute(sql: "DELETE FROM ConsentStore")
        try await db.execute(sql: "DELETE FROM AuditLog")
        let store = ConsentStoreActor(db: db, privacyActor: privacy)
        try await store.acceptConsent(consentVersion: 1, policyVersion: 1)
        let composition = AppComposition(
            databaseManager: db,
            privacyActor: privacy,
            consentStore: store
        )
        await composition.bootstrap()
        #expect(composition.startupState == .ready)

        let vm = SettingsViewModel(composition: composition)
        vm.requestRevokeConsent()
        #expect(vm.showRevokeConsentConfirmation == true)
        await vm.confirmRevokeConsent()

        #expect(vm.showRevokeConsentConfirmation == false)
        #expect(composition.startupState == .requiresConsent)
        #expect(await store.hasConsented() == false)

        await privacy.disableConsentEnforcement()
    }
}
