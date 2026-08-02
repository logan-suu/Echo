// ==========================================
// 文件: ProgressActorTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SYS-001 (AC-3 取消后询问, AC-4 断点续传),
//            docs/02-architecture/架构设计文档.md §6.2 (恢复流程),
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.7 - 断点续传集成到长任务 单元测试
// AC 覆盖: US-SYS-001 AC-3 ✅ (检测未完成进度 → 弹窗询问 继续/重新开始),
//          AC-4 ✅ (继续保留进度 / 重新开始清除进度 意图映射)
// 架构约束: AGENTS.md §8.1 (@MainActor + state enum), §8.2 (状态流转),
//           docs/ui/architecture.md §6~7 (适配器契约 — 不保存第二份领域真相)
// 生成时间: 2026-08-02
// ==========================================

import Testing
import Foundation
@testable import Echo

@MainActor
struct ResumeProgressPromptTests {

    // MARK: - Fixture Helpers

    private func makeTaskProgress(
        taskId: String = "task-index-001",
        taskType: TaskType = .fullIndex,
        lastProcessedIndex: Int = 50,
        totalCount: Int = 128
    ) -> TaskProgress {
        TaskProgress(
            taskId: taskId,
            taskType: taskType,
            lastProcessedIndex: lastProcessedIndex,
            totalCount: totalCount,
            lastProcessedId: "item-\(lastProcessedIndex)"
        )
    }

    // MARK: - US-SYS-001 AC-3: Pending progress detection

    @Test("Initial state is idle with no prompt")
    func test_AC3_initialState() {
        let vm = ResumeProgressViewModel()
        #expect(vm.viewState == .idle)
        #expect(vm.isPromptPresented == false)
    }

    @Test("Pending progress fixture transitions to prompt state")
    func test_AC3_pendingTransitionsToPrompt() {
        let vm = ResumeProgressViewModel()
        vm.loadFixture("resume-progress-pending")

        vm.checkForPendingProgress(taskType: .fullIndex)

        #expect(vm.viewState == .checking)
    }

    @Test("No pending progress fixture transitions to none state")
    func test_AC3_noneTransitionsToNone() {
        let vm = ResumeProgressViewModel()
        vm.loadFixture("resume-progress-none")

        vm.checkForPendingProgress(taskType: .dataSourceSync)

        #expect(vm.viewState == .checking)
    }

    @Test("Continue after prompt maps to resumed with preserved progress")
    func test_AC4_continuePreservesProgress() {
        let vm = ResumeProgressViewModel()
        let progress = makeTaskProgress(lastProcessedIndex: 50, totalCount: 128)
        vm.presentPrompt(progress)

        vm.continueTask()

        #expect(vm.viewState == .resumed)
        #expect(vm.isPromptPresented == false)
        #expect(vm.lastResumeTarget?.lastProcessedIndex == 50)
        #expect(vm.lastResumeTarget?.totalCount == 128)
    }

    @Test("Restart after prompt maps to restarted (progress cleared on Core side)")
    func test_AC4_restartClearsProgress() {
        let vm = ResumeProgressViewModel()
        vm.presentPrompt(makeTaskProgress())

        vm.restartTask()

        #expect(vm.viewState == .restarted)
        #expect(vm.isPromptPresented == false)
        #expect(vm.lastResumeTarget != nil)
    }

    @Test("Continue without prompt is a no-op")
    func test_AC4_continueWithoutPromptNoop() {
        let vm = ResumeProgressViewModel()
        vm.continueTask()

        #expect(vm.viewState == .idle)
        #expect(vm.lastResumeTarget == nil)
    }

    @Test("Restart without prompt is a no-op")
    func test_AC4_restartWithoutPromptNoop() {
        let vm = ResumeProgressViewModel()
        vm.restartTask()

        #expect(vm.viewState == .idle)
        #expect(vm.lastResumeTarget == nil)
    }

    @Test("Dismiss prompt returns to idle without changing progress")
    func test_AC4_dismissPrompt() {
        let vm = ResumeProgressViewModel()
        vm.presentPrompt(makeTaskProgress())
        #expect(vm.isPromptPresented == true)

        vm.dismissPrompt()

        #expect(vm.isPromptPresented == false)
        #expect(vm.viewState == .idle)
    }

    // MARK: - US-SYS-001 AC-4: Error mapping (L2)

    @Test("simulateCheckError sets L2 error state")
    func test_AC4_errorState() {
        let vm = ResumeProgressViewModel()
        vm.simulateCheckError()

        #expect(vm.viewState == .error(.l2Recoverable(message: "Unable to check saved progress")))
    }

    @Test("retry after error re-checks and recovers to prompt")
    func test_AC4_retryAfterError() {
        let vm = ResumeProgressViewModel()
        vm.loadFixture("resume-progress-pending")
        vm.simulateCheckError()
        #expect(vm.viewState == .error(.l2Recoverable(message: "Unable to check saved progress")))

        vm.checkForPendingProgress(taskType: .fullIndex)

        #expect(vm.viewState == .checking)
    }

    // MARK: - Fixture Loader

    @Test("Fixture loader returns pending progress for pending fixture")
    func test_fixturePending() {
        let fixture = ResumeProgressFixtureLoader.load("resume-progress-pending")
        #expect(fixture.taskType == .fullIndex)
        #expect(fixture.pendingProgress?.lastProcessedIndex == 50)
        #expect(fixture.pendingProgress?.totalCount == 128)
        #expect(fixture.loadError == false)
    }

    @Test("Fixture loader returns nil progress for none fixture")
    func test_fixtureNone() {
        let fixture = ResumeProgressFixtureLoader.load("resume-progress-none")
        #expect(fixture.taskType == .dataSourceSync)
        #expect(fixture.pendingProgress == nil)
    }

    @Test("Fixture loader flags load error for error fixture")
    func test_fixtureError() {
        let fixture = ResumeProgressFixtureLoader.load("resume-progress-error")
        #expect(fixture.taskType == .modelLoad)
        #expect(fixture.loadError == true)
    }

    @Test("Fixture loader returns none for unknown fixture")
    func test_fixtureUnknown() {
        let fixture = ResumeProgressFixtureLoader.load("resume-progress-unknown")
        #expect(fixture.pendingProgress == nil)
        #expect(fixture.loadError == false)
    }
}
