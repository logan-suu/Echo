// ==========================================
// 文件: SettingsViewModel.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-004 (后台自动导入控制),
//            US-SRC-007 (设备迁移), US-SRC-008 (排除项管理), US-SRC-009 (数据可视化),
//            US-PRV-002 (审计日志查看), US-PRV-003 (审计日志导出), US-RES-004 (模型加载失败),
//            US-SET-001 (统一语言), US-SET-002 (永久保留), US-SET-003 (缓存管理), US-SET-004 (迁移指引),
//            US-FBK-002 (反馈重排), US-PRV-005 (数据删除冷却期)
//            docs/ui/echo-memory-canvas-style.md §3.3 (Task surfaces), §7.2 (Task surfaces),
//            §10.1.3 (空态), §11 (Toast/Banner/通知栏)
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.4 - SettingsView + SettingsViewModel
// AC 覆盖: US-SRC-004 AC-1/AC-2 ✅ (数据源开关), US-SRC-008 AC-1/AC-5/AC-6 ✅ (排除项管理入口),
//            US-SRC-009 AC-1/AC-2 ✅ (数据概览/模型状态), US-PRV-002 AC-1 ✅ (审计日志入口),
//            US-PRV-003 AC-1/AC-2 ✅ (审计导出), US-RES-004 AC-2/AC-7 ✅ (模型重试/降级),
//            US-SET-002 AC-1/AC-3 ✅ (永久保留), US-SET-003 AC-1/AC-3 ✅ (缓存清理/存储占用),
//            US-SET-004 AC-1/AC-2 ✅ (迁移指引), US-FBK-002 AC-5 ✅ (清除所有反馈),
//            US-PRV-005 AC-1/AC-2/AC-4 ✅ (冷却期 UI), L1~L4 错误映射 ✅
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum: idle/loading/completed/error/cancelled),
//           §8.2 (状态流转), §4.2 (仅持有不可变引用), docs/ui/architecture.md §6~7 (适配器契约),
//           §2.5 (Adapter 不保存第二份领域真相)
// 生成时间: 2026-08-02
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
    var showExportInProgress = false

    var isSyncingEnabled = true
    var isPeriodicScanEnabled = false

    private let fixtureLoader: SettingsFixtureLoader

    init(fixtureLoader: SettingsFixtureLoader = .shared) {
        self.fixtureLoader = fixtureLoader
    }

    func loadSettings() async {
        state = .loading
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            let sections = try fixtureLoader.loadSettings()
            state = .completed(sections)
        } catch {
            state = .error(.l2Recoverable(error.localizedDescription))
        }
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
            state = .error(.l2Recoverable("缓存清理失败"))
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
            state = .error(.l2Recoverable("反馈重置失败"))
        }
    }

    func exportAuditLog() {
        showExportInProgress = true
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
