// ==========================================
// 文件: ResumeProgressViewModel.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SYS-001 AC-3 (取消后询问), AC-4 (断点续传),
//            docs/02-architecture/架构设计文档.md §6.2 (恢复流程 — 检测未完成进度 → 弹窗询问继续/重新开始),
//            docs/ui/echo-memory-canvas-style.md §3.3 (Task surface — Alert/confirmationDialog),
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.7 - 断点续传集成到长任务
// AC 覆盖: US-SYS-001 AC-3 🔶 (取消后弹窗询问继续/重新开始 — UI 切片, Core 检测延后 Phase 3.9),
//          AC-4 🔶 (继续保留进度/重新开始清除进度 意图映射 — UI 切片, Core 读写延后 Phase 3.9),
//          🔮 ProgressActor/TaskQueueActor 真实读写 + 审计 (Phase 3.9 Core 集成)
//          (2026-08-02 PR review W-2: checkDelayNanoseconds 注入; W-3: 文案统一英文; W-4: progressActor 未接线占位 DEF-42-001)
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum), §8.2 (状态流转),
//           docs/ui/architecture.md §6~7 (适配器契约), §2.5 (Adapter 不保存第二份领域真相 — 仅转换展示字段)
// 生成时间: 2026-08-02
// ==========================================

import SwiftUI
import Foundation

// MARK: - ResumeProgressViewModel

/// 断点续传恢复提示 ViewModel — 当长任务重启且存在未完成进度时，提示用户继续或重新开始。
///
/// ## Surface Family: Task
/// - 布局: Alert / confirmationDialog（echo-memory-canvas §3.3, §7.2）
/// - Masonry: 禁止 (Task surface)
///
/// ## 职责 (docs/ui/architecture.md §7.1)
/// - 线程隔离: ProgressActor (actor) → @MainActor 状态
/// - 状态映射: TaskProgress → 恢复提示展示状态
/// - 错误映射: L2 → error state
/// - Intent 转发: 继续/重新开始 → ProgressActor / TaskQueueActor (Phase 3.9)
/// - 生命周期: Task 管理
///
/// ## 状态流转 (AGENTS.md §8.2)
/// ```
/// idle → checking → prompt(TaskProgress) → resumed
///                → none
///                → error(L2) → checking (retry)
/// ```
@MainActor
@Observable
final class ResumeProgressViewModel {
    // MARK: - State Enum

    /// ViewModel 统一状态枚举 (AGENTS.md §8.1)
    enum ViewState: Equatable, Sendable {
        /// 初始状态 — 未检查
        case idle
        /// 检查未完成进度中
        case checking
        /// 存在未完成进度 → 展示恢复提示弹窗
        case prompt(TaskProgress)
        /// 无未完成进度 → 直接从头开始
        case none
        /// 用户选择"继续" → 从保存的进度恢复
        case resumed
        /// 用户选择"重新开始" → 清除进度后从头开始
        case restarted
        /// 错误状态 — L2 可恢复
        case error(ErrorLevel)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.checking, .checking), (.none, .none),
                 (.resumed, .resumed), (.restarted, .restarted):
                return true

            case (.prompt(let l), .prompt(let r)):
                return l.taskId == r.taskId
                    && l.taskType == r.taskType
                    && l.lastProcessedIndex == r.lastProcessedIndex
                    && l.totalCount == r.totalCount

            case (.error(let l), .error(let r)):
                return l == r

            default:
                return false
            }
        }
    }

    /// 错误等级 — 对应 AGENTS.md §4.4
    enum ErrorLevel: Equatable, Sendable {
        /// L2 可恢复: Toast + 重试按钮
        case l2Recoverable(message: String)
    }

    deinit {}

    // MARK: - Published State

    /// 统一视图状态
    private(set) var viewState: ViewState = .idle
    /// 恢复提示弹窗是否已展示
    private(set) var isPromptPresented: Bool = false
    /// 最后一次展示的恢复目标（用于断言继续/重新开始意图）
    private(set) var lastResumeTarget: TaskProgress?

    // MARK: - Dependencies (Immutable Actor References)

    /// ProgressActor 引用 — 不可变 actor 引用 (docs/ui/architecture.md §6.4)
    /// 可选注入: Phase 3.9 完整集成后通过 DI 容器注入
    /// (2026-08-02 W-4: 当前未接线占位, 追踪 DEF-42-001)
    private let progressActor: ProgressActor?

    /// 模拟检查延迟 — 测试可注入 0 以 await 真实异步转换 (2026-08-02 W-2)
    private let checkDelayNanoseconds: UInt64

    /// 当前活跃的检查 Task
    private var checkTask: Task<Void, Never>?

    /// 当前检查的任务类型（用于重试）
    private var currentTaskType: TaskType?

    /// UI 切片模式 fixture 注入源
    private var stubFixture: ResumeProgressFixture?

    /// 模拟加载失败标记（fixture 驱动 error 态）
    private var simulateError = false

    // MARK: - Initialization

    /// 初始化 ResumeProgressViewModel。
    ///
    /// - Parameters:
    ///   - progressActor: ProgressActor 实例（可选注入）。
    ///     Phase 3.9 完整集成后通过 DI 容器注入。
    ///   - checkDelayNanoseconds: 模拟检查延迟。测试可注入 0 以同步等待异步转换。
    init(progressActor: ProgressActor? = nil, checkDelayNanoseconds: UInt64 = 200_000_000) {
        self.progressActor = progressActor
        self.checkDelayNanoseconds = checkDelayNanoseconds
    }

    // MARK: - Actions

    /// 检查指定任务类型是否存在未完成进度（US-SYS-001 AC-3: 取消后再次启动相同任务时询问）。
    ///
    /// - Parameter taskType: 即将启动的任务类型
    func checkForPendingProgress(taskType: TaskType) {
        // 防止重复检查
        guard viewState != .checking else { return }

        // 取消已有 Task
        checkTask?.cancel()

        currentTaskType = taskType

        // Set checking synchronously (AGENTS.md §8.1: first line of action)
        viewState = .checking
        isPromptPresented = false

        checkTask = Task { [weak self] in
            guard let self else { return }

            do {
                // 🔮 Phase 3.9+: 通过 ProgressActor.hasPendingProgress(taskType:) / load(taskId:)
                // 读取 SQLite TaskProgress 记录 (架构文档 §6.2)。当前 UI 切片在 Preview/测试中
                // 通过 loadFixture 注入确定性数据。
                if self.simulateError || self.stubFixture?.loadError == true {
                    throw ResumeProgressError.checkFailed
                }

                // 模拟检查延迟 — 可注入 (W-2), 测试注入 0 使异步转换可 await
                try await Task.sleep(nanoseconds: checkDelayNanoseconds)

                guard !Task.isCancelled else {
                    self.viewState = .idle
                    return
                }

                if let progress = self.stubFixture?.pendingProgress {
                    self.presentPrompt(progress)
                } else {
                    self.viewState = .none
                }
            } catch is CancellationError {
                self.viewState = .idle
            } catch {
                guard !Task.isCancelled else {
                    self.viewState = .idle
                    return
                }
                self.viewState = .error(.l2Recoverable(
                    message: "Unable to check saved progress. Please try again."
                ))
            }
        }
    }

    /// 用户选择"继续" — 从保存的进度恢复（US-SYS-001 AC-3）。
    ///
    /// 🔮 Phase 3.9: 转发 TaskQueueActor.resume(taskId:)（Core 串行队列）。
    /// 当前为 UI 切片状态更新（fixture 切片模式）。
    func continueTask() {
        guard case .prompt(let progress) = viewState else { return }
        lastResumeTarget = progress
        isPromptPresented = false
        viewState = .resumed
    }

    /// 用户选择"重新开始" — 清除进度后从头开始（US-SYS-001 AC-4）。
    ///
    /// 🔮 Phase 3.9: 调用 ProgressActor.delete(taskId:) + 启动新任务（清除 stale 记录）。
    /// 当前为 UI 切片状态更新（fixture 切片模式）。
    func restartTask() {
        guard case .prompt(let progress) = viewState else { return }
        lastResumeTarget = progress
        isPromptPresented = false
        viewState = .restarted
    }

    /// 关闭恢复提示弹窗（不改变任务状态）。
    func dismissPrompt() {
        isPromptPresented = false
        if case .prompt = viewState {
            viewState = .idle
        }
    }

    /// 重试检查 (L2 恢复路径)。
    ///
    /// fixture 模式下错误为一次性瞬态（simulateCheckError 仅注入 error 展示态），
    /// 重试清除该标记使检查流程恢复正常。
    func retry() {
        guard let currentTaskType else { return }
        simulateError = false
        checkForPendingProgress(taskType: currentTaskType)
    }

    /// 重置到初始状态。
    func reset() {
        checkTask?.cancel()
        checkTask = nil
        viewState = .idle
        isPromptPresented = false
        currentTaskType = nil
        stubFixture = nil
        simulateError = false
    }

    // MARK: - Presentation

    /// 展示恢复提示弹窗。
    ///
    /// 非 private：Preview / 单元测试通过 fixture 钩子注入已发现的进度以驱动 prompt 态
    /// （等价于检查完成路径，与 ``BackgroundTaskViewModel.loadPreloadedTasks`` 同模式）。
    func presentPrompt(_ progress: TaskProgress) {
        viewState = .prompt(progress)
        isPromptPresented = true
    }

    // MARK: - Fixture Injection

    /// 注入确定性 fixture（Preview / 测试 / XCUITest / Live Sim Review）。
    ///
    /// - Parameter fixtureID: resume-progress-pending | resume-progress-none | resume-progress-error
    func loadFixture(_ fixtureID: String) {
        stubFixture = ResumeProgressFixtureLoader.load(fixtureID)
        simulateError = false
    }

    /// 注入加载错误状态（Preview / 测试 fixture 驱动 error 态）。
    func simulateCheckError(_ message: String = "Unable to check saved progress") {
        simulateError = true
        viewState = .error(.l2Recoverable(message: message))
    }
}

// MARK: - Errors

/// 断点续传进度检查错误
enum ResumeProgressError: Error {
    /// 检查失败
    case checkFailed

    var localizedDescription: String {
        "Unable to check saved progress"
    }
}
