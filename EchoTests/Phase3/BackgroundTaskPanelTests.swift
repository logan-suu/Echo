// ==========================================
// 文件: BackgroundTaskPanelTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SYS-001 (实时后台任务状态面板),
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.5 - 实时后台任务面板 单元测试
// AC 覆盖: US-SYS-001 AC-1 ✅ (活跃任务列表), AC-2 ✅ (进度计数/百分比),
//          AC-3 ✅ (暂停/恢复/取消交互), AC-5 ✅ (无活跃任务自动隐藏判定)
// 架构约束: AGENTS.md §8.1 (@MainActor + state enum), §8.2 (状态流转),
//           docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约 — 不保存第二份领域真相)
// 生成时间: 2026-08-02
// ==========================================

import Testing
import Foundation
@testable import Echo

@Suite("BackgroundTaskPanel", .serialized)
@MainActor
struct BackgroundTaskPanelTests {

    // MARK: - Fixture Helpers

    private func makeTaskProgress(
        taskId: String = "task-sync-001",
        taskType: TaskType = .dataSourceSync,
        lastProcessedIndex: Int = 32,
        totalCount: Int = 128
    ) -> TaskProgress {
        TaskProgress(
            taskId: taskId,
            taskType: taskType,
            lastProcessedIndex: lastProcessedIndex,
            totalCount: totalCount,
            lastProcessedId: "photo-\(lastProcessedIndex)"
        )
    }

    // MARK: - US-SYS-001 AC-1: Active task list

    @Test("Initial state is idle with empty tasks and panel closed")
    func test_AC1_initialState() {
        let vm = BackgroundTaskViewModel()
        #expect(vm.viewState == .idle)
        #expect(vm.tasks.isEmpty)
        #expect(vm.isPanelPresented == false)
        #expect(vm.hasActiveTasks == false)
    }

    @Test("loadPreloadedTasks maps TaskProgress to UI models")
    func test_AC1_loadPreloadedMapsTasks() {
        let vm = BackgroundTaskViewModel()
        vm.loadPreloadedTasks([makeTaskProgress()])

        #expect(vm.viewState == .completed)
        #expect(vm.tasks.count == 1)
        #expect(vm.tasks[0].taskId == "task-sync-001")
        #expect(vm.tasks[0].taskType == .dataSourceSync)
        #expect(vm.tasks[0].displayName == "Syncing photos")
        #expect(vm.hasActiveTasks == true)
    }

    @Test("openPanel presents panel and enters loading state")
    func test_AC1_openPanelEntersLoading() {
        let vm = BackgroundTaskViewModel()
        vm.openPanel()

        #expect(vm.isPanelPresented == true)
        #expect(vm.viewState == .loading)
    }

    @Test("closePanel resets to idle")
    func test_AC1_closePanelResets() {
        let vm = BackgroundTaskViewModel()
        vm.openPanel()
        vm.loadPreloadedTasks([makeTaskProgress()])
        vm.closePanel()

        #expect(vm.isPanelPresented == false)
        #expect(vm.viewState == .idle)
        #expect(vm.tasks.isEmpty)
    }

    // MARK: - US-SYS-001 AC-2: Progress display

    @Test("Progress percent and count are computed correctly")
    func test_AC2_progressDisplay() {
        let vm = BackgroundTaskViewModel()
        vm.loadPreloadedTasks([makeTaskProgress(lastProcessedIndex: 32, totalCount: 128)])

        #expect(vm.tasks[0].progressCountText == "32/128")
        #expect(vm.tasks[0].progressPercentText == "25%")
        #expect(vm.tasks[0].progress == 0.25)
    }

    @Test("Progress is zero when total is zero")
    func test_AC2_progressZeroWhenNoTotal() {
        let vm = BackgroundTaskViewModel()
        vm.loadPreloadedTasks([makeTaskProgress(lastProcessedIndex: 0, totalCount: 0)])

        #expect(vm.tasks[0].progress == 0)
        #expect(vm.tasks[0].progressPercentText == "0%")
        #expect(vm.tasks[0].progressCountText == "0/0")
    }

    @Test("Progress is clamped to 1.0")
    func test_AC2_progressClamped() {
        let vm = BackgroundTaskViewModel()
        vm.loadPreloadedTasks([makeTaskProgress(lastProcessedIndex: 200, totalCount: 100)])

        #expect(vm.tasks[0].progress == 1.0)
        #expect(vm.tasks[0].progressPercentText == "100%")
    }

    @Test("Full index task has correct display metadata")
    func test_AC2_fullIndexDisplay() {
        let vm = BackgroundTaskViewModel()
        vm.loadPreloadedTasks([makeTaskProgress(taskId: "task-index-001", taskType: .fullIndex, lastProcessedIndex: 100, totalCount: 500)])

        #expect(vm.tasks[0].displayName == "Building vector index")
        #expect(vm.tasks[0].systemImage == "cube.box.fill")
        #expect(vm.tasks[0].progressPercentText == "20%")
    }

    // MARK: - US-SYS-001 AC-3: Pause / Resume / Cancel

    @Test("pauseTask sets task to paused")
    func test_AC3_pauseTask() {
        let vm = BackgroundTaskViewModel()
        vm.loadPreloadedTasks([makeTaskProgress()])

        vm.pauseTask("task-sync-001")

        #expect(vm.tasks[0].status == .paused)
        #expect(vm.tasks[0].statusLabel == "Paused")
        #expect(vm.hasActiveTasks == false)
    }

    @Test("AC-3 live polling preserves the TaskQueue paused state")
    func test_AC3_livePollingPreservesPausedState() async throws {
        let taskId = "review-paused-task"
        let progressActor = ProgressActor.shared
        let taskQueue = TaskQueueActor(progressActor: progressActor)
        try await DatabaseManager.shared.open()
        _ = try? await progressActor.delete(taskId: taskId)
        try await progressActor.save(progress: makeTaskProgress(taskId: taskId))
        await taskQueue.pause(taskId: taskId)

        let vm = BackgroundTaskViewModel(
            progressActor: progressActor,
            taskQueue: taskQueue,
            pollIntervalNanoseconds: 5_000_000
        )
        vm.openPanel()
        try await Task.sleep(for: .milliseconds(30))

        #expect(vm.tasks.first { $0.taskId == taskId }?.status == .paused)

        vm.closePanel()
        await taskQueue.resume(taskId: taskId)
        _ = try await progressActor.delete(taskId: taskId)
    }

    @Test("resumeTask resumes a paused task")
    func test_AC3_resumeTask() {
        let vm = BackgroundTaskViewModel()
        vm.loadPreloadedTasks([makeTaskProgress()])
        vm.pauseTask("task-sync-001")
        #expect(vm.tasks[0].status == .paused)

        vm.resumeTask("task-sync-001")

        #expect(vm.tasks[0].status == .running)
        #expect(vm.tasks[0].statusLabel == "Running")
        #expect(vm.hasActiveTasks == true)
    }

    @Test("requestCancelTask sets pending cancel state")
    func test_AC3_requestCancelSetsPending() {
        let vm = BackgroundTaskViewModel()
        vm.loadPreloadedTasks([makeTaskProgress()])

        vm.requestCancelTask("task-sync-001")

        #expect(vm.pendingCancelTaskId == "task-sync-001")
    }

    @Test("confirmCancelTask removes task from active list")
    func test_AC3_confirmCancelRemovesTask() {
        let vm = BackgroundTaskViewModel()
        vm.loadPreloadedTasks([makeTaskProgress()])
        vm.requestCancelTask("task-sync-001")

        vm.confirmCancelTask("task-sync-001")

        #expect(vm.tasks.isEmpty)
        #expect(vm.pendingCancelTaskId == nil)
        #expect(vm.hasActiveTasks == false)
    }

    @Test("dismissCancelConfirmation clears pending without cancelling")
    func test_AC3_dismissCancelConfirmation() {
        let vm = BackgroundTaskViewModel()
        vm.loadPreloadedTasks([makeTaskProgress()])
        vm.requestCancelTask("task-sync-001")

        vm.dismissCancelConfirmation()

        #expect(vm.pendingCancelTaskId == nil)
        #expect(vm.tasks.count == 1)
    }

    @Test("pause on unknown task is a no-op")
    func test_AC3_pauseUnknownTaskNoop() {
        let vm = BackgroundTaskViewModel()
        vm.loadPreloadedTasks([makeTaskProgress()])

        vm.pauseTask("task-unknown")

        #expect(vm.tasks[0].status == .running)
    }

    // MARK: - US-SYS-001 AC-5: Auto-hide determination

    @Test("hasActiveTasks is false when all tasks paused")
    func test_AC5_noActiveWhenAllPaused() {
        let vm = BackgroundTaskViewModel()
        vm.loadPreloadedTasks([
            makeTaskProgress(taskId: "task-sync-001"),
            makeTaskProgress(taskId: "task-index-001", taskType: .fullIndex),
        ])

        vm.pauseTask("task-sync-001")
        vm.pauseTask("task-index-001")

        #expect(vm.hasActiveTasks == false)
    }

    @Test("hasActiveTasks stays true while any task runs")
    func test_AC5_activeWhenAnyRuns() {
        let vm = BackgroundTaskViewModel()
        vm.loadPreloadedTasks([
            makeTaskProgress(taskId: "task-sync-001"),
            makeTaskProgress(taskId: "task-index-001", taskType: .fullIndex),
        ])

        vm.pauseTask("task-sync-001")

        #expect(vm.hasActiveTasks == true)
    }

    // MARK: - Fixture Loader

    @Test("Fixture loader returns 2 tasks for loaded fixture")
    func test_fixtureLoaded() {
        let items = BackgroundTaskFixtureLoader.load("background-tasks-loaded")
        #expect(items.count == 2)
        #expect(items[0].taskType == .dataSourceSync)
        #expect(items[1].taskType == .fullIndex)
    }

    @Test("Explicit fixture remains authoritative when live actors are injected")
    func test_fixturePrecedesLiveProgressActor() async {
        let vm = BackgroundTaskViewModel(
            progressActor: .shared,
            auditWriter: .shared,
            taskQueue: .shared,
            pollIntervalNanoseconds: 5_000_000
        )
        let items = BackgroundTaskFixtureLoader.load("background-tasks-loaded")
        vm.loadPreloadedTasks(items)
        vm.openPanel()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(vm.tasks.map(\.taskId) == items.map(\.taskId))
        vm.closePanel()
    }

    @Test("Fixture loader returns empty for empty fixture")
    func test_fixtureEmpty() {
        let items = BackgroundTaskFixtureLoader.load("background-tasks-empty")
        #expect(items.isEmpty)
    }

    @Test("Fixture loader returns empty for unknown fixture")
    func test_fixtureUnknown() {
        let items = BackgroundTaskFixtureLoader.load("background-tasks-unknown")
        #expect(items.isEmpty)
    }

    // MARK: - Error state

    @Test("simulateLoadError sets L2 error state")
    func test_errorState() {
        let vm = BackgroundTaskViewModel()
        vm.simulateLoadError()

        #expect(vm.viewState == .error(.l2Recoverable(message: "Unable to load background tasks")))
    }

    @Test("retry after error reloads tasks")
    func test_retryAfterError() {
        let vm = BackgroundTaskViewModel()
        vm.simulateLoadError()
        #expect(vm.viewState == .error(.l2Recoverable(message: "Unable to load background tasks")))

        vm.loadPreloadedTasks([makeTaskProgress()])

        #expect(vm.viewState == .completed)
        #expect(vm.tasks.count == 1)
    }
}
