// ==========================================
// 文件: SharedImportQueueActor.swift
// 对应规格: docs/decisions/ADR-008-source-import-boundaries.md §决策-3 (App Group 信封队列),
//            §决策-4 (去重), §决策-7 (最小数据边界)
//            docs/01-spec/用户故事与验收标准规格书.md → US-SRC-001 (share-only), US-SRC-003
// 任务: 3F.2 - PhotoKit、Share Extension 与真实来源
// AC 覆盖: ADR-008 §决策-3 (共享导入 App 重启后恰好处理一次 + 原子入队 + 重复投递去重),
//          §决策-7 (App Group 仅承载信封最小字段, 不存原文件全文)
// 架构约束: AGENTS.md §4.2 (Actor 隔离 — 可变状态封装, 串行执行), R-007 (禁止 unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
//       本文件同时编译进 Echo 与 EchoShareExtension target，不得依赖 App target 专属符号
//       队列为文件存储（每信封一个文件），App 与 Extension 通过 App Group 容器共享
// 生成时间: 2026-08-05
// ==========================================

import Foundation

// MARK: - App Group Constants

/// App Group 标识与共享目录（ADR-008 §决策-3：App Group 信封）
public enum AppGroupConstants {
    /// App Group ID — Echo 与 EchoShareExtension 共享
    public nonisolated static let appGroupID = "group.com.echo.Echo"
    /// App Group 容器内的分享队列子目录
    public nonisolated static let queueDirectoryName = "SharedImportQueue"
}

// MARK: - Shared Import Queue Actor

/// App Group 分享队列 Actor — 跨 App/Extension 原子投递，App 重启后恰好处理一次。
///
/// ## 设计（ADR-008 §决策-3）
/// - 每封一个新文件（`<dedupeKey>.json`），通过 App Group 容器在 App 与 Extension 间共享
/// - 入队原子性：写入临时文件 → 原子 rename 到 pending 文件（同卷 move 原子）
/// - 去重：pending 文件已存在（按 `dedupeKey`）→ 拒绝重复投递
/// - 恰好一次：`beginProcessing` 将 pending 原子 rename 为 processing；
///   处理成功后 `finishProcessing` 删除；失败 `rollbackProcessing` 移回 pending；
///   App 崩溃残留的 processing 文件由 `recoverInterrupted` 在下次启动时移回 pending 重试
///
/// ## 最小数据边界（ADR-008 §决策-7）
/// - 队列文件只存信封（最小字段），不存原文件全文
public actor SharedImportQueueActor {

    // MARK: - Singleton

    public static let shared = SharedImportQueueActor()

    // MARK: - Properties

    private let directory: URL
    private let fileManager: FileManager

    // MARK: - Initialization

    /// 默认初始化：使用 App Group 容器队列目录（生产路径）
    public init() {
        self.init(directory: Self.defaultContainerQueueDirectory)
    }

    /// 指定目录初始化（测试注入临时目录；App/Extension 生产路径为 App Group 容器）
    internal init(directory: URL) {
        self.directory = directory
        self.fileManager = .default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// App Group 容器队列目录；App Group 不可用时回退到 Application Support/Echo
    /// （回退仅保证扩展不可用时的 App 内联降级，生产应始终具备 App Group entitlement）
    private nonisolated static var defaultContainerQueueDirectory: URL {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroupConstants.appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Echo", isDirectory: true)
        return container.appendingPathComponent(AppGroupConstants.queueDirectoryName, isDirectory: true)
    }

    // MARK: - File States

    private enum QueueState: String {
        /// 待处理：`<key>.json`
        case pending = "json"
        /// 处理中：`<key>.processing`（原子 rename 自 pending）
        case processing = "processing"
    }

    private func url(for key: String, state: QueueState) -> URL {
        directory.appendingPathComponent("\(key).\(state.rawValue)")
    }

    // MARK: - Enqueue (ADR-008 §决策-3 原子入队 + 去重)

    /// 原子入队一封分享信封。
    ///
    /// - Returns: `true` 入队成功；`false` 表示相同 `dedupeKey` 已存在（重复投递被去重）
    @discardableResult
    public func enqueue(_ envelope: SharedImportEnvelope) throws -> Bool {
        let pendingURL = url(for: envelope.dedupeKey, state: .pending)
        guard !fileManager.fileExists(atPath: pendingURL.path) else { return false }

        let data = try envelope.encoded()
        let tmpURL = directory.appendingPathComponent("\(envelope.dedupeKey).tmp")
        try data.write(to: tmpURL, options: .atomic)
        do {
            // 同卷 move 原子：App/Extension 并发投递不会产生半写文件
            try fileManager.moveItem(at: tmpURL, to: pendingURL)
        } catch {
            try? fileManager.removeItem(at: tmpURL)
            throw error
        }
        return true
    }

    // MARK: - Read

    /// 待处理信封（按 createdAt 升序，保持投递顺序）。
    public func pendingEnvelopes() throws -> [SharedImportEnvelope] {
        try envelopes(state: .pending).sorted { $0.createdAt < $1.createdAt }
    }

    /// 待处理 dedupeKey 列表（审计/诊断用）。
    public func pendingKeys() throws -> [String] {
        try files(withSuffix: QueueState.pending.rawValue)
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// 待处理信封数量（非抛出）。
    public func count() -> Int {
        (try? pendingEnvelopes().count) ?? 0
    }

    // MARK: - Exactly-Once Processing

    /// 开始处理一封：将 pending 原子移为 processing，返回信封。
    ///
    /// - Returns: 信封；该 dedupeKey 无 pending 记录时返回 `nil`
    public func beginProcessing(for dedupeKey: String) throws -> SharedImportEnvelope? {
        let pending = url(for: dedupeKey, state: .pending)
        guard fileManager.fileExists(atPath: pending.path) else { return nil }
        let processing = url(for: dedupeKey, state: .processing)
        try fileManager.moveItem(at: pending, to: processing)
        let data = try Data(contentsOf: processing)
        return try SharedImportEnvelope.decode(data)
    }

    /// 处理成功：删除 processing 记录（恰好一次完成）。
    public func finishProcessing(for dedupeKey: String) throws {
        let processing = url(for: dedupeKey, state: .processing)
        if fileManager.fileExists(atPath: processing.path) {
            try fileManager.removeItem(at: processing)
        }
    }

    /// 处理失败：将 processing 移回 pending（下次启动/重试仍可处理）。
    public func rollbackProcessing(for dedupeKey: String) throws {
        let processing = url(for: dedupeKey, state: .processing)
        let pending = url(for: dedupeKey, state: .pending)
        guard fileManager.fileExists(atPath: processing.path) else { return }
        if fileManager.fileExists(atPath: pending.path) {
            // 同名 pending 已存在（异常状态）→ 丢弃 stale processing，避免歧义
            try fileManager.removeItem(at: processing)
        } else {
            try fileManager.moveItem(at: processing, to: pending)
        }
    }

    /// 恢复被中断的处理记录（App 崩溃残留的 `.processing` 移回 pending 重试）。
    ///
    /// - Returns: 恢复数量
    @discardableResult
    public func recoverInterrupted() throws -> Int {
        let processingFiles = try files(withSuffix: QueueState.processing.rawValue)
        var recovered = 0
        for file in processingFiles {
            let key = file.deletingPathExtension().lastPathComponent
            let pending = url(for: key, state: .pending)
            if fileManager.fileExists(atPath: pending.path) {
                try fileManager.removeItem(at: file)
            } else {
                try fileManager.moveItem(at: file, to: pending)
            }
            recovered += 1
        }
        return recovered
    }

    // MARK: - Private Helpers

    private func envelopes(state: QueueState) throws -> [SharedImportEnvelope] {
        let files = try files(withSuffix: state.rawValue)
        var result: [SharedImportEnvelope] = []
        for file in files {
            if let data = try? Data(contentsOf: file),
               let env = try? SharedImportEnvelope.decode(data) {
                result.append(env)
            }
        }
        return result
    }

    private func files(withSuffix suffix: String) throws -> [URL] {
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return urls.filter { $0.pathExtension == suffix }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
