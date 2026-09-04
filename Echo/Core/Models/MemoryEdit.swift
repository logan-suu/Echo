// ==========================================
// File: MemoryEdit.swift
// Spec: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-007
// Task: 4.0e - Memory editing, re-indexing, and persistent conflict closure
// AC coverage: AC-1 through AC-7
// Architecture: AGENTS.md §4.2 (Actor isolation), §7.2 (explicit trace IDs)
// Generated: 2026-09-03
// ==========================================

import Foundation

public nonisolated struct MemoryUserEdit: Sendable, Codable, Equatable {
    public let memoryID: UUID
    public let title: String
    public let description: String
    public let tags: [String]
    public let updatedAt: Date

    public init(memoryID: UUID, title: String, description: String, tags: [String], updatedAt: Date) {
        self.memoryID = memoryID
        self.title = title
        self.description = description
        self.tags = tags
        self.updatedAt = updatedAt
    }
}

public nonisolated struct MemoryEditRequest: Sendable, Equatable {
    public let memoryID: UUID
    public let title: String
    public let description: String
    public let tags: [String]
    public let timestamp: Date

    public init(memoryID: UUID, title: String, description: String, tags: [String], timestamp: Date) {
        self.memoryID = memoryID
        self.title = title
        self.description = description
        self.tags = tags
        self.timestamp = timestamp
    }
}

public nonisolated struct PendingMemorySourceChange: Sendable, Codable, Equatable {
    public let assetID: String
    public let source: String
    public let changeType: String
    public let newContentHash: String?
    public let hashSkipped: Bool

    public init(
        assetID: String,
        source: String,
        changeType: String,
        newContentHash: String?,
        hashSkipped: Bool
    ) {
        self.assetID = assetID
        self.source = source
        self.changeType = changeType
        self.newContentHash = newContentHash
        self.hashSkipped = hashSkipped
    }
}

public nonisolated protocol MemoryExternalChangeApplying: Actor {
    func applyResolvedExternalChange(
        _ change: PendingMemorySourceChange,
        memoryID: UUID,
        traceID: String
    ) async throws
}

public nonisolated struct MemoryEditPostCommitTask: Sendable, Codable, Equatable {
    public let operationID: String
    public let generationID: String
    public let obsoleteVectorIDs: [UUID]

    public init(operationID: String, generationID: String, obsoleteVectorIDs: [UUID]) {
        self.operationID = operationID
        self.generationID = generationID
        self.obsoleteVectorIDs = obsoleteVectorIDs
    }
}

public nonisolated protocol MemoryEditPostCommitCleaning: Actor {
    func cleanup(_ task: MemoryEditPostCommitTask) async throws
}

public nonisolated struct MemoryEditConflict: Sendable, Codable, Equatable {
    public let memoryID: UUID
    public let externalVersionSummary: String
    public let detectedAt: Date
    public let pendingChange: PendingMemorySourceChange?

    public init(
        memoryID: UUID,
        externalVersionSummary: String,
        detectedAt: Date,
        pendingChange: PendingMemorySourceChange? = nil
    ) {
        self.memoryID = memoryID
        self.externalVersionSummary = externalVersionSummary
        self.detectedAt = detectedAt
        self.pendingChange = pendingChange
    }
}

public nonisolated struct MemoryEditSnapshot: Sendable {
    public let memory: Memory
    public let edit: MemoryUserEdit?
    public let conflict: MemoryEditConflict?

    public init(memory: Memory, edit: MemoryUserEdit?, conflict: MemoryEditConflict?) {
        self.memory = memory
        self.edit = edit
        self.conflict = conflict
    }
}

public nonisolated struct MemoryEditResult: Sendable {
    public let snapshot: MemoryEditSnapshot
    public let effectiveText: String

    public init(snapshot: MemoryEditSnapshot, effectiveText: String) {
        self.snapshot = snapshot
        self.effectiveText = effectiveText
    }
}

public nonisolated enum MemoryConflictResolution: Sendable, Equatable {
    case local
    case external
    case merge(MemoryEditRequest)
}

public nonisolated enum ExternalChangeDisposition: Sendable, Equatable {
    case proceed
    case conflictRecorded
    case skippedUserLocked
}

public nonisolated enum MemoryEditError: Error, LocalizedError, Sendable, Equatable {
    case privacyDenied
    case memoryNotFound
    case routeUnavailable
    case conflictMissing
    case conflictPending
    case syncInProgress
    case externalReplayUnavailable
    case pendingOperationInvalid

    public var errorDescription: String? {
        switch self {
        case .privacyDenied: "The memory edit was denied by the current privacy policy."
        case .memoryNotFound: "The memory no longer exists."
        case .routeUnavailable: "The active text index is unavailable."
        case .conflictMissing: "The edit conflict no longer exists."
        case .conflictPending: "Resolve the external change conflict before saving this memory."
        case .syncInProgress: "This memory is being updated. Please edit it again after synchronization finishes."
        case .externalReplayUnavailable: "The external version cannot be restored until synchronization is available."
        case .pendingOperationInvalid: "The pending memory-edit cleanup operation is invalid."
        }
    }
}
