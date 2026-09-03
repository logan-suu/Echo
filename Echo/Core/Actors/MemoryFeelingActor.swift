// ==========================================
// File: MemoryFeelingActor.swift
// Specification: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-005 AC-4
// Task: 4.0d - Interactive Awakening Card production closure
// AC coverage: AC-4 (transactional CRUD, restart persistence, memory cascade)
// Architecture: ADR-016 D-3; AGENTS.md §4.2, R-006/R-008 and D-005
// Generated: 2026-09-02
// ==========================================

import Foundation

public actor MemoryFeelingActor {
    private static let maximumTextLength = 2_000
    private let db: DatabaseManager
    private let privacyActor: PrivacyActor

    public init(
        db: DatabaseManager = .shared,
        privacyActor: PrivacyActor = .shared
    ) {
        self.db = db
        self.privacyActor = privacyActor
    }

    public func create(
        memoryID: UUID,
        text: String,
        traceID: String
    ) async throws -> UserFeeling {
        let checkpoint = await privacyActor.validate(operation: .awakening, traceID: traceID)
        guard checkpoint.isAllowed else { throw MemoryFeelingError.privacyDenied }
        let normalized = try Self.normalized(text)
        let feeling = UserFeeling(memoryID: memoryID, text: normalized)
        _ = try await db.executeWrite(
            sql: """
                INSERT INTO MemoryFeeling (feelingId, memoryId, text, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """,
            bindings: [
                .text(feeling.feelingID.uuidString),
                .text(feeling.memoryID.uuidString),
                .text(feeling.text),
                .double(feeling.createdAt.timeIntervalSince1970),
                .double(feeling.updatedAt.timeIntervalSince1970),
            ]
        )
        return feeling
    }

    public func fetch(memoryID: UUID, traceID: String = UUID().uuidString) async throws -> [UserFeeling] {
        let checkpoint = await privacyActor.validate(operation: .awakening, traceID: traceID)
        guard checkpoint.isAllowed else { throw MemoryFeelingError.privacyDenied }
        let rows = try await db.executeQuery(
            sql: """
                SELECT feelingId, memoryId, text, createdAt, updatedAt
                FROM MemoryFeeling
                WHERE memoryId = ?
                ORDER BY createdAt ASC, feelingId ASC
                """,
            bindings: [.text(memoryID.uuidString)]
        )
        return try rows.map(Self.decode)
    }

    public func update(
        feelingID: UUID,
        text: String,
        traceID: String
    ) async throws -> UserFeeling {
        let checkpoint = await privacyActor.validate(operation: .awakening, traceID: traceID)
        guard checkpoint.isAllowed else { throw MemoryFeelingError.privacyDenied }
        let normalized = try Self.normalized(text)
        let timestamp = Date()
        let changed = try await db.executeWrite(
            sql: "UPDATE MemoryFeeling SET text = ?, updatedAt = ? WHERE feelingId = ?",
            bindings: [
                .text(normalized), .double(timestamp.timeIntervalSince1970),
                .text(feelingID.uuidString),
            ]
        )
        guard changed > 0 else { throw MemoryFeelingError.notFound }
        let rows = try await db.executeQuery(
            sql: """
                SELECT feelingId, memoryId, text, createdAt, updatedAt
                FROM MemoryFeeling WHERE feelingId = ?
                """,
            bindings: [.text(feelingID.uuidString)]
        )
        guard let row = rows.first else { throw MemoryFeelingError.notFound }
        return try Self.decode(row)
    }

    public func delete(
        feelingID: UUID,
        traceID: String
    ) async throws {
        let checkpoint = await privacyActor.validate(operation: .awakening, traceID: traceID)
        guard checkpoint.isAllowed else { throw MemoryFeelingError.privacyDenied }
        let changed = try await db.executeWrite(
            sql: "DELETE FROM MemoryFeeling WHERE feelingId = ?",
            bindings: [.text(feelingID.uuidString)]
        )
        guard changed > 0 else { throw MemoryFeelingError.notFound }
    }

    private nonisolated static func normalized(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw MemoryFeelingError.emptyText }
        guard value.count <= maximumTextLength else { throw MemoryFeelingError.textTooLong }
        return value
    }

    private nonisolated static func decode(_ row: [String: DBValue]) throws -> UserFeeling {
        guard let feelingID = row["feelingId"]?.stringValue.flatMap(UUID.init),
              let memoryID = row["memoryId"]?.stringValue.flatMap(UUID.init),
              let text = row["text"]?.stringValue,
              let createdAt = row["createdAt"]?.doubleValue,
              let updatedAt = row["updatedAt"]?.doubleValue else {
            throw MemoryFeelingError.invalidRow
        }
        return UserFeeling(
            feelingID: feelingID,
            memoryID: memoryID,
            text: text,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
