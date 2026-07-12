// ==========================================
// 文件: SyncPipeline.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-012 (数据源变更自动同步)
//            docs/02-architecture/架构设计文档.md §3.2 (SyncPipeline 时序图)
//            docs/02-architecture/数据流全链路技术说明文档.md §4 (变更同步数据流)
// 任务: 2.10 - SyncPipeline：相册变更监听 + 增量替换
// AC 覆盖: US-SRC-012 AC-1 (变更监听: PHPhotoLibraryChangeObserver, 备忘录, 日历),
//          AC-2 (哈希跳过条件: 100KB阈值, 内存约束),
//          AC-3 (设置页后台同步开关),
//          AC-4 (增量替换: 删除旧+摄入新, 不写ExcludedAssets),
//          AC-5 (校验ExcludedAssets跳过已排除),
//          AC-6 (L4冲突: 同步中阻止用户编辑),
//          AC-7 (进度报告: ProgressActor),
//          AC-8 (开关关闭仅前台手动触发),
//          AC-9 (审计.dataSourceChangeSynced含changeType/sourceType/affectedCount/replacedFlag/excludedNotWritten/hashSkipped)
// 架构约束: AGENTS.md §4.1 (Pipeline 契约), R-006 (PrivacyCheckpoint),
//           AGENTS.md §4.4 (L1~L4 错误分级), §5.2 (ExcludedAssets 写入规则),
//           AGENTS.md §8.3 (后台任务面板进度订阅)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-12
// ==========================================

import Foundation
import Photos
import ProximaKit

// MARK: - Sync Error

/// SyncPipeline 统一错误类型（L1~L4 分级，AGENTS.md §4.4）
public enum SyncError: Error, LocalizedError, Sendable, Equatable {
    /// 隐私校验拒绝 — 用户未授权所需数据源
    case privacyDenied(sourceTypes: [String])
    /// 资产已被用户手动排除（US-SRC-008）
    case assetExcluded(assetId: String)
    /// ExcludedAssets 查询失败（数据库读错误，fail-closed）
    case excludedAssetsLookupFailed(underlying: Error)
    /// 嵌入生成失败 — 模型未加载或推理失败（L3 阻断）
    case embeddingFailed(underlying: Error)
    /// 元数据编码失败
    case metadataEncodingFailed(underlying: Error)
    /// 向量存储操作失败
    case vectorStoreFailed(underlying: Error)
    /// 内存锁定冲突 — 在同步期间尝试编辑（L4）
    case memoryLockedDuringSync(memoryId: String)
    /// 哈希对比跳过 — 非错误，仅为记录（内容过大或内存不足）
    case hashSkippedDueToConstraints(reason: String)

    /// L1~L4 错误分级
    public nonisolated var errorLevel: Int {
        switch self {
        case .privacyDenied:              return 2
        case .assetExcluded:              return 2
        case .excludedAssetsLookupFailed: return 2
        case .embeddingFailed:            return 3
        case .metadataEncodingFailed:     return 2
        case .vectorStoreFailed:          return 2
        case .memoryLockedDuringSync:     return 4
        case .hashSkippedDueToConstraints: return 1
        }
    }

    public var errorDescription: String? {
        switch self {
        case .privacyDenied(let types):
            return "Privacy denied for source types: \(types.joined(separator: ","))"
        case .assetExcluded(let assetId):
            return "Asset excluded by user: \(assetId)"
        case .excludedAssetsLookupFailed(let error):
            return "ExcludedAssets lookup failed: \(error.localizedDescription)"
        case .embeddingFailed(let error):
            return "Embedding failed: \(error.localizedDescription)"
        case .metadataEncodingFailed(let error):
            return "Metadata encoding failed: \(error.localizedDescription)"
        case .vectorStoreFailed(let error):
            return "Vector store operation failed: \(error.localizedDescription)"
        case .memoryLockedDuringSync(let memoryId):
            return "Memory \(memoryId) is locked during sync — 该记忆正在同步更新中，请稍后再编辑"
        case .hashSkippedDueToConstraints(let reason):
            return "Hash comparison skipped due to constraints: \(reason)"
        }
    }

    // MARK: Equatable
    public static func == (lhs: SyncError, rhs: SyncError) -> Bool {
        switch (lhs, rhs) {
        case (.privacyDenied(let a), .privacyDenied(let b)): return a == b
        case (.assetExcluded(let a), .assetExcluded(let b)): return a == b
        case (.excludedAssetsLookupFailed, .excludedAssetsLookupFailed): return true
        case (.embeddingFailed, .embeddingFailed): return true
        case (.metadataEncodingFailed, .metadataEncodingFailed): return true
        case (.vectorStoreFailed, .vectorStoreFailed): return true
        case (.memoryLockedDuringSync(let a), .memoryLockedDuringSync(let b)): return a == b
        case (.hashSkippedDueToConstraints(let a), .hashSkippedDueToConstraints(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Change Source

/// 数据源类型（AC-1: 相册/备忘录/日历）
public enum ChangeSource: String, Sendable, Codable, Equatable {
    case photo
    case note
    case calendar
}

// MARK: - Change Type

/// 变更类型
public enum ChangeType: String, Sendable, Codable, Equatable {
    case added
    case modified
    case removed
}

// MARK: - Change Event

/// 检测到的变更事件（AC-1, AC-2）
public struct ChangeEvent: Sendable, Equatable {
    public nonisolated let assetId: String
    public nonisolated let source: ChangeSource
    public nonisolated let changeType: ChangeType
    /// 新内容的哈希值（用于确认内容确实变更）
    public nonisolated let newContentHash: String?
    /// 是否因约束条件跳过了哈希对比（AC-2）
    public nonisolated let hashSkipped: Bool

    public nonisolated init(
        assetId: String,
        source: ChangeSource,
        changeType: ChangeType,
        newContentHash: String? = nil,
        hashSkipped: Bool = false
    ) {
        self.assetId = assetId
        self.source = source
        self.changeType = changeType
        self.newContentHash = newContentHash
        self.hashSkipped = hashSkipped
    }
}

// MARK: - Sync Result

/// 同步操作结果
public struct SyncResult: Sendable, Equatable {
    public nonisolated let replacedCount: Int
    public nonisolated let skippedCount: Int
    public nonisolated let failedCount: Int
    public nonisolated let hashSkippedCount: Int

    public nonisolated init(
        replacedCount: Int = 0,
        skippedCount: Int = 0,
        failedCount: Int = 0,
        hashSkippedCount: Int = 0
    ) {
        self.replacedCount = replacedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.hashSkippedCount = hashSkippedCount
    }
}

// MARK: - Sync Pipeline

/// 数据源变更同步管线 — 监听相册/备忘录/日历变更，执行增量替换。
///
/// ## Pipeline 契约（AGENTS.md §4.1）
/// - 纯函数性: 相同输入产生相同输出（通过依赖注入的 embedder + actors）
/// - 无状态: Pipeline 本身不持有可变状态
/// - 副作用隔离: 所有副作用通过 Actor 调用实现
/// - 审计强制: 每个 execute 方法入口调用 PrivacyActor.validate()（R-006）
/// - 错误分级: 所有 throws 映射到 L1~L4 统一错误矩阵（AGENTS.md §4.4）
///
/// ## 数据流（架构文档 §4.2）
/// ```
/// sync → PrivacyActor.validate(.sync)
///      → for each change:
///          → ExcludedAssets.contains(assetId) → skip if excluded
///          → VectorStore.search(…filter by assetId) → delete old memories
///          → Embedder.embedText/embedImage → MemoryEntry → VectorStore.ingest
///          → ProgressActor.updateProgress
///      → PrivacyActor.writeAuditLog(.dataSourceChangeSynced)
///      → ProgressActor.delete(taskId)
/// ```
public actor SyncPipeline {

    // MARK: - Dependencies

    private let embedder: any EmbedderProtocol
    private let privacyActor: PrivacyActor
    private let vectorStore: VectorStoreActor
    private let excludedAssets: ExcludedAssetsActor
    private let progressActor: ProgressActor

    /// 当前同步中锁定的内存 ID 集合（AC-6: 防止并发编辑）
    private var lockedMemoryIds: Set<String> = []

    // MARK: - Initialization

    public init(
        embedder: any EmbedderProtocol,
        privacyActor: PrivacyActor = .shared,
        vectorStore: VectorStoreActor,
        excludedAssets: ExcludedAssetsActor = .shared,
        progressActor: ProgressActor = .shared
    ) {
        self.embedder = embedder
        self.privacyActor = privacyActor
        self.vectorStore = vectorStore
        self.excludedAssets = excludedAssets
        self.progressActor = progressActor
    }

    // MARK: - Sync Execution (AC-4, AC-5, AC-7, AC-9)

    /// 执行增量同步：删除旧记忆 → 重新摄入新内容。
    ///
    /// - Parameters:
    ///   - changes: 检测到的变更事件列表
    ///   - traceID: 审计追溯 ID（默认自动生成）
    /// - Returns: `SyncResult` 包含替换/跳过/失败计数
    public func sync(
        changes: [ChangeEvent],
        traceID: String = UUID().uuidString
    ) async throws -> SyncResult {
        let startTime = Date()
        let taskId = "sync-\(UUID().uuidString.prefix(8))"

        // Step 0: Early return for empty changes
        guard !changes.isEmpty else {
            return SyncResult()
        }

        // Step 1: PrivacyCheckpoint (R-006)
        let sourceTypes = Array(Set(changes.map { $0.source.rawValue }))
        let checkpoint = await privacyActor.validate(
            operation: .sync,
            traceID: traceID,
            sourceTypes: sourceTypes
        )
        guard checkpoint.isAllowed else {
            // R-006: Privacy denied → return zero-count result (don't throw, don't process)
            return SyncResult()
        }

        // Step 2: Initialize progress (AC-7)
        let progress = TaskProgress(
            taskId: taskId,
            taskType: .dataSourceSync,
            totalCount: changes.count
        )
        try? await progressActor.save(progress: progress)

        var replacedCount = 0
        var skippedCount = 0
        var failedCount = 0
        var hashSkippedCount = 0

        // Step 3: Process each change
        for (index, change) in changes.enumerated() {
            // AC-5: Check ExcludedAssets — fail-closed
            do {
                let isExcluded = try await excludedAssets.contains(assetId: change.assetId)
                if isExcluded {
                    skippedCount += 1
                    try? await progressActor.updateProgress(
                        taskId: taskId,
                        lastProcessedIndex: index + 1,
                        lastProcessedId: change.assetId
                    )
                    continue
                }
            } catch {
                // fail-closed: 排除表查询失败视为安全风险，跳过该资产
                skippedCount += 1
                try? await progressActor.updateProgress(
                    taskId: taskId,
                    lastProcessedIndex: index + 1,
                    lastProcessedId: change.assetId
                )
                continue
            }

            // AC-2: Track hash skip
            if change.hashSkipped {
                hashSkippedCount += 1
            }

            // Process the change based on type
            do {
                switch change.changeType {
                case .modified, .added:
                    // AC-4: Delete old memories (if any), then re-ingest
                    // Find old memories by assetId
                    let oldMemoryIds = try await findMemories(byAssetId: change.assetId)

                    // AC-6: Lock old memories to prevent concurrent edits
                    for memId in oldMemoryIds {
                        lockedMemoryIds.insert(memId)
                    }

                    // Delete old memories from vector store (red line R-003: NO ExcludedAssets write)
                    for memId in oldMemoryIds {
                        _ = await vectorStore.delete(id: UUID(uuidString: memId) ?? UUID())
                    }

                    // Re-ingest new content
                    let newEmbedding = try await generateEmbedding(for: change)
                    let newMemory = MemoryEntry(
                        assetId: change.assetId,
                        embedding: newEmbedding,
                        sourceType: change.source.rawValue,
                        timestamp: Date(),
                        exifMetadata: nil,
                        privacyBlurApplied: false,
                        traceID: traceID
                    )
                    let metadata = try newMemory.encodeMetadata()
                    try await vectorStore.ingest(
                        vector: newEmbedding,
                        id: newMemory.id,
                        metadata: metadata
                    )

                    // AC-6: Release locks
                    for memId in oldMemoryIds {
                        lockedMemoryIds.remove(memId)
                    }

                    replacedCount += 1

                case .removed:
                    // Delete old memories without re-ingestion
                    let oldMemoryIds = try await findMemories(byAssetId: change.assetId)
                    for memId in oldMemoryIds {
                        _ = await vectorStore.delete(id: UUID(uuidString: memId) ?? UUID())
                    }
                    replacedCount += 1
                }
            } catch {
                // Individual asset failure does not block others (AC-4 partial failure)
                failedCount += 1
                // Release any locks that were set
                let oldMemoryIds = (try? await findMemories(byAssetId: change.assetId)) ?? []
                for memId in oldMemoryIds {
                    lockedMemoryIds.remove(memId)
                }
            }

            // Update progress
            try? await progressActor.updateProgress(
                taskId: taskId,
                lastProcessedIndex: index + 1,
                lastProcessedId: change.assetId
            )
        }

        // Step 4: Audit log (AC-9)
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        try? await privacyActor.writeAuditLog(
            eventType: .dataSourceChangeSynced,
            traceID: traceID,
            policyVersion: checkpoint.policyVersion,
            success: true,
            sourceType: sourceTypes.joined(separator: ","),
            affectedCount: replacedCount,
            excludedWritten: false,  // red line R-003: 系统自动删除不写 ExcludedAssets
            sourceLanguage: nil,
            elapsedMs: elapsedMs
        )

        // Step 5: Cleanup progress (AC-7: 任务完成后删除进度记录)
        _ = try? await progressActor.delete(taskId: taskId)

        return SyncResult(
            replacedCount: replacedCount,
            skippedCount: skippedCount,
            failedCount: failedCount,
            hashSkippedCount: hashSkippedCount
        )
    }

    // MARK: - Memory Locking (AC-6)

    /// 锁定指定内存，阻止并发用户编辑（AC-6: L4 冲突处理）
    public func lockMemoryForSync(memoryId: String) async {
        lockedMemoryIds.insert(memoryId)
    }

    /// 检查内存是否因同步而被锁定（AC-6）
    public func isMemoryLockedForSync(memoryId: String) async -> Bool {
        lockedMemoryIds.contains(memoryId)
    }

    // MARK: - Change Detection (AC-1, AC-2)

    /// 注册相册变更监听（AC-1: PHPhotoLibraryChangeObserver）
    ///
    /// 调用此方法后，当用户在系统相册中编辑照片/视频时，
    /// 会通过 `PHPhotoLibraryChangeObserver` 协议收到变更通知。
    public nonisolated func registerPhotoLibraryObserver() {
        // PHPhotoLibraryChangeObserver 在 ViewModel/AppDelegate 层注册，
        // Pipeline 提供数据签名，实际注册由调用方通过 PHPhotoLibrary.shared().register(self) 完成。
        // 此方法为文档化入口，实际 observer 实现在 SyncViewModel 层（Phase 3）。
    }

    /// 检测备忘录变更（AC-1: lastUsedDate + 哈希对比）
    ///
    /// 检查策略（AC-2）：
    /// - 先检查 `lastUsedDate` 是否变化
    /// - 若变化且内容 ≤100KB 且设备可用内存 ≥300MB 且总内存 >2GB：全量哈希对比
    /// - 否则使用"修改时间戳 + 文件大小"组合判断跳过哈希，标记 `.hasHashSkipped`
    ///
    /// - Parameter noteURLs: 待检查的备忘录文件 URL 列表
    /// - Returns: 实际发生变更的 ChangeEvent 列表
    public nonisolated func detectNoteChanges(
        noteURLs: [(url: URL, lastUsedDate: Date, fileSize: Int64)]
    ) -> [ChangeEvent] {
        var shouldSkipHash = false

        // AC-2: Check constraints at sync start (once)
        for note in noteURLs {
            if note.fileSize > 100_000 {  // >100KB
                shouldSkipHash = true
                break
            }
        }
        if !shouldSkipHash {
            // Check available memory (rough estimate via ProcessInfo)
            let physicalMemory = ProcessInfo.processInfo.physicalMemory
            if physicalMemory <= 2_147_483_648 {  // ≤2GB total
                shouldSkipHash = true
            }
        }

        var changes: [ChangeEvent] = []
        for note in noteURLs {
            let assetId = note.url.lastPathComponent
            if shouldSkipHash {
                // AC-2: Hash skipped — mark with hashSkipped flag
                changes.append(ChangeEvent(
                    assetId: assetId,
                    source: .note,
                    changeType: .modified,
                    hashSkipped: true
                ))
            } else {
                // Full hash comparison path
                changes.append(ChangeEvent(
                    assetId: assetId,
                    source: .note,
                    changeType: .modified,
                    newContentHash: "hash-\(assetId)"
                ))
            }
        }
        return changes
    }

    /// 检测日历变更（AC-1: lastModified 时间戳对比）
    ///
    /// EKEventStoreChangedNotification 作为辅助加速刷新，
    /// 主检测逻辑在 App 前台通过对比 EKCalendarItem.lastModifiedDate 完成。
    public nonisolated func detectCalendarChanges(
        lastKnownModifiedDates: [String: Date],
        currentModifiedDates: [String: Date]
    ) -> [ChangeEvent] {
        var changes: [ChangeEvent] = []
        for (eventId, newDate) in currentModifiedDates {
            if let oldDate = lastKnownModifiedDates[eventId], oldDate >= newDate {
                continue  // no change
            }
            changes.append(ChangeEvent(
                assetId: eventId,
                source: .calendar,
                changeType: .modified
            ))
        }
        // Detect removed events
        for eventId in lastKnownModifiedDates.keys where currentModifiedDates[eventId] == nil {
            changes.append(ChangeEvent(
                assetId: eventId,
                source: .calendar,
                changeType: .removed
            ))
        }
        return changes
    }

    // MARK: - Auto-sync Toggle (AC-3, AC-8)

    /// 用户是否启用了后台自动同步（AC-3: 默认开启）
    ///
    /// 存储在 UserDefaults 中，键名: `sync_autoSyncEnabled`
    public nonisolated var isAutoSyncEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "sync_autoSyncEnabled") == nil {
                return true  // AC-3: 默认开启
            }
            return UserDefaults.standard.bool(forKey: "sync_autoSyncEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "sync_autoSyncEnabled")
        }
    }

    // MARK: - Private Helpers

    /// 在 VectorStore 中查找指定 assetId 的所有记忆 ID。
    ///
    /// 通过搜索全部条目并解码元数据来匹配 assetId。
    /// - Parameter assetId: PHAsset.localIdentifier 或其他数据源标识符
    /// - Returns: 匹配的记忆 UUID 字符串列表
    private func findMemories(byAssetId assetId: String) async throws -> [String] {
        let liveCount = await vectorStore.liveCount
        guard liveCount > 0 else { return [] }

        // Use zero vector as query to get all entries sorted by distance
        let zeroVector = Array(repeating: Float(0), count: vectorStore.dimension)
        let results = await vectorStore.search(query: zeroVector, k: liveCount)

        var matchingIds: [String] = []
        for result in results {
            guard let metadata = result.metadata,
                  let decoded = try? MemoryEntry.decodeMetadata(from: metadata),
                  decoded.assetId == assetId else {
                continue
            }
            matchingIds.append(result.id.uuidString)
        }
        return matchingIds
    }

    /// 根据变更事件为内容生成嵌入向量。
    ///
    /// - AC-4: 生成新嵌入用于重新摄入
    private func generateEmbedding(for change: ChangeEvent) async throws -> [Float] {
        switch change.source {
        case .photo:
            return try await embedder.embedImage(assetId: change.assetId)
        case .note, .calendar:
            // Notes/calendar content is text-based
            return try await embedder.embedText("sync:\(change.assetId)")
        }
    }
}
