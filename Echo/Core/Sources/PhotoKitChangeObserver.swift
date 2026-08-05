// ==========================================
// 文件: PhotoKitChangeObserver.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-012 (数据源内容变更自动同步),
//            docs/02-architecture/数据流全链路技术说明文档.md §4 (变更同步数据流)
//            docs/decisions/ADR-008-source-import-boundaries.md §决策-1 (PhotoKitChangeObserver 变更去重)
// 任务: 3F.2 - PhotoKit、Share Extension 与真实来源
// AC 覆盖: US-SRC-012 AC-1 (监听 PHPhotoLibraryChangeObserver → 生成 ChangeEvent),
//          ADR-008 §决策-1 (变更去重 — 批内去重于观察器，跨投递窗口去重于 SyncPipeline actor)
// 架构约束: AGENTS.md §4.2, R-007 (禁止 unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor；本类全部成员显式 nonisolated，
//       使其可被 SyncPipeline actor（非 MainActor）安全构造与注册，
//       PHPhotoLibraryChangeObserver 回调由系统在主线程投递
// 生成时间: 2026-08-05
// ==========================================

import Foundation
@preconcurrency import Photos

// MARK: - Change Event Builder

/// 从资产标识符数组构建 ChangeEvent（纯函数，可测试）。
///
/// US-SRC-012 AC-1：新增 → `.added`，修改 → `.modified`，删除 → `.removed`
public enum ChangeEventBuilder {
    public nonisolated static func events(
        inserted: [String],
        changed: [String],
        removed: [String]
    ) -> [ChangeEvent] {
        var events: [ChangeEvent] = []
        events.append(contentsOf: inserted.map {
            ChangeEvent(assetId: $0, source: .photo, changeType: .added)
        })
        events.append(contentsOf: changed.map {
            ChangeEvent(assetId: $0, source: .photo, changeType: .modified)
        })
        events.append(contentsOf: removed.map {
            ChangeEvent(assetId: $0, source: .photo, changeType: .removed)
        })
        return events
    }
}

// MARK: - Change Coalescer

/// 批内变更去重器（ADR-008 §决策-1）。
///
/// 纯函数：对同一 `assetId|changeType` 仅保留首次出现（PhotoKit 可能在单次投递中
/// 对同一资产重复回调）。跨投递的窗口去重由 SyncPipeline actor 的 recency 状态完成。
public struct ChangeCoalescer: Sendable {
    /// 去重窗口（秒）— 由 SyncPipeline actor 的 recency 剪枝使用
    public nonisolated let window: TimeInterval

    public nonisolated init(window: TimeInterval = 2.0) {
        self.window = window
    }

    /// 返回 `events` 中不重复的事件（按 `assetId|changeType`，忽略 `existing` 中已出现者）。
    public nonisolated func dedupe(_ events: [ChangeEvent], existing: [ChangeEvent]) -> [ChangeEvent] {
        var seen = Set<String>()
        for event in existing {
            seen.insert("\(event.assetId)|\(event.changeType.rawValue)")
        }
        var result: [ChangeEvent] = []
        for event in events {
            let key = "\(event.assetId)|\(event.changeType.rawValue)"
            if seen.insert(key).inserted {
                result.append(event)
            }
        }
        return result
    }
}

// MARK: - PhotoKit Change Observer

/// PhotoKit photo-library change observer (US-SRC-012 AC-1) — thin Photos boundary,
/// no mutable instance state.
///
/// - Implements `PHPhotoLibraryChangeObserver`; `photoLibraryDidChange` extracts
///   inserted/changed/removed asset localIdentifiers, builds `[ChangeEvent]`, dedupes,
///   then delivers
/// - All members `nonisolated`: safely constructed and registered from the
///   SyncPipeline actor (non-MainActor)
/// - Delivery closure is a `@Sendable` value type carrying only value-type ChangeEvents
/// - The monitored pre-change fetch result is cached in a dedicated @MainActor singleton
///   (`MonitoredFetchResult`), avoiding instance @MainActor state (Swift 6 rejects
///   nonisolated callbacks capturing self with a sending data race; verified on CI
///   Xcode 16.4)
public final class PhotoKitChangeObserver: NSObject, PHPhotoLibraryChangeObserver {

    /// 变更事件投递闭包（@Sendable 值类型，只携带值类型 ChangeEvent）
    public nonisolated let onPhotoLibraryChange: (@Sendable ([ChangeEvent]) -> Void)?
    private nonisolated let coalescer: ChangeCoalescer

    public nonisolated init(
        onPhotoLibraryChange: (@Sendable ([ChangeEvent]) -> Void)? = nil,
        coalescer: ChangeCoalescer = ChangeCoalescer()
    ) {
        self.onPhotoLibraryChange = onPhotoLibraryChange
        self.coalescer = coalescer
        super.init()
    }

    // MARK: - PHPhotoLibraryChangeObserver

    /// PhotoKit 回调：提取变更标识符 → 构建事件 → 批内去重 → 投递。
    ///
    /// Apple 文档确认 `photoLibraryDidChange` 在**任意后台队列**调用（非主线程），
    /// 不能用 `MainActor.assumeIsolated`（非主线程会 trap）。MonitoredFetchResult 是
    /// @MainActor 单例（PHFetchResult 非 Sendable），故用 `Task { @MainActor }` 跳转；
    /// 闭包只捕获 Sendable 局部常量（deliver + coalescer），不捕获 self
    /// （NSObject 非 Sendable），满足 Xcode 16.4 Swift 6 严格并发。
    public nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // 提取局部常量，使 Task 闭包完全不捕获 self
        let deliver = onPhotoLibraryChange
        let coalescer = self.coalescer
        Task { @MainActor in
            guard let identifiers = MonitoredFetchResult.assetIdentifiers(from: changeInstance)
            else { return }
            let events = ChangeEventBuilder.events(
                inserted: identifiers.inserted,
                changed: identifiers.changed,
                removed: identifiers.removed
            )
            guard !events.isEmpty else { return }
            let deduped = coalescer.dedupe(events, existing: [])
            guard !deduped.isEmpty else { return }
            deliver?(deduped)
        }
    }

    /// 处理资产标识符变更（内部可测试入口；photoLibraryDidChange 提取后调用）。
    ///
    /// - Returns: 去重后实际投递的变更事件（空数组表示无有效变更）
    internal nonisolated func consumeForTesting(
        inserted: [String],
        changed: [String],
        removed: [String]
    ) -> [ChangeEvent] {
        let events = ChangeEventBuilder.events(inserted: inserted, changed: changed, removed: removed)
        guard !events.isEmpty else { return [] }
        // 批内去重（ADR-008 §决策-1）；跨投递窗口去重由 SyncPipeline 负责
        let deduped = coalescer.dedupe(events, existing: [])
        guard !deduped.isEmpty else { return [] }
        onPhotoLibraryChange?(deduped)
        return deduped
    }
}

// MARK: - Monitored Fetch Result

/// Cache of the monitored pre-change fetch result (CodeRabbit #2).
///
/// `PHChange.changeDetails(for:)` only returns a delta for the fetch result that
/// represents the pre-change state; passing a fresh result makes the system report
/// "no changes" and drop the ChangeEvent (US-SRC-012 AC-1).
///
/// Threading: PHFetchResult is not Sendable, so this is a @MainActor singleton;
/// seeding is a plain assignment and `PHAsset.fetchAssets` is thread-safe, so the
/// caller may seed from any thread. `assetIdentifiers` is only ever invoked from
/// `photoLibraryDidChange`, which hops to MainActor via Task.
/// (Swift 6 rejects nonisolated static mutable state and NSLock-held globals;
/// @MainActor isolation is the only compliant storage — CI Xcode 16.4 verified.)
@MainActor
internal enum MonitoredFetchResult {
    private static var result: PHFetchResult<PHAsset>?

    /// Extracts inserted/changed/removed asset localIdentifiers from PHChange.
    ///
    /// Lazily seeds the pre-change fetch result on first callback (CodeRabbit #2/#6):
    /// `changeDetails(for:)` must receive a result captured before the change; a fresh
    /// result makes the system report "no changes" and drop the event. Called from
    /// `photoLibraryDidChange` on MainActor (via Task).
    static func assetIdentifiers(from changeInstance: PHChange)
        -> (inserted: [String], changed: [String], removed: [String])? {
        if result == nil {
            result = PHAsset.fetchAssets(with: nil)
        }
        guard let fetch = result,
              let details = changeInstance.changeDetails(for: fetch) else { return nil }
        result = details.fetchResultAfterChanges
        return (
            inserted: details.insertedObjects.map(\.localIdentifier),
            changed: details.changedObjects.map(\.localIdentifier),
            removed: details.removedObjects.map(\.localIdentifier)
        )
    }
}
