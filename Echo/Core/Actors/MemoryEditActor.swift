// ==========================================
// File: MemoryEditActor.swift
// Spec: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-007
// Task: 4.0e - Memory editing, re-indexing, and persistent conflict closure
// AC coverage: AC-1 through AC-7
// Architecture: AGENTS.md §4.2 (Actor isolation), §7.1 (PrivacyCheckpoint)
// Generated: 2026-09-03
// ==========================================

import Foundation

/// Owns the production edit transaction. Source canonical text is immutable; user fields live
/// in `MemoryUserEdit`, while the published representation and FTS row use effective text.
public actor MemoryEditActor {
    private let db: DatabaseManager
    private let privacyActor: PrivacyActor
    private let generationRegistry: GenerationRegistryActor
    private let embedder: any EmbedderProtocol
    private var activeEditingMemoryIDs: Set<UUID> = []

    public init(
        db: DatabaseManager = .shared,
        privacyActor: PrivacyActor = .shared,
        generationRegistry: GenerationRegistryActor,
        embedder: any EmbedderProtocol
    ) {
        self.db = db
        self.privacyActor = privacyActor
        self.generationRegistry = generationRegistry
        self.embedder = embedder
    }

    public func loadSnapshot(memoryID: UUID, traceID: String) async throws -> MemoryEditSnapshot? {
        let checkpoint = await privacyActor.validate(operation: .search, traceID: traceID)
        guard checkpoint.isAllowed else { throw MemoryEditError.privacyDenied }
        return try await loadSnapshotUnchecked(memoryID: memoryID)
    }

    public func beginEditing(memoryID: UUID, traceID: String) async throws {
        let checkpoint = await privacyActor.validate(operation: .sync, traceID: traceID)
        guard checkpoint.isAllowed else { throw MemoryEditError.privacyDenied }
        guard try await loadSnapshotUnchecked(memoryID: memoryID) != nil else {
            throw MemoryEditError.memoryNotFound
        }
        activeEditingMemoryIDs.insert(memoryID)
    }

    public func cancelEditing(memoryID: UUID, traceID: String) async throws {
        let checkpoint = await privacyActor.validate(operation: .sync, traceID: traceID)
        guard checkpoint.isAllowed else { throw MemoryEditError.privacyDenied }
        activeEditingMemoryIDs.remove(memoryID)
    }

    public func save(_ request: MemoryEditRequest, traceID: String) async throws -> MemoryEditResult {
        let checkpoint = await privacyActor.validate(operation: .sync, traceID: traceID)
        guard checkpoint.isAllowed else { throw MemoryEditError.privacyDenied }
        let result = try await publish(request, traceID: traceID, conflictResolution: nil)
        activeEditingMemoryIDs.remove(request.memoryID)
        return result
    }

    public func handleExternalChange(
        memoryID: UUID,
        externalVersionSummary: String,
        traceID: String
    ) async throws -> ExternalChangeDisposition {
        let checkpoint = await privacyActor.validate(operation: .sync, traceID: traceID)
        guard checkpoint.isAllowed else { throw MemoryEditError.privacyDenied }
        guard let snapshot = try await loadSnapshotUnchecked(memoryID: memoryID) else {
            throw MemoryEditError.memoryNotFound
        }
        if snapshot.memory.userLocked { return .skippedUserLocked }
        guard activeEditingMemoryIDs.contains(memoryID) else { return .proceed }
        try await db.executeWrite(
            sql: """
            INSERT INTO MemoryEditConflict (memoryId, externalVersionSummary, detectedAt)
            VALUES (?, ?, ?)
            ON CONFLICT(memoryId) DO UPDATE SET
                externalVersionSummary = excluded.externalVersionSummary,
                detectedAt = excluded.detectedAt
            """,
            bindings: [
                .text(memoryID.uuidString),
                .text(externalVersionSummary),
                .double(Date().timeIntervalSince1970),
            ]
        )
        return .conflictRecorded
    }

    public func resolveConflict(
        memoryID: UUID,
        resolution: MemoryConflictResolution,
        traceID: String
    ) async throws {
        let checkpoint = await privacyActor.validate(operation: .sync, traceID: traceID)
        guard checkpoint.isAllowed else { throw MemoryEditError.privacyDenied }
        guard let snapshot = try await loadSnapshotUnchecked(memoryID: memoryID) else {
            throw MemoryEditError.memoryNotFound
        }
        guard snapshot.conflict != nil else { throw MemoryEditError.conflictMissing }

        let resolvedWith: String
        switch resolution {
        case .local:
            try await db.executeTransaction([
                .init(sql: "UPDATE Memory SET userLocked = 1, updatedAt = ? WHERE memoryId = ?", bindings: [.double(Date().timeIntervalSince1970), .text(memoryID.uuidString)]),
                .init(sql: "DELETE FROM MemoryEditConflict WHERE memoryId = ?", bindings: [.text(memoryID.uuidString)]),
            ])
            resolvedWith = "local"
        case .external:
            try await db.executeTransaction([
                .init(sql: "DELETE FROM MemoryUserEdit WHERE memoryId = ?", bindings: [.text(memoryID.uuidString)]),
                .init(sql: "DELETE FROM MemoryEditConflict WHERE memoryId = ?", bindings: [.text(memoryID.uuidString)]),
                .init(sql: "UPDATE Memory SET userEdited = 0, userLocked = 0, updatedAt = ? WHERE memoryId = ?", bindings: [.double(Date().timeIntervalSince1970), .text(memoryID.uuidString)]),
                .init(sql: "DELETE FROM MemoryFTS WHERE memoryId = ?", bindings: [.text(memoryID.uuidString)]),
                .init(sql: "INSERT INTO MemoryFTS (memoryId, canonicalText, sourceType) VALUES (?, ?, ?)", bindings: [.text(memoryID.uuidString), snapshot.memory.canonicalText.map(DBBinding.text) ?? .null, .text(snapshot.memory.sourceType)]),
                .init(sql: "DELETE FROM translationCache WHERE memoryId = ?", bindings: [.text(memoryID.uuidString)]),
            ])
            resolvedWith = "external"
        case .merge(let request):
            _ = try await publish(request, traceID: traceID, conflictResolution: "merge")
            try await db.executeTransaction([
                .init(sql: "UPDATE Memory SET userLocked = 1 WHERE memoryId = ?", bindings: [.text(memoryID.uuidString)]),
                .init(sql: "DELETE FROM MemoryEditConflict WHERE memoryId = ?", bindings: [.text(memoryID.uuidString)]),
            ])
            resolvedWith = "merge"
        }
        activeEditingMemoryIDs.remove(memoryID)
        if resolvedWith != "merge" {
            try await writeAudit(
                memoryID: memoryID,
                sourceType: snapshot.memory.sourceType,
                traceID: traceID,
                fields: [],
                reindexed: resolvedWith == "external",
                conflictResolution: resolvedWith
            )
        }
    }

    public func allowExplicitResync(memoryID: UUID, traceID: String) async throws {
        let checkpoint = await privacyActor.validate(operation: .sync, traceID: traceID)
        guard checkpoint.isAllowed else { throw MemoryEditError.privacyDenied }
        try await db.executeWrite(
            sql: "UPDATE Memory SET userLocked = 0 WHERE memoryId = ?",
            bindings: [.text(memoryID.uuidString)]
        )
    }

    private func publish(
        _ request: MemoryEditRequest,
        traceID: String,
        conflictResolution: String?
    ) async throws -> MemoryEditResult {
        guard let previous = try await loadSnapshotUnchecked(memoryID: request.memoryID) else {
            throw MemoryEditError.memoryNotFound
        }
        guard let route = try await generationRegistry.loadActiveRoute(),
              let store = await generationRegistry.vectorStore(for: route.textGeneration) else {
            throw MemoryEditError.routeUnavailable
        }

        let title = Self.normalizedLine(request.title)
        let description = request.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = Self.normalizedTags(request.tags)
        let effectiveText = Self.effectiveText(
            title: title,
            description: description,
            tags: tags,
            canonicalText: previous.memory.canonicalText
        )
        let vector = try await embedder.embedText(effectiveText, context: .passage)
        let contentHash = AuditContentHasher.sha256Hex(effectiveText)
        let representationID = CanonicalMemoryRepositoryActor.deterministicID(
            sourceLocator: "\(request.memoryID.uuidString)|edit|\(contentHash)",
            sourceType: "text_edit"
        )
        let oldTextIDs = try await db.executeQuery(
            sql: "SELECT representationId FROM Representation WHERE memoryId = ? AND modality = ?",
            bindings: [.text(request.memoryID.uuidString), .text(Modality.textDense.rawValue)]
        ).compactMap { $0["representationId"]?.stringValue.flatMap(UUID.init(uuidString:)) }

        try await store.ingest(vector: vector, id: representationID)
        do {
            try await generationRegistry.persistStore(generationId: route.textGeneration)
            let tagsData = try JSONEncoder().encode(tags)
            let tagsJSON = String(decoding: tagsData, as: UTF8.self)
            let now = Date()
            let timestampChanged = request.timestamp != previous.memory.createdAt
            try await db.executeTransaction([
                .init(
                    sql: """
                    INSERT INTO MemoryUserEdit (memoryId, title, description, tagsJSON, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(memoryId) DO UPDATE SET title=excluded.title,
                        description=excluded.description, tagsJSON=excluded.tagsJSON,
                        updatedAt=excluded.updatedAt
                    """,
                    bindings: [.text(request.memoryID.uuidString), .text(title), .text(description), .text(tagsJSON), .double(now.timeIntervalSince1970)]
                ),
                .init(
                    sql: """
                    UPDATE Memory SET createdAt = ?, updatedAt = ?,
                        originalTimestamp = CASE
                            WHEN ? = 1 THEN COALESCE(originalTimestamp, createdAt)
                            ELSE originalTimestamp END,
                        userEdited = 1
                    WHERE memoryId = ?
                    """,
                    bindings: [.double(request.timestamp.timeIntervalSince1970), .double(now.timeIntervalSince1970), .int(timestampChanged ? 1 : 0), .text(request.memoryID.uuidString)]
                ),
                .init(sql: "DELETE FROM Representation WHERE memoryId = ? AND modality = ?", bindings: [.text(request.memoryID.uuidString), .text(Modality.textDense.rawValue)]),
                .init(sql: "INSERT INTO Representation (representationId, memoryId, modality, preprocessVersion, contentHash) VALUES (?, ?, ?, ?, ?)", bindings: [.text(representationID.uuidString), .text(request.memoryID.uuidString), .text(Modality.textDense.rawValue), .text("user-edit/e5-v1"), .text(contentHash)]),
                .init(sql: "DELETE FROM MemoryFTS WHERE memoryId = ?", bindings: [.text(request.memoryID.uuidString)]),
                .init(sql: "INSERT INTO MemoryFTS (memoryId, canonicalText, sourceType) VALUES (?, ?, ?)", bindings: [.text(request.memoryID.uuidString), .text(effectiveText), .text(previous.memory.sourceType)]),
                .init(sql: "DELETE FROM translationCache WHERE memoryId = ?", bindings: [.text(request.memoryID.uuidString)]),
            ])
        } catch {
            _ = await store.delete(id: representationID)
            try? await generationRegistry.persistStore(generationId: route.textGeneration)
            throw error
        }

        for oldID in oldTextIDs where oldID != representationID {
            _ = await store.delete(id: oldID)
        }
        try await generationRegistry.persistStore(generationId: route.textGeneration)
        try await writeAudit(
            memoryID: request.memoryID,
            sourceType: previous.memory.sourceType,
            traceID: traceID,
            fields: Self.editedFields(previous: previous, title: title, description: description, tags: tags, timestamp: request.timestamp),
            reindexed: true,
            conflictResolution: conflictResolution
        )
        guard let snapshot = try await loadSnapshotUnchecked(memoryID: request.memoryID) else {
            throw MemoryEditError.memoryNotFound
        }
        return MemoryEditResult(snapshot: snapshot, effectiveText: effectiveText)
    }

    private func writeAudit(
        memoryID: UUID,
        sourceType: String,
        traceID: String,
        fields: [String],
        reindexed: Bool,
        conflictResolution: String?
    ) async throws {
        let policy = await privacyActor.getPolicy()
        try await privacyActor.writeAuditLog(
            eventType: .memoryEdited,
            traceID: traceID,
            policyVersion: policy.policyVersion,
            sourceType: sourceType,
            memoryIdDigest: AuditContentHasher.sha256Hex(memoryID.uuidString),
            editedFields: fields,
            reindexed: reindexed,
            conflictResolvedWith: conflictResolution
        )
    }

    private func loadSnapshotUnchecked(memoryID: UUID) async throws -> MemoryEditSnapshot? {
        let rows = try await db.executeQuery(
            sql: """
            SELECT m.*, e.title, e.description, e.tagsJSON, e.updatedAt AS editUpdatedAt,
                   c.externalVersionSummary, c.detectedAt
            FROM Memory m
            LEFT JOIN MemoryUserEdit e ON e.memoryId = m.memoryId
            LEFT JOIN MemoryEditConflict c ON c.memoryId = m.memoryId
            WHERE m.memoryId = ?
            """,
            bindings: [.text(memoryID.uuidString)]
        )
        guard let row = rows.first,
              let locator = row["sourceLocator"]?.stringValue,
              let sourceType = row["sourceType"]?.stringValue,
              let createdAt = row["createdAt"]?.doubleValue,
              let updatedAt = row["updatedAt"]?.doubleValue,
              let recoverabilityRaw = row["recoverability"]?.stringValue,
              let recoverability = Recoverability(rawValue: recoverabilityRaw) else { return nil }
        let memory = Memory(
            memoryId: memoryID,
            sourceLocator: locator,
            canonicalText: row["canonicalText"]?.stringValue,
            sourceType: sourceType,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            recoverability: recoverability,
            originalTimestamp: row["originalTimestamp"]?.doubleValue.map(Date.init(timeIntervalSince1970:)),
            userEdited: (row["userEdited"]?.intValue ?? 0) != 0,
            userLocked: (row["userLocked"]?.intValue ?? 0) != 0
        )
        let edit: MemoryUserEdit? = if let title = row["title"]?.stringValue,
                                       let description = row["description"]?.stringValue,
                                       let tagsJSON = row["tagsJSON"]?.stringValue,
                                       let editUpdatedAt = row["editUpdatedAt"]?.doubleValue {
            MemoryUserEdit(
                memoryID: memoryID,
                title: title,
                description: description,
                tags: (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? [],
                updatedAt: Date(timeIntervalSince1970: editUpdatedAt)
            )
        } else { nil }
        let conflict: MemoryEditConflict? = if let summary = row["externalVersionSummary"]?.stringValue,
                                                let detectedAt = row["detectedAt"]?.doubleValue {
            MemoryEditConflict(memoryID: memoryID, externalVersionSummary: summary, detectedAt: Date(timeIntervalSince1970: detectedAt))
        } else { nil }
        return MemoryEditSnapshot(memory: memory, edit: edit, conflict: conflict)
    }

    public nonisolated static func effectiveText(
        title: String,
        description: String,
        tags: [String],
        canonicalText: String?
    ) -> String {
        ([title, description] + tags + [canonicalText ?? ""])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private nonisolated static func normalizedLine(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    public nonisolated static func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.compactMap { raw in
            let value = normalizedLine(raw)
            guard !value.isEmpty else { return nil }
            let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(key).inserted else { return nil }
            return value
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private nonisolated static func editedFields(
        previous: MemoryEditSnapshot,
        title: String,
        description: String,
        tags: [String],
        timestamp: Date
    ) -> [String] {
        var fields: [String] = []
        if previous.edit?.title != title { fields.append("title") }
        if previous.edit?.description != description { fields.append("description") }
        if previous.edit?.tags != tags { fields.append("tags") }
        if previous.memory.createdAt != timestamp { fields.append("timestamp") }
        return fields.sorted()
    }
}
