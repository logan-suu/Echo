// ==========================================
// 文件: BackgroundTaskPanelView.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SYS-001 (实时后台任务状态面板),
//            docs/ui/echo-memory-canvas-style.md §13 (后台任务面板 — Task surface family),
//            §10.1.3 (Task 空态), §11.2 (L1 Toast), §2.3 (semantic colors), §2.4 (SF Symbols)
//            docs/ui/architecture.md §3 (Surface View), §8 (Task surface family)
// 任务: 3.5 - 实时后台任务面板
// AC 覆盖: US-SYS-001 AC-1 ✅ (活跃任务列表), AC-2 ✅ (进度计数 + 百分比),
//          AC-3 ✅ (暂停/取消交互; 暂停任务抑制自动隐藏, PR #40 W-1),
//          AC-5 ✅ (任务列表为空时 1.5s 自动隐藏), 🔮 Core 接入 Phase 3.9
// 架构约束: AGENTS.md §8.1 (ViewModel 驱动), §17.7 (Task surface 禁止 masonry),
//           echo-memory-canvas apple-native 基础; 系统 Sheet + List 容器
// 生成时间: 2026-08-02
// ==========================================

import SwiftUI

// MARK: - BackgroundTaskPanelView

/// 实时后台任务面板 — 展示活跃后台任务的进度与暂停/取消操作。
///
/// ## Surface Family: Task
/// - 布局: 底部 Sheet (.medium detent, 可拖拽至 .large) + 系统 List (echo-memory-canvas §13.1)
/// - Masonry: 绝对禁止 (Task surface, §13 / §3.3)
/// - 系统容器: Sheet + NavigationStack + List
///
/// ## 状态驱动
/// - loading: ProgressView 居中
/// - completed: 任务列表 / 空态（无活跃任务时延迟 1.5s 自动隐藏，AC-5）
/// - error: L2 错误 + 重试按钮
/// - cancelled: 返回 idle
///
/// ## Style
/// - echo-memory-canvas token: .body/.caption, Color.primary, semantic colors, SF Symbols
/// - 每个任务行: SF Symbol + 名称 + determinate 进度条 + processed/total + 状态标签
/// - 暂停 (pause.circle) / 取消 (xmark.circle) 操作按钮
struct BackgroundTaskPanelView: View {
    // MARK: - ViewModel

    @State private var viewModel: BackgroundTaskViewModel

    /// 面板关闭回调（供父视图重置展示状态）
    var onDismiss: (() -> Void)?

    /// 环境 dismiss — 关闭系统 Sheet（Done 按钮 / AC-5 自动隐藏）
    @Environment(\.dismiss) private var dismiss

    /// 首次出现标记 — 控制 fixture 注入仅执行一次
    @State private var hasHandledLaunchArguments = false

    /// 自动隐藏调度 Task — 绑定视图生命周期（onDisappear 取消，W-4）
    @State private var autoHideTask: Task<Void, Never>?

    init(
        viewModel: BackgroundTaskViewModel = BackgroundTaskViewModel(
            progressActor: .shared,
            auditWriter: .shared,
            taskQueue: .shared
        ),
        onDismiss: (() -> Void)? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onDismiss = onDismiss
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Background Tasks")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            viewModel.closePanel()
                            dismiss()
                            onDismiss?()
                        }
                        .accessibilityIdentifier("background-tasks-done")
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .confirmationDialog(
            "Cancel Task",
            isPresented: Binding(
                get: { viewModel.pendingCancelTaskId != nil },
                set: { if !$0 { viewModel.dismissCancelConfirmation() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Cancel Task", role: .destructive) {
                if let taskId = viewModel.pendingCancelTaskId {
                    viewModel.confirmCancelTask(taskId)
                }
            }
            Button("Keep Running", role: .cancel) {
                viewModel.dismissCancelConfirmation()
            }
        } message: {
            Text("Progress up to this point will be saved. You can resume later.")
        }
        .onAppear { handleFirstAppear() }
        .onDisappear { autoHideTask?.cancel() }
        .onChange(of: viewModel.tasks.isEmpty, initial: true) { _, isEmpty in
            if isEmpty {
                scheduleAutoHideIfNeeded()
            } else {
                autoHideTask?.cancel()
            }
        }
        .accessibilityIdentifier("background-tasks-panel")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.viewState {
        case .idle, .loading:
            loadingState

        case .completed:
            if viewModel.tasks.isEmpty {
                emptyState
            } else {
                taskList
            }

        case .error(let level):
            errorState(level)

        case .cancelled:
            Color(.systemBackground)
                .onAppear { viewModel.retry() }
        }
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Color.accentColor)
            Text("Loading tasks...")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: - Empty State (US-SYS-001 AC-5)

    /// 无活跃任务 — 居中系统 List 空态 (echo-memory-canvas §13.3 / §10.1.3)
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)

            Text("No active tasks")
                .font(.headline)
                .foregroundStyle(Color.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No active tasks")
        .accessibilityIdentifier("background-tasks-empty")
    }

    // MARK: - Task List (US-SYS-001 AC-1/AC-2)

    private var taskList: some View {
        List {
            Section {
                ForEach(viewModel.tasks) { task in
                    taskRow(task)
                }
            } header: {
                Text(String(format: EchoStrings.tr(viewModel.tasks.count == 1 ? "%lld active task" : "%lld active tasks"), viewModel.tasks.count))
                    .font(.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("background-tasks-list")
    }

    /// 单个任务行 — SF Symbol + 名称 + 进度条 + 计数 + 状态标签 + 暂停/取消
    private func taskRow(_ task: BackgroundTaskModel) -> some View {
        HStack(spacing: 12) {
            // 任务类型图标
            Image(systemName: task.systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)

            // 任务信息 + 进度
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(EchoStrings.tr(task.displayName))
                        .font(.body)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(EchoStrings.tr(task.statusLabel))
                        .font(.caption)
                        .foregroundStyle(task.status == .paused ? Color.orange : Color.secondary)
                }

                // Determinate 进度条 (echo-memory-canvas §13.2)
                ProgressView(value: task.progress)
                    .tint(Color.accentColor)

                Text("\(task.progressCountText) · \(task.progressPercentText)")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            Spacer(minLength: 8)

            // 暂停 / 恢复按钮
            Button {
                if task.status == .paused {
                    viewModel.resumeTask(task.taskId)
                } else {
                    viewModel.pauseTask(task.taskId)
                }
            } label: {
                Image(systemName: task.status == .paused ? "play.circle" : "pause.circle")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(task.status == .paused
                                ? String(format: EchoStrings.tr("Resume %@"), task.localizedDisplayName)
                                : String(format: EchoStrings.tr("Pause %@"), task.localizedDisplayName))
            .accessibilityIdentifier("background-task-pause-\(task.taskId)")

            // 取消按钮
            Button {
                viewModel.requestCancelTask(task.taskId)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.title3)
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(format: EchoStrings.tr("Cancel %@"), task.localizedDisplayName))
            .accessibilityHint(EchoStrings.tr("Terminates the task and saves progress"))
            .accessibilityIdentifier("background-task-cancel-\(task.taskId)")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.accessibilityLabel)
        .accessibilityIdentifier("background-task-row-\(task.taskId)")
    }

    // MARK: - Error State (L2)

    private func errorState(_ level: BackgroundTaskViewModel.ErrorLevel) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.yellow)
                .accessibilityHidden(true)

            Text(EchoStrings.tr(errorMessage(for: level)))
                .font(.body)
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button(action: { viewModel.retry() }) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.callout)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .accessibilityIdentifier("background-tasks-retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityLabel("Unable to load background tasks")
    }

    private func errorMessage(for level: BackgroundTaskViewModel.ErrorLevel) -> String {
        switch level {
        case .l2Recoverable(let msg), .l3Blocking(let msg):
            return msg
        }
    }

    // MARK: - Auto-Hide (US-SYS-001 AC-5)

    /// 无活跃任务时延迟 1.5 秒自动关闭面板 (echo-memory-canvas §13.3)。
    /// 仅当任务列表为空（全部完成/取消）时触发；存在 paused 任务时抑制，
    /// 保留 AC-3「随时恢复继续」能力（W-1）。
    private func scheduleAutoHideIfNeeded() {
        guard viewModel.tasks.isEmpty else { return }
        autoHideTask?.cancel()

        let capturedViewModel = viewModel
        let capturedOnDismiss = onDismiss
        let capturedDismiss = dismiss

        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            guard capturedViewModel.tasks.isEmpty else { return }
            if capturedViewModel.isPanelPresented {
                capturedViewModel.closePanel()
                capturedDismiss()
                capturedOnDismiss?()
            }
        }
    }

    // MARK: - Launch Argument Fixture Injection

    /// 首次出现时处理启动参数 fixture 注入。
    ///
    /// 支持 `-ui-fixture background-tasks-loaded|empty` — XCUITest / Live Sim Review
    /// 确定性导航到面板状态。生产构建（#if DEBUG 排除）无任何注入逻辑。
    private func handleFirstAppear() {
        guard !hasHandledLaunchArguments else { return }
        hasHandledLaunchArguments = true
        #if DEBUG
        handleLaunchArguments()
        #endif
    }

    #if DEBUG
    /// 处理 XCUITest / Live Sim Review 启动参数注入确定性 fixture。
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-ui-fixture"), idx + 1 < args.count else { return }
        let fixtureID = args[idx + 1]

        switch fixtureID {
        case "background-tasks-loaded", "background-tasks-empty":
            let items = BackgroundTaskFixtureLoader.load(fixtureID)
            viewModel.loadPreloadedTasks(items)

        default:
            break
        }
    }
    #endif
}

// MARK: - Preview

#Preview("Loaded") {
    BackgroundTaskPanelView(viewModel: previewViewModel([.dataSourceSync, .fullIndex]))
}

#Preview("Paused") {
    let vm = previewViewModel([.dataSourceSync, .fullIndex])
    vm.pauseTask("task-sync-001")
    return BackgroundTaskPanelView(viewModel: vm)
}

#Preview("Empty") {
    BackgroundTaskPanelView(viewModel: previewViewModel([]))
}

#Preview("Error") {
    let vm = BackgroundTaskViewModel()
    vm.simulateLoadError()
    return BackgroundTaskPanelView(viewModel: vm)
}

// MARK: - Preview Helpers

@MainActor
private func previewViewModel(_ taskTypes: [TaskType]) -> BackgroundTaskViewModel {
    let vm = BackgroundTaskViewModel()
    let items = taskTypes.enumerated().map { index, type in
        TaskProgress(
            taskId: index == 0 ? "task-sync-001" : "task-index-001",
            taskType: type,
            lastProcessedIndex: index == 0 ? 32 : 100,
            totalCount: index == 0 ? 128 : 500
        )
    }
    vm.loadPreloadedTasks(items)
    return vm
}
