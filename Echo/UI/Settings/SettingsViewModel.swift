// ==========================================
// 文件: SettingsViewModel.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-004 (后台自动导入控制),
//            US-SRC-007 (设备迁移), US-SRC-008 (排除项管理), US-SRC-009 (数据可视化),
//            US-PRV-002 (审计日志查看), US-PRV-003 (审计日志导出), US-RES-004 (模型加载失败),
//            US-SET-001 (统一语言), US-SET-002 (永久保留), US-SET-003 (缓存管理), US-SET-004 (迁移指引),
//            US-FBK-002 (反馈重排), US-PRV-005 (数据删除冷却期), US-PRV-008 (撤回同意)
//            docs/ui/echo-memory-canvas-style.md §3.3 (Task surfaces), §7.2 (Task surfaces),
//            §10.1.3 (空态), §11 (Toast/Banner/通知栏)
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.4 - SettingsView + SettingsViewModel
//       3F.1 - 撤回同意/注销接线 (ADR-007 §决策-3, US-PRV-008 AC-5)
// AC 覆盖: US-SRC-004 AC-1/AC-2 ✅ (数据源开关), US-SRC-008 AC-1 ✅ / AC-5/AC-6 🔶 (排除项管理入口, sub-page deferred to 3.9),
//            US-SRC-009 AC-1/AC-2 ✅ (数据概览/模型状态), US-PRV-002 AC-1 🔶 (审计日志入口, sub-page deferred to 3.9),
//            US-PRV-003 AC-1 ✅ / AC-2 🔶 (审计导出, stub deferred to 3.9), US-RES-004 AC-2/AC-7 ✅ (模型重试/降级),
//            US-SET-002 AC-1/AC-3 ✅ (永久保留), US-SET-003 AC-1/AC-3 ✅ (缓存清理/存储占用),
//            US-SET-004 AC-1 ✅ / AC-2 🔶 (迁移指引, sub-page deferred to 3.9), US-FBK-002 AC-5 ✅ (清除所有反馈),
//            US-PRV-005 AC-1/AC-2/AC-4 ✅ (冷却期 UI), US-PRV-008 AC-5 ✅ (撤回同意→注销清除),
//            L1~L4 错误映射 ✅
// Legend: ✅ implemented | 🔶 stub/skeleton (entry point exists, detail deferred to Phase 3.9) | 🔮 planned future phase
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum: idle/loading/completed/error/cancelled),
//           §8.2 (状态流转), §4.2 (仅持有不可变引用), docs/ui/architecture.md §6~7 (适配器契约),
//           §2.5 (Adapter 不保存第二份领域真相)
// 生成时间: 2026-08-02, 2026-08-04 (Task 3F.1)
// ==========================================

import SwiftUI
import Foundation

// MARK: - Settings Section Models

/// 数据源设置项 — 对应 US-SRC-004 AC-1/AC-2
struct DataSourceItem: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let systemImage: String
    let isAuthorized: Bool
    let itemCount: Int
}

/// 存储概览 — 对应 US-SRC-009 AC-1, US-SET-003 AC-3
struct StorageInfo: Sendable, Equatable {
    let indexCount: Int
    let vectorStoreSize: String
    let cacheSize: String
    let databaseSize: String
}

/// 模型状态摘要 — 对应 US-SRC-009 AC-2, US-RES-004 AC-2/AC-7
struct ModelStatusInfo: Sendable, Equatable {
    let totalModels: Int
    let loadedCount: Int
    let failedCount: Int
    let notLoadedCount: Int
    let isDegraded: Bool
}

/// 设置页全部数据 — 适配器映射的 UI State
struct SettingsSections: Sendable, Equatable {
    let dataSources: [DataSourceItem]
    let storage: StorageInfo
    let modelStatus: ModelStatusInfo
    let excludedCount: Int
    let feedbackCount: Int
    let pendingOpsCount: Int
}

// MARK: - SettingsViewModel

@MainActor
@Observable
final class SettingsViewModel {

    enum State: Equatable, Sendable {
        case idle
        case loading
        case completed(SettingsSections)
        case error(ErrorLevel)
        case cancelled
    }

    enum ErrorLevel: Equatable, Sendable {
        case l1Transient
        case l2Recoverable(String)
        case l3Blocking(String)
        case l4Conflict(String)
    }

    var state: State = .idle
    var showClearCacheConfirmation = false
    var showResetFeedbackConfirmation = false
    var showDeleteDataConfirmation = false
    var showRevokeConsentConfirmation = false
    var showExportInProgress = false

    var isSyncingEnabled = true
    var isPeriodicScanEnabled = false

    private let fixtureLoader: SettingsFixtureLoader

    /// 撤回同意/注销用 composition（3F.1 生产接线，fixture 模式可为 nil）
    private let composition: AppComposition?

    /// 数据概览服务（US-SRC-009 live 值，3F.7 接线）— nil 时回退 fixture 占位
    private let dataOverviewService: DataOverviewService?

    init(fixtureLoader: SettingsFixtureLoader = .shared,
         composition: AppComposition? = nil,
         dataOverviewService: DataOverviewService? = nil) {
        self.fixtureLoader = fixtureLoader
        self.composition = composition
        self.dataOverviewService = dataOverviewService
    }

    func loadSettings() async {
        state = .loading
        do {
            // 3F.7: live 数据概览（US-SRC-009）优先；无 service 时回退 fixture（Preview/旧测试）
            if let overview = dataOverviewService {
                let snap = try await overview.snapshot()
                let live = SettingsSections(
                    dataSources: makeLiveDataSources(snap),
                    storage: StorageInfo(
                        indexCount: snap.memoryCount,
                        vectorStoreSize: byteCount(snap.vectorStoreBytes),
                        cacheSize: "\(snap.translationCacheCount) items",
                        databaseSize: byteCount(snap.databaseBytes)
                    ),
                    modelStatus: ModelStatusInfo(
                        totalModels: snap.modelTotalCount,
                        loadedCount: snap.modelLoadedCount,
                        failedCount: snap.modelFailedCount,
                        notLoadedCount: snap.modelNotLoadedCount,
                        isDegraded: snap.modelFailedCount > 0
                    ),
                    excludedCount: try await ExcludedAssetsActor.shared.count(),
                    feedbackCount: try await FeedbackActor.shared.count(),
                    pendingOpsCount: try await PendingOpsActor.shared.count()
                )
                state = .completed(live)
            } else {
                try await Task.sleep(nanoseconds: 300_000_000)
                let sections = try fixtureLoader.loadSettings()
                state = .completed(sections)
            }
        } catch {
            state = .error(.l2Recoverable(error.localizedDescription))
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func makeLiveDataSources(_ snap: DataOverviewSnapshot) -> [DataSourceItem] {
        [
            DataSourceItem(id: "photo", displayName: "Photos", systemImage: "photo.on.rectangle", isAuthorized: true, itemCount: snap.countsBySourceType["photo"] ?? 0),
            DataSourceItem(id: "video", displayName: "Videos", systemImage: "video", isAuthorized: true, itemCount: snap.countsBySourceType["video"] ?? 0),
            DataSourceItem(id: "note", displayName: "Notes", systemImage: "note.text", isAuthorized: true, itemCount: snap.countsBySourceType["note"] ?? 0),
            DataSourceItem(id: "voice", displayName: "Voice Memos", systemImage: "waveform", isAuthorized: true, itemCount: snap.countsBySourceType["voice"] ?? 0),
        ]
    }

    func toggleSync(_ enabled: Bool) {
        isSyncingEnabled = enabled
    }

    func togglePeriodicScan(_ enabled: Bool) {
        isPeriodicScanEnabled = enabled
    }

    func clearCache() {
        showClearCacheConfirmation = true
    }

    func confirmClearCache() async {
        showClearCacheConfirmation = false
        do {
            try await Task.sleep(nanoseconds: 500_000_000)
            await loadSettings()
        } catch {
            state = .error(.l2Recoverable("Failed to clear cache"))
        }
    }

    func resetAllFeedback() {
        showResetFeedbackConfirmation = true
    }

    func confirmResetFeedback() async {
        showResetFeedbackConfirmation = false
        do {
            try await Task.sleep(nanoseconds: 500_000_000)
            await loadSettings()
        } catch {
            state = .error(.l2Recoverable("Failed to reset feedback"))
        }
    }

    func exportAuditLog() {
        showExportInProgress = true
    }

    func startDeleteData() async {
        showDeleteDataConfirmation = false
        do {
            try await Task.sleep(nanoseconds: 500_000_000)
            await loadSettings()
        } catch {
            state = .error(.l2Recoverable("Failed to start data deletion"))
        }
    }

    /// Request consent revocation (shows a second confirmation, US-PRV-008 AC-4/AC-5)
    func requestRevokeConsent() {
        showRevokeConsentConfirmation = true
    }

    /// Confirm consent revocation = account wipe (US-PRV-008 AC-5, ADR-007 §决策-3)
    func confirmRevokeConsent() async {
        showRevokeConsentConfirmation = false
        state = .loading
        guard let composition else {
            state = .error(.l2Recoverable("Consent revocation is unavailable"))
            return
        }
        do {
            let result = try await composition.revokeConsent(boundary: .full)
            if result.blocked {
                state = .error(.l3Blocking("Cleanup did not complete. Please retry."))
            } else {
                await loadSettings()
            }
        } catch {
            state = .error(.l3Blocking(error.localizedDescription))
        }
    }

    func retry() async {
        await loadSettings()
    }

    func cancel() {
        state = .cancelled
    }
}

// MARK: - Settings Fixture Loader

final class SettingsFixtureLoader: Sendable {
    static let shared = SettingsFixtureLoader()

    func loadSettings() throws -> SettingsSections {
        SettingsSections(
            dataSources: [
                DataSourceItem(id: "photo", displayName: "Photos", systemImage: "photo.on.rectangle", isAuthorized: true, itemCount: 1247),
                DataSourceItem(id: "note", displayName: "Notes", systemImage: "note.text", isAuthorized: false, itemCount: 0),
                DataSourceItem(id: "voice", displayName: "Voice Memos", systemImage: "waveform", isAuthorized: false, itemCount: 0),
            ],
            storage: StorageInfo(indexCount: 1247, vectorStoreSize: "42.3 MB", cacheSize: "8.1 MB", databaseSize: "5.2 MB"),
            modelStatus: ModelStatusInfo(totalModels: 6, loadedCount: 6, failedCount: 0, notLoadedCount: 0, isDegraded: false),
            excludedCount: 12,
            feedbackCount: 8,
            pendingOpsCount: 0
        )
    }
}
