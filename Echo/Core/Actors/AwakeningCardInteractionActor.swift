// ==========================================
// File: AwakeningCardInteractionActor.swift
// Specification: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-005 AC-5
// Task: 4.0d - Interactive Awakening Card production closure
// AC coverage: AC-4/5 (atomic feeling record and structured hash-only audit)
// Architecture: ADR-016 D-4; AGENTS.md §4.2, §5.4 and R-006/R-008
// Generated: 2026-09-02
// ==========================================

import Foundation

public actor AwakeningCardInteractionActor {
    private let feelingStore: MemoryFeelingActor
    private let privacyActor: PrivacyActor

    public init(
        feelingStore: MemoryFeelingActor = MemoryFeelingActor(),
        privacyActor: PrivacyActor = .shared
    ) {
        self.feelingStore = feelingStore
        self.privacyActor = privacyActor
    }

    public func recordFeeling(
        _ text: String,
        cardID: UUID,
        memoryID: UUID,
        traceID: String
    ) async throws -> UserFeeling {
        let checkpoint = await privacyActor.validate(operation: .awakening, traceID: traceID)
        guard checkpoint.isAllowed else { throw MemoryFeelingError.privacyDenied }
        return try await feelingStore.createWithInteractionAudit(
            memoryID: memoryID,
            text: text,
            cardID: cardID,
            traceID: traceID
        )
    }

    public func record(
        action: AwakeningCardAction,
        cardID: UUID,
        memoryID: UUID,
        traceID: String
    ) async throws {
        let checkpoint = await privacyActor.validate(operation: .awakening, traceID: traceID)
        guard checkpoint.isAllowed else { throw MemoryFeelingError.privacyDenied }
        try await writeAudit(
            action: action,
            cardID: cardID,
            memoryID: memoryID,
            feelingAssociatedToSource: false,
            traceID: traceID,
            policyVersion: checkpoint.policyVersion
        )
    }

    private func writeAudit(
        action: AwakeningCardAction,
        cardID: UUID,
        memoryID: UUID,
        feelingAssociatedToSource: Bool,
        traceID: String,
        policyVersion: Int
    ) async throws {
        try await privacyActor.writeAuditLog(
            eventType: .cardInteraction,
            traceID: traceID,
            policyVersion: policyVersion,
            action: action.rawValue,
            cardIdDigest: AuditContentHasher.sha256Hex(cardID.uuidString.lowercased()),
            memoryIdDigest: AuditContentHasher.sha256Hex(memoryID.uuidString.lowercased()),
            feelingAssociatedToSource: feelingAssociatedToSource
        )
    }
}
