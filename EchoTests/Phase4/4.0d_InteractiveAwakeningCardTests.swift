// ==========================================
// File: 4.0d_InteractiveAwakeningCardTests.swift
// Specification: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-005
// Task: 4.0d - Interactive Awakening Card production closure
// AC coverage: AC-1 (real media + offline music), AC-2 (stable interactions),
//              AC-3 (typed Focus routing), AC-4 (relational feelings),
//              AC-5 (hash-only structured audit)
// Architecture: ADR-016; AGENTS.md R-001/R-005/R-006/R-007/R-008 and D-005
// Generated: 2026-09-02
// ==========================================

import Foundation
import Testing
@testable import Echo

@Suite("InteractiveAwakeningCardTests", .serialized)
@MainActor
struct InteractiveAwakeningCardTests {
    private let db: DatabaseManager
    private let privacy: PrivacyActor

    init() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-4.0d-\(UUID().uuidString).sqlite")
        db = DatabaseManager(databaseURL: databaseURL)
        privacy = PrivacyActor(db: db)
        try await db.open()
        try await privacy.updatePolicy(UserPolicy(
            preferredLanguage: "en-US",
            authorizedSourceTypes: ["photo", "video", "note", "voice"],
            policyVersion: 40
        ))
    }

    @Test("AC-1: bundled music manifest is complete, metadata-only and deterministic")
    func test_AC1_bundledMusicManifest() throws {
        let url = repositoryRoot.appendingPathComponent(
            "Echo/Resources/MusicOffline/offline-music.json"
        )
        let data = try Data(contentsOf: url)
        let library = try BundledMusicLibrary(data: data)

        #expect(!library.manifest.schemaVersion.isEmpty)
        #expect(!library.manifest.supportedYears.isEmpty)
        #expect(!library.manifest.fallback.isEmpty)
        #expect(!library.manifest.provenance.isEmpty)
        #expect(!library.manifest.license.isEmpty)
        for year in library.manifest.supportedYears {
            #expect(library.manifest.tracks.filter { $0.releaseYear == year }.count == 20)
        }
        #expect(library.manifest.tracks.allSatisfy {
            $0.audioResource == nil && $0.artworkResource == nil && $0.lyrics == nil && $0.url == nil
        })

        let memoryID = UUID(uuidString: "9CBB1048-E8C4-486E-BDB7-FC02D1888192")!
        #expect(library.suggestion(memoryID: memoryID, year: 1999)
            == library.suggestion(memoryID: memoryID, year: 1999))
        #expect(library.suggestion(memoryID: memoryID, year: 1900)?.source == .bundled)
    }

    @Test("AC-1: device matching is opt-in, local-only and falls back safely")
    func test_AC1_deviceMusicOptInAndFallback() async throws {
        let bundled = try BundledMusicLibrary.loadFromBundleOrRepository()
        let provider = DeviceMusicProviderStub(
            authorization: .authorized,
            tracks: [
                DeviceMusicTrack(id: "cloud", title: "Cloud", artist: "Artist", releaseYear: 1999,
                                 isCloudItem: true, isPlayable: true),
                DeviceMusicTrack(id: "local", title: "Local", artist: "Artist", releaseYear: 1999,
                                 isCloudItem: false, isPlayable: true),
            ]
        )
        let service = AwakeningMusicService(library: bundled, deviceProvider: provider)
        let memoryID = UUID()

        let defaultSuggestion = await service.suggestion(
            memoryID: memoryID, year: 1999, matchDeviceMusic: false
        )
        #expect(defaultSuggestion?.source == .bundled)
        #expect(await provider.queryCount == 0)

        let localSuggestion = await service.suggestion(
            memoryID: memoryID, year: 1999, matchDeviceMusic: true
        )
        #expect(localSuggestion?.source == .device)
        #expect(localSuggestion?.title == "Local")
        #expect(localSuggestion?.isPlayable == true)
        #expect(await provider.queryCount == 1)

        await provider.setAuthorization(.denied)
        #expect(await service.suggestion(
            memoryID: memoryID, year: 1999, matchDeviceMusic: true
        )?.source == .bundled)

        let restricted = AwakeningMusicService(
            library: bundled,
            deviceProvider: DeviceMusicProviderStub(authorization: .restricted, tracks: [])
        )
        #expect(await restricted.suggestion(
            memoryID: memoryID, year: 1999, matchDeviceMusic: true
        )?.source == .bundled)

        let empty = AwakeningMusicService(
            library: bundled,
            deviceProvider: DeviceMusicProviderStub(authorization: .authorized, tracks: [])
        )
        #expect(await empty.suggestion(
            memoryID: memoryID, year: 1999, matchDeviceMusic: true
        )?.source == .bundled)

        let failing = AwakeningMusicService(
            library: bundled,
            deviceProvider: DeviceMusicProviderStub(
                authorization: .authorized,
                tracks: [],
                shouldThrow: true
            )
        )
        #expect(await failing.suggestion(
            memoryID: memoryID, year: 1999, matchDeviceMusic: true
        )?.source == .bundled)
    }

    @Test("AC-1: device release dates preserve the year used for matching")
    func test_AC1_deviceReleaseYearMapping() {
        let components = DateComponents(calendar: Calendar(identifier: .gregorian), year: 1999)
        #expect(SystemDeviceMusicLibraryProvider.releaseYear(from: components.date) == 1999)
        #expect(SystemDeviceMusicLibraryProvider.releaseYear(from: nil) == nil)
    }

    @Test("AC-2: next follows stable order and disables at the end")
    func test_AC2_stableNextOrder() {
        let ids = [UUID(), UUID(), UUID()]
        var navigator = AwakeningCardNavigator(memoryIDs: ids)

        #expect(navigator.currentMemoryID == ids[0])
        #expect(navigator.canAdvance)
        #expect(navigator.advance() == ids[1])
        #expect(navigator.advance() == ids[2])
        #expect(!navigator.canAdvance)
        #expect(navigator.advance() == nil)
        #expect(navigator.currentMemoryID == ids[2])
    }

    @Test("AC-3: source types resolve to typed Focus routes")
    func test_AC3_typedFocusRoutes() {
        let memoryID = UUID()
        #expect(AwakeningFocusRoute.resolve(
            memoryID: memoryID, sourceType: "photo", sourceLocator: "asset-1"
        ) == .media(memoryID: memoryID, sourceLocator: "asset-1"))
        #expect(AwakeningFocusRoute.resolve(
            memoryID: memoryID, sourceType: "note", sourceLocator: "note-1"
        ) == .text(memoryID: memoryID, sourceLocator: "note-1"))
        #expect(AwakeningFocusRoute.resolve(
            memoryID: memoryID, sourceType: "voice", sourceLocator: "voice-1"
        ) == .voice(memoryID: memoryID, sourceLocator: "voice-1"))
        #expect(AwakeningFocusRoute.resolve(
            memoryID: memoryID, sourceType: "photo", sourceLocator: ""
        ) == .unavailable(memoryID: memoryID))
    }

    @Test("AC-4: feelings support transactional CRUD and cascade with Memory")
    func test_AC4_feelingCRUDAndCascade() async throws {
        let memoryID = UUID()
        try await insertMemory(memoryID)
        let store = MemoryFeelingActor(db: db, privacyActor: privacy)

        let created = try await store.create(
            memoryID: memoryID, text: "Quietly grateful", traceID: "feeling-create"
        )
        let fetched = try #require(try await store.fetch(memoryID: memoryID).first)
        #expect(fetched.feelingID == created.feelingID)
        #expect(fetched.memoryID == memoryID)
        #expect(fetched.text == "Quietly grateful")

        let updated = try await store.update(
            feelingID: created.feelingID, text: "Grateful", traceID: "feeling-update"
        )
        #expect(updated.text == "Grateful")

        let removable = try await store.create(
            memoryID: memoryID, text: "Temporary", traceID: "feeling-delete-create"
        )
        try await store.delete(
            feelingID: removable.feelingID, traceID: "feeling-delete"
        )
        #expect(try await store.fetch(memoryID: memoryID).map(\.feelingID) == [created.feelingID])

        await #expect(throws: MemoryFeelingError.notFound) {
            try await store.update(
                feelingID: UUID(), text: "Missing", traceID: "feeling-update-missing"
            )
        }
        await #expect(throws: MemoryFeelingError.notFound) {
            try await store.delete(feelingID: UUID(), traceID: "feeling-delete-missing")
        }

        try await db.executeTransaction([
            .init(sql: "DELETE FROM Memory WHERE memoryId = ?", bindings: [.text(memoryID.uuidString)])
        ])
        #expect(try await store.fetch(memoryID: memoryID).isEmpty)
        let excluded = try await db.executeQuery(
            sql: "SELECT * FROM ExcludedAssets WHERE assetId = ?", bindings: [.text("source-\(memoryID)")]
        )
        #expect(excluded.isEmpty)
    }

    @Test("AC-4: feelings persist after the database is closed and reopened")
    func test_AC4_feelingPersistsAcrossRestart() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-4.0d-restart-\(UUID().uuidString).sqlite")
        let firstDB = DatabaseManager(databaseURL: databaseURL)
        let firstPrivacy = PrivacyActor(db: firstDB)
        try await firstDB.open()
        try await firstPrivacy.updatePolicy(UserPolicy(
            preferredLanguage: "en-US",
            authorizedSourceTypes: ["note"],
            policyVersion: 40
        ))
        let memoryID = UUID()
        try await insertMemory(memoryID, into: firstDB)
        let created = try await MemoryFeelingActor(db: firstDB, privacyActor: firstPrivacy).create(
            memoryID: memoryID,
            text: "Still here after restart",
            traceID: "feeling-before-restart"
        )
        await firstDB.close()

        let reopenedDB = DatabaseManager(databaseURL: databaseURL)
        let reopenedPrivacy = PrivacyActor(db: reopenedDB)
        try await reopenedDB.open()
        try await reopenedPrivacy.updatePolicy(UserPolicy(
            preferredLanguage: "en-US",
            authorizedSourceTypes: ["note"],
            policyVersion: 40
        ))
        let restored = try await MemoryFeelingActor(
            db: reopenedDB,
            privacyActor: reopenedPrivacy
        ).fetch(memoryID: memoryID, traceID: "feeling-after-restart")

        #expect(restored.map(\.feelingID) == [created.feelingID])
        #expect(restored.map(\.text) == ["Still here after restart"])
        await reopenedDB.close()
    }

    @Test("AC-4: feeling text never enters memory, FTS, representation or translation cache")
    func test_AC4_feelingIsNotSearchableOrTranslated() async throws {
        let memoryID = UUID()
        try await insertMemory(memoryID)
        let store = MemoryFeelingActor(db: db, privacyActor: privacy)
        let secret = "A feeling that must not be indexed"
        _ = try await store.create(memoryID: memoryID, text: secret, traceID: "feeling-isolation")

        let memoryRows = try await db.executeQuery(
            sql: "SELECT * FROM Memory WHERE canonicalText = ?", bindings: [.text(secret)]
        )
        let ftsRows = try await db.executeQuery(
            sql: "SELECT * FROM MemoryFTS WHERE canonicalText MATCH ?", bindings: [.text("feeling")]
        )
        let representations = try await db.executeQuery(
            sql: "SELECT * FROM Representation WHERE memoryId = ?", bindings: [.text(memoryID.uuidString)]
        )
        let translations = try await db.executeQuery(
            sql: "SELECT * FROM translationCache WHERE memoryId = ?", bindings: [.text(memoryID.uuidString)]
        )

        #expect(memoryRows.isEmpty)
        #expect(ftsRows.isEmpty)
        #expect(representations.isEmpty)
        #expect(translations.isEmpty)
    }

    @Test("AC-5: successful record writes structured hash-only cardInteraction audit")
    func test_AC5_recordAuditIsStructuredAndHashOnly() async throws {
        let memoryID = UUID()
        let cardID = UUID()
        try await insertMemory(memoryID)
        let store = MemoryFeelingActor(db: db, privacyActor: privacy)
        let interactions = AwakeningCardInteractionActor(
            feelingStore: store, privacyActor: privacy
        )
        let rawFeeling = "I want this private"

        _ = try await interactions.recordFeeling(
            rawFeeling, cardID: cardID, memoryID: memoryID, traceID: "record-audit"
        )
        let rows = try await db.executeQuery(
            sql: "SELECT * FROM AuditLog WHERE eventType = 'cardInteraction' AND traceID = ?",
            bindings: [.text("record-audit")]
        )
        let row = try #require(rows.first)
        #expect(row["action"]?.stringValue == "record")
        #expect(row["cardIdDigest"]?.stringValue == AuditContentHasher.sha256Hex(cardID.uuidString.lowercased()))
        #expect(row["memoryIdDigest"]?.stringValue == AuditContentHasher.sha256Hex(memoryID.uuidString.lowercased()))
        #expect(row["feelingAssociatedToSource"]?.intValue == 1)
        #expect(!rows.description.contains(rawFeeling))
    }

    @Test("AC-4/5: feeling and record audit roll back atomically")
    func test_AC4_AC5_recordFeelingAndAuditAreAtomic() async throws {
        let memoryID = UUID()
        try await insertMemory(memoryID)
        try await db.execute(sql: """
            CREATE TRIGGER RejectCardInteractionAudit
            BEFORE INSERT ON AuditLog
            WHEN NEW.eventType = 'cardInteraction'
            BEGIN
                SELECT RAISE(ABORT, 'injected audit failure');
            END
            """)
        let store = MemoryFeelingActor(db: db, privacyActor: privacy)
        let interactions = AwakeningCardInteractionActor(
            feelingStore: store,
            privacyActor: privacy
        )

        await #expect(throws: (any Error).self) {
            try await interactions.recordFeeling(
                "Must roll back",
                cardID: UUID(),
                memoryID: memoryID,
                traceID: "atomic-record"
            )
        }

        #expect(try await store.fetch(memoryID: memoryID).isEmpty)
        let audits = try await db.executeQuery(
            sql: "SELECT * FROM AuditLog WHERE traceID = ? AND action = 'record'",
            bindings: [.text("atomic-record")]
        )
        #expect(audits.isEmpty)
    }

    @Test("AC-5: next and jump audit false association; failed save writes no record audit")
    func test_AC5_allAuditActionsAndFailedSave() async throws {
        let memoryID = UUID()
        let cardID = UUID()
        try await insertMemory(memoryID)
        let store = MemoryFeelingActor(db: db, privacyActor: privacy)
        let interactions = AwakeningCardInteractionActor(
            feelingStore: store,
            privacyActor: privacy
        )

        try await interactions.record(
            action: .next, cardID: cardID, memoryID: memoryID, traceID: "next-audit"
        )
        try await interactions.record(
            action: .jump, cardID: cardID, memoryID: memoryID, traceID: "jump-audit"
        )
        await #expect(throws: (any Error).self) {
            try await interactions.recordFeeling(
                "Cannot attach",
                cardID: cardID,
                memoryID: UUID(),
                traceID: "failed-record-audit"
            )
        }

        let successful = try await db.executeQuery(
            sql: """
                SELECT action, feelingAssociatedToSource
                FROM AuditLog
                WHERE eventType = 'cardInteraction' AND traceID IN (?, ?)
                ORDER BY action
                """,
            bindings: [.text("next-audit"), .text("jump-audit")]
        )
        #expect(successful.map { $0["action"]?.stringValue } == ["jump", "next"])
        #expect(successful.allSatisfy { $0["feelingAssociatedToSource"]?.intValue == 0 })
        let failed = try await db.executeQuery(
            sql: "SELECT * FROM AuditLog WHERE traceID = ? AND action = 'record'",
            bindings: [.text("failed-record-audit")]
        )
        #expect(failed.isEmpty)
    }

    @Test("AC-5: cancelled editor performs no feeling write and no record audit")
    func test_AC5_cancelIsNoOp() async throws {
        let memoryID = UUID()
        try await insertMemory(memoryID)
        let store = MemoryFeelingActor(db: db, privacyActor: privacy)
        let interactions = AwakeningCardInteractionActor(
            feelingStore: store,
            privacyActor: privacy
        )
        let viewModel = HomeViewModel(
            interactionActor: interactions,
            feelingStore: store
        )

        #expect(viewModel.cancelFeelingEditing() == .idle)

        #expect(try await store.fetch(memoryID: memoryID).isEmpty)
        let rows = try await db.executeQuery(
            sql: "SELECT * FROM AuditLog WHERE eventType = 'cardInteraction' AND action = 'record'",
            bindings: []
        )
        #expect(rows.isEmpty)
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Echo/UI/Home/HomeView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("Button(\"Cancel\")"))
        #expect(source.contains("viewModel.cancelFeelingEditing()"))
    }

    @Test("AC-2/3: Home exposes equivalent visible, gesture and accessibility intents")
    func test_AC2_AC3_homeInteractionContract() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Echo/UI/Home/HomeView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("DragGesture"))
        #expect(source.contains("accessibilityAction"))
        #expect(source.contains("awakening-next"))
        #expect(source.contains("awakening-record-feeling"))
        #expect(source.contains("AwakeningFocusRoute"))
        #expect(source.contains("MemoryDetailView(memoryId:"))
        #expect(source.contains("viewModel.interactionErrorMessage"))
        #expect(source.contains("Interaction unavailable"))
        #expect(source.contains("selectedFeeling?.feelingID == feeling.feelingID"))

        let viewModelSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Echo/UI/Home/HomeViewModel.swift"),
            encoding: .utf8
        )
        #expect(viewModelSource.contains("interactionTasks: [UUID: Task<Void, Never>]"))
        #expect(viewModelSource.contains("interactionGenerations: [UUID: UUID]"))
        #expect(viewModelSource.contains("latestInteractionGeneration"))
        #expect(viewModelSource.contains("guard self.isCurrentInteraction"))
    }

    private func insertMemory(_ memoryID: UUID) async throws {
        try await insertMemory(memoryID, into: db)
    }

    private func insertMemory(_ memoryID: UUID, into database: DatabaseManager) async throws {
        try await database.executeWrite(
            sql: """
                INSERT INTO Memory (
                    memoryId, sourceLocator, canonicalText, sourceType,
                    createdAt, updatedAt, recoverability, userEdited, userLocked
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            bindings: [
                .text(memoryID.uuidString), .text("source-\(memoryID.uuidString)"),
                .text("A canonical summary"), .text("note"),
                .double(Date().timeIntervalSince1970), .double(Date().timeIntervalSince1970),
                .text("full"), .int(0), .int(0),
            ]
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private actor DeviceMusicProviderStub: DeviceMusicLibraryProviding {
    private var authorization: DeviceMusicAuthorization
    private let tracks: [DeviceMusicTrack]
    private let shouldThrow: Bool
    private(set) var queryCount = 0

    init(
        authorization: DeviceMusicAuthorization,
        tracks: [DeviceMusicTrack],
        shouldThrow: Bool = false
    ) {
        self.authorization = authorization
        self.tracks = tracks
        self.shouldThrow = shouldThrow
    }

    func requestAuthorization() async -> DeviceMusicAuthorization { authorization }

    func localTracks() async throws -> [DeviceMusicTrack] {
        queryCount += 1
        if shouldThrow { throw CocoaError(.fileReadUnknown) }
        return tracks
    }

    func setAuthorization(_ authorization: DeviceMusicAuthorization) {
        self.authorization = authorization
    }
}
