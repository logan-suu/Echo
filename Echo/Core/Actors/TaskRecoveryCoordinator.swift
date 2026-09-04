// ==========================================
// File: TaskRecoveryCoordinator.swift
// Spec: docs/01-spec/用户故事与验收标准规格书.md → US-SYS-001 AC-3/AC-4/AC-7
// Task: 4.0g - Production task resume loop
// AC Coverage: typed reconstruction, exact taskId, authorization recheck,
//              idempotent Continue/Restart, L2 persistence, structured audit
// Architecture: AGENTS.md §4.2, §4.3, §4.5, §7.3
// Generated: 2026-09-04
// ==========================================

import Foundation

/// Core-only allow-list that turns a validated value descriptor into a queued job.
/// UI code can request recovery but cannot install arbitrary launchers.
public actor TaskRecoveryRegistry {
    typealias Launcher = @Sendable (TaskRecoveryRequest) async throws -> TaskQueueActor.QueuedJob

    private var launchers: [TaskType: Launcher] = [:]

    func register(taskType: TaskType, launcher: @escaping Launcher) {
        guard taskType != .unknown else { return }
        launchers[taskType] = launcher
    }

    func makeJob(for request: TaskRecoveryRequest) async throws -> TaskQueueActor.QueuedJob {
        guard request.progress.taskType != .unknown,
              let launcher = launchers[request.progress.taskType] else {
            throw TaskRecoveryError.unsupportedTaskType(request.progress.rawTaskType)
        }
        return try await launcher(request)
    }
}

/// Owns cross-process recovery attempts and serializes each exact task identity.
public actor TaskRecoveryCoordinator {
    private let progressActor: ProgressActor
    private let taskQueue: TaskQueueActor
    private let registry: TaskRecoveryRegistry
    private let privacyActor: PrivacyActor
    private let pendingOpsActor: PendingOpsActor?
    private let auditWriter: PrivacyActor?
    private var recoveringTaskIDs: Set<String> = []

    public init(
        progressActor: ProgressActor = .shared,
        taskQueue: TaskQueueActor = .shared,
        registry: TaskRecoveryRegistry,
        privacyActor: PrivacyActor = .shared,
        pendingOpsActor: PendingOpsActor? = .shared,
        auditWriter: PrivacyActor? = .shared
    ) {
        self.progressActor = progressActor
        self.taskQueue = taskQueue
        self.registry = registry
        self.privacyActor = privacyActor
        self.pendingOpsActor = pendingOpsActor
        self.auditWriter = auditWriter
    }

    /// Returns every orphaned/interrupted row and excludes jobs owned by this process.
    public func pendingRecords(taskType: TaskType? = nil) async throws -> [TaskProgress] {
        let owned = await taskQueue.ownedTaskIDs()
        return try await progressActor.loadAll()
            .filter { !owned.contains($0.taskId) }
            .filter { taskType == nil || $0.taskType == taskType }
            .sorted {
                if $0.updatedAt == $1.updatedAt { return $0.taskId < $1.taskId }
                return $0.updatedAt < $1.updatedAt
            }
    }

    public func continueTask(_ snapshot: TaskProgress) async throws -> TaskRecoveryOutcome {
        try beginRecovery(taskId: snapshot.taskId)
        defer { recoveringTaskIDs.remove(snapshot.taskId) }
        do {
            let current = try await currentProgress(matching: snapshot)
            try await ensureNotOwned(taskId: current.taskId)
            let request = try makeRequest(progress: current, choice: .continue)
            try await validatePrivacy(request.descriptor)
            let job = try await registry.makeJob(for: request)
            try validate(job: job, progress: current)
            do {
                try await taskQueue.enqueue(job, progressPolicy: .preserveExisting)
            } catch {
                throw TaskRecoveryError.enqueueFailed
            }
            await recordAudit(progress: current, choice: "continue", outcome: "resumed", success: true)
            return .resumed
        } catch {
            let mapped = Self.map(error)
            await recordFailure(snapshot, choice: "continue", error: mapped)
            throw mapped
        }
    }

    public func restartTask(_ snapshot: TaskProgress) async throws -> TaskRecoveryOutcome {
        try beginRecovery(taskId: snapshot.taskId)
        defer { recoveringTaskIDs.remove(snapshot.taskId) }
        do {
            let current = try await currentProgress(matching: snapshot)
            try await ensureNotOwned(taskId: current.taskId)
            let request = try makeRequest(progress: current, choice: .restart)
            try await validatePrivacy(request.descriptor)
            let job = try await registry.makeJob(for: request)
            try validate(job: job, progress: current)
            let reset = try await progressActor.resetForRestart(current)
            do {
                try await taskQueue.enqueue(job, progressPolicy: .preserveExisting)
            } catch {
                throw TaskRecoveryError.enqueueFailed
            }
            await recordAudit(progress: reset, choice: "restart", outcome: "restarted", success: true)
            return .restarted
        } catch {
            let mapped = Self.map(error)
            await recordFailure(snapshot, choice: "restart", error: mapped)
            throw mapped
        }
    }

    private func beginRecovery(taskId: String) throws {
        guard recoveringTaskIDs.insert(taskId).inserted else {
            throw TaskRecoveryError.recoveryAlreadyInProgress
        }
    }

    private func currentProgress(matching snapshot: TaskProgress) async throws -> TaskProgress {
        guard let current = try await progressActor.load(taskId: snapshot.taskId) else {
            throw TaskRecoveryError.progressMissing
        }
        guard abs(current.updatedAt.timeIntervalSince1970 - snapshot.updatedAt.timeIntervalSince1970) < 0.001,
              current.rawTaskType == snapshot.rawTaskType,
              current.lastProcessedIndex == snapshot.lastProcessedIndex,
              current.totalCount == snapshot.totalCount else {
            throw TaskRecoveryError.staleProgress
        }
        return current
    }

    private func ensureNotOwned(taskId: String) async throws {
        guard !(await taskQueue.ownedTaskIDs()).contains(taskId) else {
            throw TaskRecoveryError.taskOwnedByCurrentSession
        }
    }

    private func makeRequest(
        progress: TaskProgress,
        choice: TaskRecoveryChoice
    ) throws -> TaskRecoveryRequest {
        guard let data = progress.resumeData else {
            throw TaskRecoveryError.descriptorUnavailable
        }
        do {
            return TaskRecoveryRequest(
                progress: progress,
                descriptor: try TaskResumeDescriptor.decode(data),
                choice: choice
            )
        } catch {
            throw TaskRecoveryError.descriptorInvalid
        }
    }

    private func validatePrivacy(_ descriptor: TaskResumeDescriptor) async throws {
        let checkpoint = await privacyActor.validate(
            operation: descriptor.operation,
            traceID: UUID().uuidString,
            sourceTypes: descriptor.sourceTypes
        )
        guard checkpoint.isAllowed else { throw TaskRecoveryError.privacyDenied }
    }

    private func validate(job: TaskQueueActor.QueuedJob, progress: TaskProgress) throws {
        guard job.taskId == progress.taskId,
              job.taskType.rawValue == progress.rawTaskType,
              job.totalCount == progress.totalCount,
              job.resumeData == progress.resumeData else {
            throw TaskRecoveryError.launcherMismatch
        }
    }

    private func recordFailure(
        _ progress: TaskProgress,
        choice: String,
        error: TaskRecoveryError
    ) async {
        if let pendingOpsActor {
            let digest = AuditContentHasher.sha256Hex(progress.taskId)
            let parameters = Data("taskDigest=\(digest)|choice=\(choice)".utf8)
            try? await pendingOpsActor.add(operation: PendingOperation(
                operationId: "task-recovery-\(digest)-\(choice)",
                operationType: "taskRecovery",
                parameters: parameters,
                lastError: String(describing: error)
            ))
        }
        await recordAudit(
            progress: progress,
            choice: choice,
            outcome: String(describing: error),
            success: false
        )
    }

    private func recordAudit(
        progress: TaskProgress,
        choice: String,
        outcome: String,
        success: Bool
    ) async {
        guard let auditWriter else { return }
        let policy = await auditWriter.getPolicy()
        try? await auditWriter.writeAuditLog(
            eventType: .backgroundTaskInterrupted,
            traceID: UUID().uuidString,
            policyVersion: policy.policyVersion,
            success: success,
            sourceType: progress.rawTaskType,
            action: "recover",
            resumePoint: progress.lastProcessedIndex,
            userChoiceOnRestart: choice,
            outcome: outcome
        )
    }

    private nonisolated static func map(_ error: Error) -> TaskRecoveryError {
        if let recoveryError = error as? TaskRecoveryError { return recoveryError }
        if error is TaskResumeDescriptorError { return .descriptorInvalid }
        return .enqueueFailed
    }
}
