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

/// PhotoKit 相册变更观察者（US-SRC-012 AC-1）— 薄 Photos 边界，无实例可变状态。
///
/// - 实现 `PHPhotoLibraryChangeObserver`，在 `photoLibraryDidChange` 中提取
///   新增/修改/删除资产的 localIdentifier，构建 `[ChangeEvent]` 批内去重后投递
/// - 全部成员 `nonisolated`：可在 SyncPipeline actor（非 MainActor）中安全构造与注册
/// - 投递闭包为 `@Sendable` 值类型，不携带可变 PHAsset 引用
/// - 被监控的 pre-change fetch result 缓存在独立 @MainActor 单例（`MonitoredFetchResult`），
///   避免 observer 实例持有 @MainActor 状态（Swift 6 下 nonisolated 回调捕获 self 会报
///   sending data race，CI Xcode 16.4 验证）
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

    /// PhotoKit 回调（系统保证主线程投递）：提取变更标识符 → 构建事件 → 批内去重 → 投递。
    ///
    /// PHPhotoLibraryChangeObserver 回调在主线程，用 MainActor.assumeIsolated 同步访问
    /// 缓存的 pre-change fetch result；闭包只引用 @MainActor 静态单例，不捕获 self，
    /// 满足 Swift 6 严格并发（CI Xcode 16.4 -strict-concurrency=complete）。
    public nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // 提取局部常量，使 assumeIsolated 闭包完全不捕获 self（NSObject 子类 non-Sendable，
        // Xcode 16.4 Swift 6 下捕获 self 报 sending data race）
        let deliver = onPhotoLibraryChange
        let coalescer = self.coalescer
        MainActor.assumeIsolated {
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

/// 被监控的 pre-change fetch result 缓存（CodeRabbit #2）。
///
/// `PHChange.changeDetails(for:)` 必须接收变更前的 fetch result 才会返回差异；
/// 每次新建 fresh result 会令系统认为"无变化"而丢失 ChangeEvent（US-SRC-012 AC-1）。
/// PHFetchResult 非 Sendable，缓存在 @MainActor 单例（回调保证主线程，同步访问安全）；
/// observer 保持无实例状态，避免 nonisolated 回调捕获 self 的 Swift 6 data race。
@MainActor
internal enum MonitoredFetchResult {
    private static var result: PHFetchResult<PHAsset>?

    /// 注册时种子化（MainActor 上下文调用）。
    static func seed(_ fetchResult: PHFetchResult<PHAsset>) {
        result = fetchResult
    }

    /// 从 PHChange 提取资产新增/修改/删除的 localIdentifier 数组（主线程调用）。
    ///
    /// 使用缓存的 pre-change fetch result；首次无缓存时用 fresh result 并降级为 nil。
    static func assetIdentifiers(from changeInstance: PHChange)
        -> (inserted: [String], changed: [String], removed: [String])? {
        let fetch = result ?? PHAsset.fetchAssets(with: nil)
        guard let details = changeInstance.changeDetails(for: fetch) else { return nil }
        result = details.fetchResultAfterChanges
        return (
            inserted: details.insertedObjects.map(\.localIdentifier),
            changed: details.changedObjects.map(\.localIdentifier),
            removed: details.removedObjects.map(\.localIdentifier)
        )
    }
}
