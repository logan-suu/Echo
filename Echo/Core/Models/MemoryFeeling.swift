// ==========================================
// File: MemoryFeeling.swift
// Specification: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-005 AC-4
// Task: 4.0d - Interactive Awakening Card production closure
// AC coverage: AC-4 (relational, editable, non-searchable user feelings)
// Architecture: ADR-016 D-3; AGENTS.md §4.2 and D-005
// Generated: 2026-09-02
// ==========================================

import Foundation

public nonisolated struct UserFeeling: Identifiable, Sendable, Codable, Equatable {
    public let feelingID: UUID
    public let memoryID: UUID
    public let text: String
    public let createdAt: Date
    public let updatedAt: Date

    public var id: UUID { feelingID }

    public init(
        feelingID: UUID = UUID(),
        memoryID: UUID,
        text: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.feelingID = feelingID
        self.memoryID = memoryID
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public nonisolated enum MemoryFeelingError: Error, Equatable {
    case privacyDenied
    case emptyText
    case textTooLong
    case notFound
    case invalidRow
}

