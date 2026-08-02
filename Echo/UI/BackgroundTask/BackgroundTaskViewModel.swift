// ==========================================
// 文件: BackgroundTaskViewModel.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SYS-001 (实时后台任务状态面板),
//            docs/ui/echo-memory-canvas-style.md §13 (后台任务面板 — Task surface family),
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.5 - 实时后台任务面板
// AC 覆盖: US-SYS-001 AC-1 ✅ (活跃任务列表展示), AC-2 ✅ (进度百分比/计数),
//          AC-3 ✅ (暂停/取消交互, 🔮 Core TaskQueueActor 接入), AC-4 🔮 (SQLite TaskProgress 断点续传, Phase 3.9),
//          AC-5 ✅ (无活跃任务自动隐藏), AC-6 🔮 (串行队列, Core 侧), AC-7 🔮 (审计, Core 侧)
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum: idle/loading/completed/error/cancelled),
//           §8.2 (状态流转), §4.2 (仅持有不可变引用), docs/ui/architecture.md §6~7 (适配器契约),
//           §2.5 (Adapter 不保存第二份领域真相 — 仅转换展示字段)
// 生成时间: 2026-08-02
// ==========================================

import SwiftUI
import Foundation

// MARK: - Task Status

/// 任务运行时状态 — UI 展示状态（US-SYS-001 AC-3）。
enum BackgroundTaskStatus: Equatable, Sendable {
    /// 运行中
    case running
    /// 已暂停（挂起状态，资源未释放，可恢复）
    case paused
    /// 已取消（完全终止，进度已记录）
    case cancelled
}

// MARK: - Background Task UI Model

/// UI 层后台任务展示模型 — 从 Core ``TaskProgress`` 映射的薄适配器。
///
/// 适配器职责 (docs/ui/architecture.md §7.1):
/// - 状态映射: Core 值类型 → UI State
/// - 不保存第二份领域真相 — 仅按需转换展示字段，不复制断点续传业务规则
struct BackgroundTaskModel: Identifiable, Sendable, Equatable {
    /// 任务唯一标识（映射自 TaskProgress.taskId）
    let taskId: String
    /// 任务类型 (fullIndex / dataSourceSync / modelLoad)
    let taskType: TaskType
    /// 已处理数量（映射自 lastProcessedIndex）
    let processedCount: Int
    /// 总量（映射自 totalCount）
    let totalCount: Int
    /// 运行时状态
    var status: BackgroundTaskStatus

    /// Identifiable 一致标识
    var id: String { taskId }

    /// 从 Core ``TaskProgress`` 映射。
    init(from progress: TaskProgress) {
        self.taskId = progress.taskId
        self.taskType = progress.taskType
        self.processedCount = progress.lastProcessedIndex
        self.totalCount = progress.totalCount
        self.status = .running
    }

    /// 任务类型展示名称 (US-SYS-001 AC-1: 如 "正在同步新照片" / "正在构建向量索引")
    var displayName: String {
        switch taskType {
        case .dataSourceSync: return "Syncing photos"
        case .fullIndex:      return "Building vector index"
        case .modelLoad:      return "Loading AI model"
        }
    }

    /// 对应的 SF Symbol 图标名 (echo-memory-canvas §13.2)
    var systemImage: String {
        switch taskType {
        case .dataSourceSync: return "arrow.triangle.2.circlepath"
        case .fullIndex:      return "cube.box.fill"
        case .modelLoad:      return "cpu"
        }
    }

    /// 确定性进度 0...1（totalCount == 0 时返回 0，避免除零）
    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return min(Double(processedCount) / Double(totalCount), 1)
    }

    /// 进度百分比文本（US-SYS-001 AC-2）
    var progressPercentText: String {
        "\(Int(progress * 100))%"
    }

    /// 进度计数文本 "processed/total"（US-SYS-001 AC-1: 如 "32/128"）
    var progressCountText: String {
        "\(processedCount)/\(totalCount)"
    }

    /// 状态标签 (US-SYS-001 AC-3)
    var statusLabel: String {
        switch status {
        case .running:  return "Running"
        case .paused:   return "Paused"
        case .cancelled: return "Cancelled"
        }
    }

    /// VoiceOver 标签 (echo-memory-canvas §13.2, §2.5)
    var accessibilityLabel: String {
        "\(displayName), \(processedCount) of \(totalCount) processed, \(statusLabel)"
    }
}

// MARK: - BackgroundTaskViewModel

/// 后台任务面板 ViewModel — 任务状态管理 + 暂停/取消交互。
///
/// ## Surface Family: Task
/// - 布局: 底部 Sheet (.medium detent, 可拖拽至 .large) + List (echo-memory-canvas §13.1)
/// - 样式: echo-memory-canvas + apple-native 基础
/// - Masonry: 禁止 (Task surface)
///
/// ## 职责 (docs/ui/architecture.md §7.1)
/// - 线程隔离: ProgressActor (actor) → @MainActor 状态
/// - 状态映射: TaskProgress → BackgroundTaskModel
/// - 错误映射: L2 → error state
/// - Intent 转发: 暂停/取消 → ProgressActor / TaskQueueActor (Phase 3.9)
/// - 生命周期: Task 管理，面板消失时 cancel
///
/// ## 状态流转 (AGENTS.md §8.2)
/// ```
/// idle → loading → completed
///                → error(L2)
///                → cancelled
/// ```
@MainActor
@Observable
final class BackgroundTaskViewModel {
    // MARK: - State Enum

    /// ViewModel 统一状态枚举 (AGENTS.md §8.1)
    enum ViewState: Equatable, Sendable {
        /// 初始状态 — 面板尚未打开
        case idle
        /// 加载中 — ProgressView
        case loading
        /// 加载完成 — 展示任务列表或空态
        case completed
        /// 错误状态 — L2 可恢复
        case error(ErrorLevel)
        /// 已取消
        case cancelled
    }

    /// 错误等级 — 对应 AGENTS.md §4.4
    enum ErrorLevel: Equatable, Sendable {
        /// L2 可恢复: Toast + 重试按钮
        case l2Recoverable(message: String)
        /// L3 阻断: 全屏引导页（当前无 L3 来源，预留给 Phase 3.9）
        case l3Blocking(message: String)
    }

    // MARK: - Published State

    /// 统一视图状态
    private(set) var viewState: ViewState = .idle
    /// 任务列表（由 ProgressActor / fixture 填充）
    private(set) var tasks: [BackgroundTaskModel] = []
    /// 面板是否已展示
    private(set) var isPanelPresented: Bool = false
    /// 待确认取消的任务 ID（AC-3 取消需确认）
    private(set) var pendingCancelTaskId: String?

    // MARK: - Dependencies (Immutable Actor References)

    /// ProgressActor 引用 — 不可变 actor 引用 (docs/ui/architecture.md §6.4)
    /// 可选注入: Phase 3.9 完整集成后通过 DI 容器注入
    private let progressActor: ProgressActor?

    /// 当前活跃的加载 Task
    private var loadTask: Task<Void, Never>?

    /// UI 切片模式模拟任务源 — fixture 注入；空数组 = 无注入
    private var stubTasks: [TaskProgress] = []

    /// 模拟加载失败标记（fixture 驱动 error 态）
    private var simulateError = false

    // MARK: - Initialization

    /// 初始化 BackgroundTaskViewModel。
    ///
    /// - Parameter progressActor: ProgressActor 实例（可选注入）。
    ///   Phase 3.9 完整集成后通过 DI 容器注入。
    init(progressActor: ProgressActor? = nil) {
        self.progressActor = progressActor
    }

    // MARK: - Computed Properties

    /// 是否存在活跃任务 (US-SYS-001 AC-5: 无活跃任务时自动隐藏)
    var hasActiveTasks: Bool {
        tasks.contains { $0.status == .running }
    }

    // MARK: - Actions

    /// 打开后台任务面板。
    ///
    /// 设置 state = .loading，加载任务列表，完成后设置 .completed 或 .error。
    /// 遵循 AGENTS.md §8.2 状态流转: idle→loading→completed/error/cancelled。
    func openPanel() {
        isPanelPresented = true
        loadTasks()
    }

    /// 关闭面板。
    func closePanel() {
        loadTask?.cancel()
        loadTask = nil
        isPanelPresented = false
        pendingCancelTaskId = nil
        tasks = []
        viewState = .idle
    }

    /// 加载活跃任务列表。
    ///
    /// 当前 UI 切片模式: 通过 fixture 注入 stub 任务；真实数据源 (ProgressActor /
    /// TaskQueueActor progressStream) 在 Phase 3.9 接入。
    func loadTasks() {
        // 防止重复加载
        guard viewState != .loading else { return }

        // 取消已有 Task
        loadTask?.cancel()

        // Set loading synchronously (AGENTS.md §8.1: first line of action)
        viewState = .loading

        loadTask = Task { [weak self] in
            guard let self else { return }

            do {
                // 🔮 Phase 3.9+: 通过 TaskQueueActor.progressStream 实时订阅进度
                // (AGENTS.md §8.3 / docs/ui/architecture.md §6.3)。当前 UI 切片在
                // Preview/测试中通过 loadPreloadedTasks 注入确定性数据。
                if self.simulateError {
                    throw BackgroundTaskError.loadFailed
                }

                // 短暂模拟加载以展示 loading 态
                try await Task.sleep(nanoseconds: 300_000_000)

                guard !Task.isCancelled else {
                    self.viewState = .cancelled
                    return
                }

                if self.progressActor != nil {
                    // Phase 3.9: 从 ProgressActor 加载断点续传进度记录
                    // self.tasks = try await ... (接入时补充)
                }

                self.tasks = self.stubTasks.map(BackgroundTaskModel.init)
                self.viewState = .completed
            } catch is CancellationError {
                self.viewState = .cancelled
            } catch {
                guard !Task.isCancelled else {
                    self.viewState = .cancelled
                    return
                }
                self.viewState = .error(.l2Recoverable(
                    message: "Unable to load background tasks. Please try again."
                ))
            }
        }
    }

    /// 重试加载 (L2 恢复路径)。
    func retry() {
        loadTasks()
    }

    /// 暂停单个任务 (US-SYS-001 AC-3)。
    ///
    /// 任务进入挂起状态，不释放已占用的资源，可随时恢复继续。
    /// - Parameter taskId: 目标任务 ID
    func pauseTask(_ taskId: String) {
        guard let idx = tasks.firstIndex(where: { $0.taskId == taskId }) else { return }
        tasks[idx].status = .paused

        // 🔮 Phase 3.9: 转发 TaskQueueActor.pause(taskId:)（Core 串行队列）
        // 当前为本地 UI 状态更新（fixture 切片模式）
    }

    /// 恢复已暂停任务 (US-SYS-001 AC-3)。
    /// - Parameter taskId: 目标任务 ID
    func resumeTask(_ taskId: String) {
        guard let idx = tasks.firstIndex(where: { $0.taskId == taskId }) else { return }
        guard tasks[idx].status == .paused else { return }
        tasks[idx].status = .running
    }

    /// 请求取消任务 — 进入确认状态（AC-3 取消需确认，requiresConfirmation: true）。
    /// - Parameter taskId: 目标任务 ID
    func requestCancelTask(_ taskId: String) {
        pendingCancelTaskId = taskId
    }

    /// 确认取消任务 — 完全终止但记录已处理进度 (US-SYS-001 AC-3/AC-4)。
    ///
    /// UI 层从活跃列表移除任务；断点进度写入 SQLite TaskProgress 由
    /// ProgressActor 在 Phase 3.9 接管（AC-4 契约）。
    func confirmCancelTask(_ taskId: String) {
        guard let idx = tasks.firstIndex(where: { $0.taskId == taskId }) else {
            pendingCancelTaskId = nil
            return
        }
        tasks[idx].status = .cancelled
        tasks.remove(at: idx)
        pendingCancelTaskId = nil

        // 🔮 Phase 3.9: ProgressActor.save(lastProcessedIndex) 记录断点进度
        // + TaskQueueActor.cancel(taskId:) 终止任务 + 审计 .backgroundTaskInterrupted
    }

    /// 取消确认弹窗（不执行取消）。
    func dismissCancelConfirmation() {
        pendingCancelTaskId = nil
    }

    // MARK: - Fixture Injection

    /// 预加载确定性任务列表（Preview / 测试 / XCUITest / Live Sim Review fixture 注入）。
    ///
    /// - Parameter items: TaskProgress 数组（来自 fixture loader）
    func loadPreloadedTasks(_ items: [TaskProgress]) {
        stubTasks = items
        tasks = items.map(BackgroundTaskModel.init)
        viewState = .completed
    }

    /// 注入加载错误状态（Preview / 测试 fixture 驱动 error 态）。
    func simulateLoadError(_ message: String = "Unable to load background tasks") {
        simulateError = true
        viewState = .error(.l2Recoverable(message: message))
    }
}

// MARK: - Errors

/// 后台任务加载错误
enum BackgroundTaskError: Error {
    /// 加载失败
    case loadFailed

    var localizedDescription: String {
        "Unable to load background tasks"
    }
}
