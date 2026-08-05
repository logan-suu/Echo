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

/// PhotoKit 相册变更观察者（US-SRC-012 AC-1）— 薄 Photos 边界，无可变状态。
///
/// - 实现 `PHPhotoLibraryChangeObserver`，在 `photoLibraryDidChange` 中提取
///   新增/修改/删除资产的 localIdentifier，构建 `[ChangeEvent]` 批内去重后投递
/// - 全部成员 `nonisolated`：可在 SyncPipeline actor（非 MainActor）中安全构造与注册
/// - 投递闭包为 `@Sendable` 值类型，不携带可变 PHAsset 引用
public final class PhotoKitChangeObserver: NSObject, PHPhotoLibraryChangeObserver {

    /// 变更事件投递闭包（@Sendable 值类型，只携带值类型 ChangeEvent）
    public nonisolated let onPhotoLibraryChange: (@Sendable ([ChangeEvent]) -> Void)?
    private nonisolated let coalescer: ChangeCoalescer

    /// 被监控的 pre-change fetch result（PHChange.changeDetails(for:) 必须传入变更前的结果，
    /// 每次新建 fresh result 会令系统认为"无变化"而丢失 ChangeEvent，CodeRabbit #2）。
    /// PHFetchResult 非 Sendable，仅在主线程（photoLibraryDidChange 回调线程）访问。
    @MainActor
    private var monitoredFetchResult: PHFetchResult<PHAsset>?

    public nonisolated init(
        onPhotoLibraryChange: (@Sendable ([ChangeEvent]) -> Void)? = nil,
        coalescer: ChangeCoalescer = ChangeCoalescer()
    ) {
        self.onPhotoLibraryChange = onPhotoLibraryChange
        self.coalescer = coalescer
        super.init()
    }

    /// 注册时种子化被监控的 fetch result（MainActor 上下文调用）。
    @MainActor
    public func seedMonitoredFetchResult(_ result: PHFetchResult<PHAsset>) {
        monitoredFetchResult = result
    }

    // MARK: - PHPhotoLibraryChangeObserver

    /// PhotoKit 回调（主线程）：提取变更标识符 → 构建事件 → 批内去重 → 投递。
    public nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            guard let identifiers = self.assetIdentifiers(from: changeInstance) else { return }
            _ = self.consumeForTesting(
                inserted: identifiers.inserted,
                changed: identifiers.changed,
                removed: identifiers.removed
            )
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

    // MARK: - Private Helpers

    /// 从 PHChange 提取资产新增/修改/删除的 localIdentifier 数组。
    ///
    /// PHChange 无法在测试中构造，故提取逻辑保持在此（薄 Photos 边界），
    /// 可测试的纯映射在 ChangeEventBuilder / consumeForTesting。
    /// 使用缓存的 pre-change fetch result（CodeRabbit #2）：changeDetails(for:) 必须
    /// 接收变更前的 fetch result 才会返回差异；首次无缓存时用 fresh result 并降级为 nil。
    @MainActor
    private func assetIdentifiers(from changeInstance: PHChange)
        -> (inserted: [String], changed: [String], removed: [String])? {
        let fetch = monitoredFetchResult ?? PHAsset.fetchAssets(with: nil)
        guard let details = changeInstance.changeDetails(for: fetch) else { return nil }
        monitoredFetchResult = details.fetchResultAfterChanges
        return (
            inserted: details.insertedObjects.map(\.localIdentifier),
            changed: details.changedObjects.map(\.localIdentifier),
            removed: details.removedObjects.map(\.localIdentifier)
        )
    }
}
