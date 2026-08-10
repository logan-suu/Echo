// ==========================================
// 文件: TaskQueueActor.swift
// 对应规格: docs/decisions/ADR-011-task-progress-boundary.md 决策-1 (串行契约)
//            docs/01-spec/用户故事与验收标准规格书.md → US-SYS-001 AC-3/4/6 (暂停/取消/断点续传)
//            AGENTS.md §4.3 (TaskQueue 契约), §4.5 (断点续传契约)
// 任务: 3F.5 - Production ingestion
// AC 覆盖: 串行执行 (索引构建与数据同步互斥), 入队写入任务, 暂停 (挂起不释放资源),
//          取消 (保存进度), 完成/最终失败后删除 TaskProgress, 取消保留进度供下次询问
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §4.3 (TaskQueue 契约), R-007 (禁止 unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-10
// ==========================================

import Foundation

/// 长任务串行队列 Actor（ADR-011 决策-1，AGENTS.md §4.3）。
///
/// ## 契约
/// - **串行执行**：同一时刻仅一个任务在运行，索引构建与数据同步互斥，避免资源争抢
/// - **进度持久化**：入队时经 `ProgressActor.save` 写入 `TaskProgress`；任务通过
///   `TaskContext.report` 原子更新进度
/// - **完成/最终失败后清理**：任务成功或抛出非取消错误后立即删除 `TaskProgress` 记录
///   （US-SYS-001 AC-4），避免表无限增长
/// - **取消保留进度**：取消或暂停不删除进度记录，重启后 UI 询问「继续/重新开始」（§4.5）
/// - **暂停**：任务挂起（不释放资源，可随时恢复）；运行中的任务经 `PauseToken` 协作式暂停
///
/// ## 协作式取消/暂停
/// - 任务体通过 `Task.isCancelled` 感知取消；队列对激活任务调用 `Task.cancel()`
/// - 任务体通过 `TaskContext.checkPaused()` 在检查点感知暂停并抛出 `.paused`
public actor TaskQueueActor {

    // MARK: - Singleton

    public static let shared = TaskQueueActor()

    // MARK: - Properties

    private let progressActor: ProgressActor
    private var queue: [QueuedJob] = []
    private var activeTask: Task<Void, Never>?
    private var activeJobId: String?
    private var activePauseToken: PauseToken?
    private var pausedJobIds: Set<String> = []
    private var cancelledJobIds: Set<String> = []
    private var completions: [String: CheckedContinuation<Void, Error>] = [:]

    // MARK: - Initialization

    public init(progressActor: ProgressActor = .shared) {
        self.progressActor = progressActor
    }

    // MARK: - Public Task Model

    /// 队列任务（Sendable 值类型，跨 Actor 安全）。
    public struct QueuedJob: Sendable {
        public nonisolated let taskId: String
        public nonisolated let taskType: TaskType
        public nonisolated let totalCount: Int
        public nonisolated let resumeData: Data?
        public nonisolated let body: @Sendable (TaskContext) async throws -> Void

        public nonisolated init(
            taskId: String = UUID().uuidString,
            taskType: TaskType,
            totalCount: Int,
            resumeData: Data? = nil,
            body: @escaping @Sendable (TaskContext) async throws -> Void
        ) {
            self.taskId = taskId
            self.taskType = taskType
            self.totalCount = totalCount
            self.resumeData = resumeData
            self.body = body
        }
    }

    /// 任务上下文 — 提供进度上报与暂停/取消检查（跨 Actor 值类型）。
    public struct TaskContext: Sendable {
        nonisolated let taskId: String
        nonisolated let progressActor: ProgressActor
        nonisolated let pauseToken: PauseToken

        /// 原子更新已处理进度（US-SYS-001 AC-4 事务写入）。
        public func report(processedIndex: Int, lastProcessedId: String?) async throws {
            try await progressActor.updateProgress(
                taskId: taskId,
                lastProcessedIndex: processedIndex,
                lastProcessedId: lastProcessedId
            )
        }

        /// 检查暂停信号；暂停时抛出 `.paused`（任务在检查点协作式挂起）。
        public func checkPaused() async throws {
            if await pauseToken.isPaused {
                throw TaskQueueError.paused(taskId: taskId)
            }
        }

        /// 检查取消信号。
        public func checkCancelled() throws {
            if Task.isCancelled {
                throw CancellationError()
            }
        }
    }

    // MARK: - Public API

    /// 入队一个任务并立即持久化初始进度；若队列空闲则开始串行执行。
    ///
    /// - Throws: `TaskQueueError.taskAlreadyQueued` 若同 taskId 已在队列/运行中
    public func enqueue(_ job: QueuedJob) async throws {
        guard !queue.contains(where: { $0.taskId == job.taskId }), activeJobId != job.taskId else {
            throw TaskQueueError.taskAlreadyQueued(taskId: job.taskId)
        }
        let progress = TaskProgress(
            taskId: job.taskId,
            taskType: job.taskType,
            totalCount: job.totalCount,
            resumeData: job.resumeData
        )
        try await progressActor.save(progress: progress)
        queue.append(job)
        if activeTask == nil {
            await startNext()
        }
    }

    /// 取消指定任务：运行中 → 终止底层 Task（进度保留）；排队中 → 移除（进度清理）。
    public func cancel(taskId: String) async {
        if activeJobId == taskId {
            cancelledJobIds.insert(taskId)
            activeTask?.cancel()
        } else if queue.contains(where: { $0.taskId == taskId }) {
            cancelledJobIds.insert(taskId)
        }
    }

    /// 暂停指定任务：运行中 → 经 PauseToken 协作式挂起；排队中 → 标记暂停（不启动）。
    public func pause(taskId: String) async {
        pausedJobIds.insert(taskId)
        if activeJobId == taskId {
            await activePauseToken?.setPaused(true)
        }
    }

    /// 恢复指定任务（解除暂停）。
    public func resume(taskId: String) async {
        pausedJobIds.remove(taskId)
        if activeJobId == taskId {
            await activePauseToken?.setPaused(false)
        } else if activeTask == nil {
            await startNext()
        }
    }

    /// 当前是否有任务在运行。
    public var isRunning: Bool {
        get async { activeTask != nil }
    }

    /// 当前运行任务 ID（nil 表示空闲）。
    public func activeTaskID() async -> String? {
        activeJobId
    }

    /// 队列中待处理任务数（不含运行中）。
    public func pendingCount() async -> Int {
        queue.count
    }

    /// 是否暂停了指定任务。
    public func isPaused(taskId: String) async -> Bool {
        pausedJobIds.contains(taskId)
    }

    /// 入队并等待任务执行完毕（生产管线接入用）。
    ///
    /// 与 `enqueue` 相同的串行/进度语义，但阻塞直到任务完成或抛出其终止错误。
    /// - Throws: 任务体抛出的错误，或 `TaskQueueError`（取消/暂停）
    public func enqueueAndWait(_ job: QueuedJob) async throws {
        try await withCheckedThrowingContinuation { continuation in
            completions[job.taskId] = continuation
            Task {
                do {
                    try await self.enqueue(job)
                } catch {
                    // 入队本身失败（重复 ID 等）→ 立即恢复调用方
                    if let completion = completions.removeValue(forKey: job.taskId) {
                        completion.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Internal Execution

    /// 串行执行：持续取出队首未被取消/暂停的任务运行，直到队列空。
    private func startNext() async {
        while activeTask == nil, !queue.isEmpty {
            let job = queue.removeFirst()

            if cancelledJobIds.contains(job.taskId) {
                cancelledJobIds.remove(job.taskId)
                // 排队中被取消 → 清理进度（从未开始）
                try? await progressActor.delete(taskId: job.taskId)
                continue
            }
            if pausedJobIds.contains(job.taskId) {
                // 暂停任务留在队首等待恢复（挂起不释放资源）
                queue.insert(job, at: 0)
                break
            }

            activeJobId = job.taskId
            let token = PauseToken()
            activePauseToken = token
            activeTask = Task {
                let outcome = await Self.run(
                    job: job,
                    token: token,
                    progressActor: progressActor
                )
                await self.finish(job.taskId, outcome: outcome)
            }
            return
        }
    }

    /// 执行单个任务并依据结果处理进度（完成/失败清理；取消/暂停保留）。
    private static func run(
        job: QueuedJob,
        token: PauseToken,
        progressActor: ProgressActor
    ) async -> TaskQueueOutcome {
        let context = TaskContext(
            taskId: job.taskId,
            progressActor: progressActor,
            pauseToken: token
        )
        do {
            try await job.body(context)
            try? await progressActor.delete(taskId: job.taskId)
            return .completed
        } catch is CancellationError {
            return .cancelled
        } catch TaskQueueError.paused {
            return .paused
        } catch {
            try? await progressActor.delete(taskId: job.taskId)
            return .failed(error)
        }
    }

    /// 任务执行结果分类（供收尾决定 continuation 恢复语义）。
    private enum TaskQueueOutcome {
        case completed
        case cancelled
        case paused
        case failed(Error)
    }

    private func finish(_ taskId: String, outcome: TaskQueueOutcome) async {
        activeJobId = nil
        activeTask = nil
        activePauseToken = nil
        pausedJobIds.remove(taskId)
        cancelledJobIds.remove(taskId)
        if let completion = completions.removeValue(forKey: taskId) {
            switch outcome {
            case .completed:
                completion.resume()
            case .cancelled:
                completion.resume(throwing: TaskQueueError.cancelled(taskId: taskId))
            case .paused:
                completion.resume(throwing: TaskQueueError.paused(taskId: taskId))
            case .failed(let error):
                completion.resume(throwing: error)
            }
        }
        await startNext()
    }
}

// MARK: - Pause Token

/// 协作式暂停信号（actor，跨任务边界传递）。
public actor PauseToken {
    public private(set) var isPaused = false
    public func setPaused(_ paused: Bool) {
        isPaused = paused
    }
}

// MARK: - Task Queue Error

/// TaskQueueActor 统一错误类型
public enum TaskQueueError: Error, LocalizedError, Sendable {
    /// 任务已存在（重复入队被拒绝）
    case taskAlreadyQueued(taskId: String)
    /// 任务被暂停（协作式挂起信号）
    case paused(taskId: String)
    /// 任务被取消
    case cancelled(taskId: String)

    public var errorDescription: String? {
        switch self {
        case .taskAlreadyQueued(let id):
            return "Task already queued: \(id)"
        case .paused(let id):
            return "Task paused: \(id)"
        case .cancelled(let id):
            return "Task cancelled: \(id)"
        }
    }
}
