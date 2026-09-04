// ==========================================
// File: 4.0e_FocusProductionActionsTests.swift
// Spec: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-007
// Task: 4.0e - Memory editing, re-indexing, and persistent conflict closure
// AC coverage: AC-1 through AC-7
// Architecture: AGENTS.md §4.2, §7.1, §9.4
// Generated: 2026-09-03
// ==========================================

import Foundation
import ProximaKit
import Testing
@testable import Echo

private actor EditTestEmbedder: EmbedderProtocol {
    enum Failure: Error { case injected }
    let shouldFail: Bool
    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }
    func embedImage(assetId: String) async throws -> [Float] { [Float](repeating: 0, count: 384) }
    func embedText(_ text: String) async throws -> [Float] {
        if shouldFail { throw Failure.injected }
        return [Float](repeating: Float(text.utf8.count % 17) / 17, count: 384)
    }
}

private actor EditTestService: MemoryEditServicing {
    let snapshot: MemoryEditSnapshot
    private var saveCount = 0

    init(snapshot: MemoryEditSnapshot) {
        self.snapshot = snapshot
    }

    func loadSnapshot(memoryID: UUID, traceID: String) async throws -> MemoryEditSnapshot? {
        snapshot
    }

    func beginEditing(memoryID: UUID, traceID: String) async throws {}

    func save(_ request: MemoryEditRequest, traceID: String) async throws -> MemoryEditResult {
        saveCount += 1
        return MemoryEditResult(snapshot: snapshot, effectiveText: snapshot.memory.canonicalText ?? "")
    }

    func resolveConflict(
        memoryID: UUID,
        resolution: MemoryConflictResolution,
        traceID: String
    ) async throws {}

    func saves() -> Int { saveCount }
}

private actor EditTestSyncLockChecker: MemorySyncLockChecking {
    let locked: Bool
    init(locked: Bool) { self.locked = locked }
    func isMemoryLockedForSync(memoryId: String) async -> Bool { locked }
}

private actor EditTestExternalChangeApplier: MemoryExternalChangeApplying {
    private let db: DatabaseManager
    private var appliedChanges: [PendingMemorySourceChange] = []

    init(db: DatabaseManager) { self.db = db }

    func applyResolvedExternalChange(
        _ change: PendingMemorySourceChange,
        memoryID: UUID,
        traceID: String
    ) async throws {
        appliedChanges.append(change)
        try await db.executeTransaction([
            .init(
                sql: "DELETE FROM MemoryUserEdit WHERE memoryId = ?",
                bindings: [.text(memoryID.uuidString)]
            ),
            .init(
                sql: "DELETE FROM MemoryEditConflict WHERE memoryId = ?",
                bindings: [.text(memoryID.uuidString)]
            ),
            .init(
                sql: "UPDATE Memory SET userEdited = 0, userLocked = 0 WHERE memoryId = ?",
                bindings: [.text(memoryID.uuidString)]
            ),
        ])
    }

    func changes() -> [PendingMemorySourceChange] { appliedChanges }
}

private actor CancellableEditTestService: MemoryEditServicing {
    func loadSnapshot(memoryID: UUID, traceID: String) async throws -> MemoryEditSnapshot? {
        try await Task.sleep(for: .seconds(10))
        return nil
    }

    func beginEditing(memoryID: UUID, traceID: String) async throws {}
    func save(_ request: MemoryEditRequest, traceID: String) async throws -> MemoryEditResult {
        throw CancellationError()
    }
    func resolveConflict(
        memoryID: UUID,
        resolution: MemoryConflictResolution,
        traceID: String
    ) async throws {}
}

private actor ConflictInjectingEditTestEmbedder: EmbedderProtocol {
    private let db: DatabaseManager
    private let memoryID: UUID

    init(db: DatabaseManager, memoryID: UUID) {
        self.db = db
        self.memoryID = memoryID
    }

    func embedImage(assetId: String) async throws -> [Float] {
        [Float](repeating: 0, count: 384)
    }

    func embedText(_ text: String) async throws -> [Float] {
        try await db.executeWrite(
            sql: "INSERT INTO MemoryEditConflict (memoryId, externalVersionSummary, detectedAt) VALUES (?, ?, ?)",
            bindings: [.text(memoryID.uuidString), .text("racing external change"), .double(1_000)]
        )
        return [Float](repeating: Float(text.utf8.count % 17) / 17, count: 384)
    }
}

@Suite("FocusProductionActionsTests", .serialized)
@MainActor
struct FocusProductionActionsTests {
    private func makeSystem(
        failingEmbedder: Bool = false
    ) async throws -> (DatabaseManager, PrivacyActor, GenerationRegistryActor, MemoryEditActor) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-4.0e-\(UUID().uuidString).sqlite")
        let db = DatabaseManager(databaseURL: url)
        try await db.open()
        let privacy = PrivacyActor(
            db: db,
            policy: UserPolicy(authorizedSourceTypes: ["note"], policyVersion: 1)
        )
        let registry = GenerationRegistryActor(db: db)
        try await registry.registerGeneration(
            IndexGeneration(
                generationId: "text_dense/e5-v1",
                indexType: "text_dense",
                dimension: 384
            )
        )
        try await registry.finishShadowBuild("text_dense/e5-v1", counts: 0, validationDigest: nil)
        try await registry.setGenerationState("text_dense/e5-v1", state: .ready)
        _ = try await registry.activateGeneration("text_dense/e5-v1")
        let actor = MemoryEditActor(
            db: db,
            privacyActor: privacy,
            generationRegistry: registry,
            embedder: EditTestEmbedder(shouldFail: failingEmbedder)
        )
        return (db, privacy, registry, actor)
    }

    private func seedMemory(_ db: DatabaseManager, id: UUID, timestamp: Date) async throws {
        try await db.executeWrite(
            sql: """
            INSERT INTO Memory
                (memoryId, sourceLocator, canonicalText, sourceType, createdAt, updatedAt,
                 recoverability, originalTimestamp, userEdited, userLocked)
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 0, 0)
            """,
            bindings: [
                .text(id.uuidString), .text("note://source"), .text("immutable source text"),
                .text("note"), .double(timestamp.timeIntervalSince1970),
                .double(timestamp.timeIntervalSince1970), .text("full"),
            ]
        )
        try await db.executeWrite(
            sql: "INSERT INTO MemoryFTS (memoryId, canonicalText, sourceType) VALUES (?, ?, ?)",
            bindings: [.text(id.uuidString), .text("immutable source text"), .text("note")]
        )
    }

    @Test("AC-1/2: edit relation preserves source and publishes deterministic effective text")
    func editRelationAndEffectiveText() async throws {
        let (db, _, _, actor) = try await makeSystem()
        let id = UUID()
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await seedMemory(db, id: id, timestamp: originalDate)

        let result = try await actor.save(
            MemoryEditRequest(
                memoryID: id,
                title: "  My title  ",
                description: "Line one\nLine two",
                tags: [" Travel ", "travel", "Family"],
                timestamp: originalDate
            ),
            traceID: "edit-ac12"
        )

        #expect(result.effectiveText == "My title\nLine one\nLine two\nFamily\nTravel\nimmutable source text")
        let snapshot = try await actor.loadSnapshot(memoryID: id, traceID: "load-ac12")
        #expect(snapshot?.memory.canonicalText == "immutable source text")
        #expect(snapshot?.edit?.title == "My title")
        #expect(snapshot?.edit?.description == "Line one\nLine two")
        #expect(snapshot?.edit?.tags == ["Family", "Travel"])
        let fts = try await db.executeQuery(
            sql: "SELECT canonicalText FROM MemoryFTS WHERE memoryId = ?",
            bindings: [.text(id.uuidString)]
        )
        #expect(fts.first?["canonicalText"]?.stringValue == result.effectiveText)
    }

    @Test("AC-2/6: timestamp backup is written once and override drives the primary index")
    func timestampBackupWrittenOnce() async throws {
        let (db, _, _, actor) = try await makeSystem()
        let id = UUID()
        let original = Date(timeIntervalSince1970: 100)
        try await seedMemory(db, id: id, timestamp: original)
        try await actor.save(
            MemoryEditRequest(memoryID: id, title: "A", description: "", tags: [], timestamp: Date(timeIntervalSince1970: 200)),
            traceID: "timestamp-1"
        )
        try await actor.save(
            MemoryEditRequest(memoryID: id, title: "B", description: "", tags: [], timestamp: Date(timeIntervalSince1970: 300)),
            traceID: "timestamp-2"
        )
        let snapshot = try await actor.loadSnapshot(memoryID: id, traceID: "timestamp-load")
        #expect(snapshot?.memory.originalTimestamp == original)
        #expect(snapshot?.memory.createdAt == Date(timeIntervalSince1970: 300))
    }

    @Test("AC-2: embedding failure retains the old serviceable version")
    func preparationFailureRollsBack() async throws {
        let (db, _, _, actor) = try await makeSystem(failingEmbedder: true)
        let id = UUID()
        let original = Date(timeIntervalSince1970: 100)
        try await seedMemory(db, id: id, timestamp: original)
        await #expect(throws: EditTestEmbedder.Failure.self) {
            try await actor.save(
                MemoryEditRequest(memoryID: id, title: "New", description: "New", tags: [], timestamp: original),
                traceID: "failure"
            )
        }
        let snapshot = try await actor.loadSnapshot(memoryID: id, traceID: "failure-load")
        #expect(snapshot?.edit == nil)
        #expect(snapshot?.memory.canonicalText == "immutable source text")
        let fts = try await db.executeQuery(
            sql: "SELECT canonicalText FROM MemoryFTS WHERE memoryId = ?",
            bindings: [.text(id.uuidString)]
        )
        #expect(fts.first?["canonicalText"]?.stringValue == "immutable source text")
    }

    @Test("AC-3: a synchronization lock blocks the production save with L4")
    func synchronizationLockBlocksSave() async throws {
        let id = UUID()
        let memory = Memory(
            memoryId: id,
            sourceLocator: "note://source",
            canonicalText: "immutable source text",
            sourceType: "note"
        )
        let service = EditTestService(
            snapshot: MemoryEditSnapshot(memory: memory, edit: nil, conflict: nil)
        )
        let viewModel = MemoryDetailViewModel(
            memoryEditService: service,
            syncLockChecker: EditTestSyncLockChecker(locked: true)
        )

        viewModel.load(memoryId: id)
        for _ in 0..<100 where viewModel.viewState == .loading {
            await Task.yield()
        }
        viewModel.presentEditSheet()
        viewModel.editTitle = "Blocked edit"
        viewModel.saveEdit()
        for _ in 0..<100 where viewModel.viewState == .loading {
            await Task.yield()
        }

        #expect(viewModel.viewState == .error(.l4Conflict(
            message: "This memory is being updated. Please edit it again after synchronization finishes."
        )))
        #expect(await service.saves() == 0)
    }

    @Test("AC-4/5: conflicts persist and local resolution locks future sync")
    func persistentConflictAndLocalResolution() async throws {
        let (db, _, _, actor) = try await makeSystem()
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 100)
        try await seedMemory(db, id: id, timestamp: timestamp)
        try await actor.save(
            MemoryEditRequest(memoryID: id, title: "Local", description: "draft", tags: [], timestamp: timestamp),
            traceID: "conflict-save"
        )
        try await actor.beginEditing(memoryID: id, traceID: "conflict-begin")
        let disposition = try await actor.handleExternalChange(
            memoryID: id,
            externalVersionSummary: "external summary",
            traceID: "conflict-detect"
        )
        #expect(disposition == .conflictRecorded)
        #expect(try await actor.loadSnapshot(memoryID: id, traceID: "conflict-load")?.conflict?.externalVersionSummary == "external summary")

        try await actor.resolveConflict(memoryID: id, resolution: .local, traceID: "conflict-local")
        let resolved = try await actor.loadSnapshot(memoryID: id, traceID: "resolved-load")
        #expect(resolved?.conflict == nil)
        #expect(resolved?.memory.userLocked == true)
        #expect(try await actor.handleExternalChange(memoryID: id, externalVersionSummary: "later", traceID: "locked") == .skippedUserLocked)
    }

    @Test("AC-4: persisted edits are protected and ordinary saves cannot bypass conflict resolution")
    func persistedEditConflictBlocksOrdinarySave() async throws {
        let (db, _, _, actor) = try await makeSystem()
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 100)
        try await seedMemory(db, id: id, timestamp: timestamp)
        _ = try await actor.save(
            MemoryEditRequest(
                memoryID: id,
                title: "Saved edit",
                description: "local",
                tags: [],
                timestamp: timestamp
            ),
            traceID: "saved-edit"
        )
        let pending = PendingMemorySourceChange(
            assetID: "note://source",
            source: "photo",
            changeType: "modified",
            newContentHash: "new-hash",
            hashSkipped: false
        )

        #expect(try await actor.handleExternalChange(
            memoryID: id,
            externalVersionSummary: "external",
            pendingChange: pending,
            traceID: "saved-edit-conflict"
        ) == .conflictRecorded)
        await #expect(throws: MemoryEditError.conflictPending) {
            try await actor.save(
                MemoryEditRequest(
                    memoryID: id,
                    title: "stale overwrite",
                    description: "stale",
                    tags: [],
                    timestamp: timestamp
                ),
                traceID: "blocked-stale-save"
            )
        }
        let snapshot = try await actor.loadSnapshot(memoryID: id, traceID: "protected-load")
        #expect(snapshot?.edit?.title == "Saved edit")
        #expect(snapshot?.conflict?.pendingChange == pending)
    }

    @Test("AC-2/4: a racing conflict cannot remove an already-serviceable identical vector")
    func racingConflictPreservesReusedVector() async throws {
        let (db, privacy, registry, actor) = try await makeSystem()
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 100)
        let request = MemoryEditRequest(
            memoryID: id,
            title: "Stable edit",
            description: "local",
            tags: [],
            timestamp: timestamp
        )
        try await seedMemory(db, id: id, timestamp: timestamp)
        _ = try await actor.save(request, traceID: "seed-identical-vector")
        let route = try #require(try await registry.loadActiveRoute())
        let store = try #require(await registry.vectorStore(for: route.textGeneration))
        let effectiveText = MemoryEditActor.effectiveText(
            title: request.title,
            description: request.description,
            tags: request.tags,
            canonicalText: "immutable source text"
        )
        let vector = [Float](repeating: Float(effectiveText.utf8.count % 17) / 17, count: 384)
        let before = await store.search(query: vector, k: 1)
        let racingActor = MemoryEditActor(
            db: db,
            privacyActor: privacy,
            generationRegistry: registry,
            embedder: ConflictInjectingEditTestEmbedder(db: db, memoryID: id)
        )

        await #expect(throws: MemoryEditError.conflictPending) {
            try await racingActor.save(request, traceID: "racing-conflict")
        }
        let after = await store.search(query: vector, k: 1)
        #expect(!before.isEmpty)
        #expect(after.first?.id == before.first?.id)
    }

    @Test("AC-4: external and merge resolutions persist their selected truth")
    func externalAndMergeResolutions() async throws {
        let (db, _, _, actor) = try await makeSystem()
        let applier = EditTestExternalChangeApplier(db: db)
        try await actor.attachExternalChangeApplier(applier, traceID: "attach-applier")
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 100)
        try await seedMemory(db, id: id, timestamp: timestamp)
        try await actor.beginEditing(memoryID: id, traceID: "begin-external")
        let pending = PendingMemorySourceChange(
            assetID: "note://source",
            source: "photo",
            changeType: "modified",
            newContentHash: "external-hash",
            hashSkipped: false
        )
        _ = try await actor.handleExternalChange(
            memoryID: id,
            externalVersionSummary: "external",
            pendingChange: pending,
            traceID: "detect-external"
        )
        try await actor.resolveConflict(memoryID: id, resolution: .external, traceID: "resolve-external")
        #expect(try await actor.loadSnapshot(memoryID: id, traceID: "load-external")?.edit == nil)
        #expect(await applier.changes() == [pending])

        try await actor.beginEditing(memoryID: id, traceID: "begin-merge")
        _ = try await actor.handleExternalChange(memoryID: id, externalVersionSummary: "external 2", traceID: "detect-merge")
        try await actor.resolveConflict(
            memoryID: id,
            resolution: .merge(MemoryEditRequest(memoryID: id, title: "Merged", description: "body", tags: ["one"], timestamp: timestamp)),
            traceID: "resolve-merge"
        )
        let merged = try await actor.loadSnapshot(memoryID: id, traceID: "load-merge")
        #expect(merged?.edit?.title == "Merged")
        #expect(merged?.memory.userLocked == true)
    }

    @Test("Regression: cancelling a production edit-service load stays cancelled")
    func cancelledEditServiceLoadStaysCancelled() async {
        let viewModel = MemoryDetailViewModel(memoryEditService: CancellableEditTestService())
        viewModel.load(memoryId: UUID())
        await Task.yield()
        viewModel.onDisappear()
        for _ in 0..<100 where viewModel.viewState == .loading {
            await Task.yield()
        }
        #expect(viewModel.viewState == .cancelled)
    }

    @Test("AC-7: audit fields are structured and identifiers are digests")
    func structuredAudit() async throws {
        let (db, privacy, _, actor) = try await makeSystem()
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 100)
        try await seedMemory(db, id: id, timestamp: timestamp)
        try await actor.save(
            MemoryEditRequest(memoryID: id, title: "Audit", description: "body", tags: ["tag"], timestamp: timestamp),
            traceID: "audit-edit"
        )
        let logs = try await privacy.fetchAuditLogs(eventType: .memoryEdited)
        let log = try #require(logs.first)
        #expect(log.editedFields == ["description", "tags", "title"])
        #expect(log.reindexed == true)
        #expect(log.conflictResolvedWith == nil)
        #expect(log.memoryIdDigest != nil)
        #expect(log.memoryIdDigest != id.uuidString)
    }
}
