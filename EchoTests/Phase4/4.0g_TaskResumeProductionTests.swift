// ==========================================
// File: 4.0g_TaskResumeProductionTests.swift
// Spec: docs/01-spec/用户故事与验收标准规格书.md → US-SYS-001 AC-3/AC-4/AC-7
// Task: 4.0g - Production task resume loop
// AC Coverage: exact task recovery, checkpoint preservation, fail-closed descriptors,
//              queue ownership filtering, idempotence, pause/cancel semantics
// Architecture: AGENTS.md §4.3, §4.5, §7.3, §8.1
// Generated: 2026-09-04
// ==========================================

import Foundation
import Testing
@testable import Echo

@Suite("4.0g Production Task Resume", .serialized)
struct TaskResumeProductionTests {
    private let db = DatabaseManager.shared
    private let progressActor = ProgressActor.shared

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM TaskProgress")
        try await db.execute(sql: "DELETE FROM PendingOperations")
        try await db.execute(sql: "DELETE FROM AuditLog")
    }

    private func descriptor(
        payload: Data = Data("safe-descriptor".utf8),
        sourceTypes: [String] = ["photo"]
    ) throws -> Data {
        try TaskResumeDescriptor(
            operation: .sync,
            sourceTypes: sourceTypes,
            payload: payload
        ).encoded()
    }

    @Test("AC-4: unknown raw task types remain readable and diagnosable")
    func test_AC4_unknownRawTaskTypeIsNotDropped() async throws {
        try await db.executeWrite(
            sql: """
                INSERT INTO TaskProgress
                  (taskId, taskType, lastProcessedIndex, totalCount, createdAt, updatedAt, lastProcessedId, resumeData)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            bindings: [
                .text("unknown-task"), .text("retiredTaskType"), .int(4), .int(10),
                .double(Date().timeIntervalSince1970), .double(Date().timeIntervalSince1970),
                .text("item-4"), .blob(try descriptor()),
            ]
        )

        let loaded = try await progressActor.load(taskId: "unknown-task")
        #expect(loaded?.rawTaskType == "retiredTaskType")
        #expect(loaded?.taskType == .unknown)
        #expect(try await progressActor.loadAll().contains { $0.taskId == "unknown-task" })
    }

    @Test("AC-4: resume descriptors reject corruption, unsupported versions, and oversized payloads")
    func test_AC4_resumeDescriptorValidationFailsClosed() throws {
        let valid = TaskResumeDescriptor(operation: .sync, sourceTypes: ["photo"], payload: Data("ok".utf8))
        let encoded = try valid.encoded()
        #expect(try TaskResumeDescriptor.decode(encoded) == valid)

        var corrupted = encoded
        corrupted[corrupted.index(before: corrupted.endIndex)] ^= 0x01
        #expect(throws: TaskResumeDescriptorError.self) {
            _ = try TaskResumeDescriptor.decode(corrupted)
        }

        #expect(throws: TaskResumeDescriptorError.self) {
            _ = try TaskResumeDescriptor(
                schemaVersion: TaskResumeDescriptor.currentSchemaVersion + 1,
                operation: .sync,
                sourceTypes: ["photo"],
                payload: Data()
            ).encoded()
        }

        #expect(throws: TaskResumeDescriptorError.self) {
            _ = try TaskResumeDescriptor(
                operation: .sync,
                sourceTypes: ["photo"],
                payload: Data(repeating: 0x41, count: TaskResumeDescriptor.maximumPayloadBytes + 1)
            ).encoded()
        }
    }

    @Test("AC-4: Continue preserves the exact persisted checkpoint when queue takes ownership")
    func test_AC4_continueDoesNotOverwriteCheckpoint() async throws {
        let taskId = "continue-checkpoint"
        let stored = TaskProgress(
            taskId: taskId,
            taskType: .dataSourceSync,
            lastProcessedIndex: 7,
            totalCount: 20,
            lastProcessedId: "item-7",
            resumeData: try descriptor()
        )
        try await progressActor.save(progress: stored)

        let hold = AsyncGate()
        let registry = TaskRecoveryRegistry()
        await registry.register(taskType: .dataSourceSync) { request in
            return TaskQueueActor.QueuedJob(
                taskId: request.progress.taskId,
                taskType: .dataSourceSync,
                totalCount: request.progress.totalCount,
                resumeData: request.progress.resumeData
            ) { _ in
                await hold.wait()
            }
        }
        let queue = TaskQueueActor(progressActor: progressActor)
        let privacy = PrivacyActor(db: db)
        try await privacy.updatePolicy(UserPolicy(authorizedSourceTypes: ["photo"]))
        let coordinator = TaskRecoveryCoordinator(
            progressActor: progressActor,
            taskQueue: queue,
            registry: registry,
            privacyActor: privacy,
            pendingOpsActor: nil,
            auditWriter: nil
        )

        let outcome = try await coordinator.continueTask(stored)
        #expect(outcome == .resumed)
        let afterEnqueue = try await progressActor.load(taskId: taskId)
        #expect(afterEnqueue?.lastProcessedIndex == 7)
        #expect(afterEnqueue?.lastProcessedId == "item-7")
        #expect(await queue.ownedTaskIDs().contains(taskId))

        await hold.open()
    }

    @Test("AC-4: Restart reserves task identity before checkpoint replacement")
    func test_AC4_restartReservationPreventsCompetingOwner() async throws {
        let taskId = "restart-checkpoint"
        let stored = TaskProgress(
            taskId: taskId,
            taskType: .dataSourceSync,
            lastProcessedIndex: 9,
            totalCount: 20,
            lastProcessedId: "item-9",
            resumeData: try descriptor()
        )
        try await progressActor.save(progress: stored)

        let queue = TaskQueueActor(progressActor: progressActor)
        let occupied = AsyncGate()
        let registry = TaskRecoveryRegistry()
        await registry.register(taskType: .dataSourceSync) { request in
            do {
                try await queue.enqueue(
                    TaskQueueActor.QueuedJob(
                        taskId: request.progress.taskId,
                        taskType: .dataSourceSync,
                        totalCount: request.progress.totalCount,
                        resumeData: request.progress.resumeData
                    ) { _ in await occupied.wait() },
                    progressPolicy: .preserveExisting
                )
                Issue.record("a competing enqueue must not acquire a reserved recovery task ID")
            } catch TaskQueueError.taskAlreadyQueued {
                // Expected: the recovery reservation owns the exact task identity.
            }
            return TaskQueueActor.QueuedJob(
                taskId: request.progress.taskId,
                taskType: .dataSourceSync,
                totalCount: request.progress.totalCount,
                resumeData: request.progress.resumeData
            ) { _ in await occupied.wait() }
        }
        let privacy = PrivacyActor(db: db)
        try await privacy.updatePolicy(UserPolicy(authorizedSourceTypes: ["photo"]))
        let coordinator = TaskRecoveryCoordinator(
            progressActor: progressActor,
            taskQueue: queue,
            registry: registry,
            privacyActor: privacy,
            pendingOpsActor: nil,
            auditWriter: nil
        )

        do {
            #expect(try await coordinator.restartTask(stored) == .restarted)
        } catch {
            await occupied.open()
            throw error
        }
        let reset = try await progressActor.load(taskId: taskId)
        #expect(reset?.lastProcessedIndex == 0)
        #expect(reset?.lastProcessedId == nil)
        await occupied.open()
    }

    @Test("AC-3: pause retains the same active job until resume")
    func test_AC3_pauseSuspendsWithoutDiscardingJob() async throws {
        let queue = TaskQueueActor(progressActor: progressActor)
        let reachedSafePoint = AsyncGate()
        let enterPauseCheck = AsyncGate()
        let finished = AsyncGate()
        let run = Task {
            try await queue.enqueueAndWait(TaskQueueActor.QueuedJob(
                taskId: "pause-job",
                taskType: .fullIndex,
                totalCount: 2
            ) { context in
                try await context.report(processedIndex: 1, lastProcessedId: "item-1")
                await reachedSafePoint.open()
                await enterPauseCheck.wait()
                try await context.checkPaused()
                try await context.report(processedIndex: 2, lastProcessedId: "item-2")
                await finished.open()
            })
        }

        await reachedSafePoint.wait()
        await queue.pause(taskId: "pause-job")
        await enterPauseCheck.open()
        try await Task.sleep(for: .milliseconds(60))
        #expect(await queue.activeTaskID() == "pause-job")
        #expect(await queue.isPaused(taskId: "pause-job"))
        #expect(try await progressActor.load(taskId: "pause-job")?.lastProcessedIndex == 1)

        await queue.resume(taskId: "pause-job")
        await finished.wait()
        _ = try await run.value
        #expect(try await progressActor.load(taskId: "pause-job") == nil)
    }

    @Test("AC-4: coordinator exposes every orphaned record and excludes queue-owned task IDs")
    func test_AC4_pendingRecordsArePerTaskAndExcludeCurrentSessionOwnership() async throws {
        let queue = TaskQueueActor(progressActor: progressActor)
        let hold = AsyncGate()
        try await queue.enqueue(TaskQueueActor.QueuedJob(
            taskId: "owned",
            taskType: .dataSourceSync,
            totalCount: 10,
            resumeData: try descriptor()
        ) { _ in await hold.wait() })
        try await progressActor.save(progress: TaskProgress(
            taskId: "orphan-a", taskType: .dataSourceSync,
            lastProcessedIndex: 2, totalCount: 10, resumeData: try descriptor()
        ))
        try await progressActor.save(progress: TaskProgress(
            taskId: "orphan-b", taskType: .dataSourceSync,
            lastProcessedIndex: 6, totalCount: 10, resumeData: try descriptor()
        ))

        let coordinator = TaskRecoveryCoordinator(
            progressActor: progressActor,
            taskQueue: queue,
            registry: TaskRecoveryRegistry(),
            privacyActor: PrivacyActor(db: db),
            pendingOpsActor: nil,
            auditWriter: nil
        )
        let records = try await coordinator.pendingRecords(taskType: .dataSourceSync)
        #expect(Set(records.map(\.taskId)) == ["orphan-a", "orphan-b"])
        await hold.open()
    }

    @Test("AC-4: current authorization is revalidated before launcher execution")
    func test_AC4_revokedSourceFailsClosedAndKeepsCheckpoint() async throws {
        let stored = TaskProgress(
            taskId: "revoked", taskType: .dataSourceSync,
            lastProcessedIndex: 3, totalCount: 8, resumeData: try descriptor(sourceTypes: ["photo"])
        )
        try await progressActor.save(progress: stored)
        let launcherProbe = InvocationProbe()
        let registry = TaskRecoveryRegistry()
        await registry.register(taskType: .dataSourceSync) { request in
            await launcherProbe.markInvoked()
            return TaskQueueActor.QueuedJob(
                taskId: request.progress.taskId,
                taskType: .dataSourceSync,
                totalCount: request.progress.totalCount
            ) { _ in }
        }
        let privacy = PrivacyActor(db: db)
        try await privacy.updatePolicy(UserPolicy(authorizedSourceTypes: []))
        let coordinator = TaskRecoveryCoordinator(
            progressActor: progressActor,
            taskQueue: TaskQueueActor(progressActor: progressActor),
            registry: registry,
            privacyActor: privacy,
            pendingOpsActor: nil,
            auditWriter: nil
        )

        await #expect(throws: TaskRecoveryError.self) {
            _ = try await coordinator.continueTask(stored)
        }
        #expect(try await progressActor.load(taskId: "revoked")?.lastProcessedIndex == 3)
        #expect(await launcherProbe.wasInvoked == false)
    }

    @Test("AC-3: cancelling a paused queued task clears queue ownership")
    func test_AC3_cancelPausedQueuedTaskClearsPauseOwnership() async throws {
        let queue = TaskQueueActor(progressActor: progressActor)
        let blocker = AsyncGate()
        try await queue.enqueue(TaskQueueActor.QueuedJob(
            taskId: "blocking-owner", taskType: .fullIndex, totalCount: 1
        ) { _ in await blocker.wait() })
        try await queue.enqueue(TaskQueueActor.QueuedJob(
            taskId: "paused-queued", taskType: .dataSourceSync, totalCount: 1
        ) { _ in })

        await queue.pause(taskId: "paused-queued")
        #expect(await queue.isPaused(taskId: "paused-queued"))
        await queue.cancel(taskId: "paused-queued")

        #expect(await queue.isPaused(taskId: "paused-queued") == false)
        #expect(await queue.ownedTaskIDs().contains("paused-queued") == false)
        await blocker.open()
    }

    @Test("AC-3: cancelling an orphan does not claim success or erase its checkpoint")
    func test_AC3_cancelOrphanReturnsFalseAndRetainsCheckpoint() async throws {
        let stored = TaskProgress(
            taskId: "orphan-cancel", taskType: .dataSourceSync,
            lastProcessedIndex: 4, totalCount: 9, resumeData: try descriptor()
        )
        try await progressActor.save(progress: stored)
        let queue = TaskQueueActor(progressActor: progressActor)

        #expect(await queue.cancel(taskId: stored.taskId) == false)
        #expect(try await progressActor.load(taskId: stored.taskId)?.lastProcessedIndex == 4)
    }

    @Test("AC-4: unsupported persisted tasks remain visible without recovery actions")
    @MainActor
    func test_AC4_unsupportedTaskIsNonActionableL2() async throws {
        let stored = TaskProgress(
            taskId: "unsupported-ui", rawTaskType: "retiredTaskType",
            lastProcessedIndex: 2, totalCount: 7, resumeData: try descriptor()
        )
        try await progressActor.save(progress: stored)
        let coordinator = TaskRecoveryCoordinator(
            progressActor: progressActor,
            taskQueue: TaskQueueActor(progressActor: progressActor),
            registry: TaskRecoveryRegistry(),
            privacyActor: PrivacyActor(db: db),
            pendingOpsActor: nil,
            auditWriter: nil
        )
        let viewModel = ResumeProgressViewModel(
            progressActor: progressActor,
            recoveryCoordinator: coordinator,
            checkDelayNanoseconds: 0
        )

        viewModel.checkForPendingProgress()
        try await Task.sleep(for: .milliseconds(100))

        #expect(viewModel.pendingProgressRecords.contains { $0.taskId == stored.taskId })
        #expect(viewModel.isPromptPresented == false)
        guard case .error(.l2Recoverable(let message)) = viewModel.viewState else {
            Issue.record("unsupported task must map to a non-actionable L2 state")
            return
        }
        #expect(message.contains("not supported"))
    }

    @Test("AC-4: duplicate recovery attempts cannot enqueue the same task twice")
    func test_AC4_duplicateRecoveryAttemptIsSerialized() async throws {
        let stored = TaskProgress(
            taskId: "double-tap", taskType: .dataSourceSync,
            lastProcessedIndex: 2, totalCount: 8, resumeData: try descriptor()
        )
        try await progressActor.save(progress: stored)
        let launcherEntered = AsyncGate()
        let releaseLauncher = AsyncGate()
        let holdJob = AsyncGate()
        let registry = TaskRecoveryRegistry()
        await registry.register(taskType: .dataSourceSync) { request in
            await launcherEntered.open()
            await releaseLauncher.wait()
            return TaskQueueActor.QueuedJob(
                taskId: request.progress.taskId,
                taskType: .dataSourceSync,
                totalCount: request.progress.totalCount,
                resumeData: request.progress.resumeData
            ) { _ in await holdJob.wait() }
        }
        let privacy = PrivacyActor(db: db)
        try await privacy.updatePolicy(UserPolicy(authorizedSourceTypes: ["photo"]))
        let coordinator = TaskRecoveryCoordinator(
            progressActor: progressActor,
            taskQueue: TaskQueueActor(progressActor: progressActor),
            registry: registry,
            privacyActor: privacy,
            pendingOpsActor: nil,
            auditWriter: nil
        )

        let first = Task { try await coordinator.continueTask(stored) }
        await launcherEntered.wait()
        await #expect(throws: TaskRecoveryError.recoveryAlreadyInProgress) {
            _ = try await coordinator.continueTask(stored)
        }
        await releaseLauncher.open()
        #expect(try await first.value == .resumed)
        await holdJob.open()
    }

    @Test("AC-3: active cancellation waits for the final checkpoint before returning")
    func test_AC3_cancelPublishesAfterFinalCheckpoint() async throws {
        let queue = TaskQueueActor(progressActor: progressActor)
        let running = AsyncGate()
        let job = Task {
            try await queue.enqueueAndWait(TaskQueueActor.QueuedJob(
                taskId: "cancel-final", taskType: .fullIndex, totalCount: 3,
                resumeData: try descriptor()
            ) { context in
                try await context.report(processedIndex: 1, lastProcessedId: "item-1")
                await running.open()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    try await context.report(processedIndex: 2, lastProcessedId: "item-2")
                    throw CancellationError()
                }
            })
        }
        await running.wait()
        await queue.cancel(taskId: "cancel-final")

        #expect(try await progressActor.load(taskId: "cancel-final")?.lastProcessedIndex == 2)
        await #expect(throws: TaskQueueError.self) { try await job.value }
    }

    @Test("AC-7: recovery audit stores structured action, point, choice, and outcome")
    func test_AC7_recoveryAuditUsesStructuredFields() async throws {
        let stored = TaskProgress(
            taskId: "audit-recovery", taskType: .dataSourceSync,
            lastProcessedIndex: 5, totalCount: 8, resumeData: try descriptor()
        )
        try await progressActor.save(progress: stored)
        let hold = AsyncGate()
        let registry = TaskRecoveryRegistry()
        await registry.register(taskType: .dataSourceSync) { request in
            TaskQueueActor.QueuedJob(
                taskId: request.progress.taskId,
                taskType: .dataSourceSync,
                totalCount: request.progress.totalCount,
                resumeData: request.progress.resumeData
            ) { _ in await hold.wait() }
        }
        let privacy = PrivacyActor(db: db)
        try await privacy.updatePolicy(UserPolicy(authorizedSourceTypes: ["photo"]))
        let coordinator = TaskRecoveryCoordinator(
            progressActor: progressActor,
            taskQueue: TaskQueueActor(progressActor: progressActor),
            registry: registry,
            privacyActor: privacy,
            pendingOpsActor: nil,
            auditWriter: privacy
        )

        _ = try await coordinator.continueTask(stored)
        let entry = try await privacy.fetchAuditLogs(
            limit: 1,
            eventType: .backgroundTaskInterrupted
        ).first
        #expect(entry?.action == "recover")
        #expect(entry?.resumePoint == 5)
        #expect(entry?.userChoiceOnRestart == "continue")
        #expect(entry?.outcome == "resumed")
        await hold.open()
    }
}

private actor AsyncGate {
    private var isOpen = false

    func wait() async {
        while !isOpen {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
    }
}

private actor InvocationProbe {
    private(set) var wasInvoked = false

    func markInvoked() {
        wasInvoked = true
    }
}
