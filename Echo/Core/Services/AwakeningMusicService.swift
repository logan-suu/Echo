// ==========================================
// File: AwakeningMusicService.swift
// Specification: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-005 AC-1
// Task: 4.0d - Interactive Awakening Card production closure
// AC coverage: AC-1 (deterministic bundled default; opt-in downloaded device music)
// Architecture: ADR-016 D-1/D-2; AGENTS.md R-001/R-005/R-007/R-008
// Generated: 2026-09-02
// ==========================================

@preconcurrency import MediaPlayer
import Foundation

public nonisolated protocol DeviceMusicLibraryProviding: Sendable {
    func requestAuthorization() async -> DeviceMusicAuthorization
    func localTracks() async throws -> [DeviceMusicTrack]
}

public nonisolated struct BundledMusicLibrary: Sendable {
    public let manifest: OfflineMusicManifest

    public init(data: Data) throws {
        manifest = try JSONDecoder().decode(OfflineMusicManifest.self, from: data)
        guard !manifest.schemaVersion.isEmpty,
              !manifest.supportedYears.isEmpty,
              !manifest.fallback.isEmpty,
              !manifest.provenance.isEmpty,
              !manifest.license.isEmpty,
              manifest.supportedYears.allSatisfy({ year in
                  manifest.tracks.filter { $0.releaseYear == year }.count == 20
              }),
              (manifest.tracks + manifest.fallback).allSatisfy({ track in
                  track.audioResource == nil && track.artworkResource == nil
                      && track.lyrics == nil && track.url == nil
              }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    public static func loadFromBundleOrRepository() throws -> BundledMusicLibrary {
        if let url = Bundle.main.url(
            forResource: "offline-music", withExtension: "json", subdirectory: "MusicOffline"
        ) ?? Bundle.main.url(forResource: "offline-music", withExtension: "json") {
            return try BundledMusicLibrary(data: Data(contentsOf: url))
        }
        #if DEBUG
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/MusicOffline/offline-music.json")
        return try BundledMusicLibrary(data: Data(contentsOf: sourceURL))
        #else
        throw CocoaError(.fileNoSuchFile)
        #endif
    }

    public func suggestion(memoryID: UUID, year: Int?) -> MusicSuggestion? {
        let exact = year.flatMap { target in
            manifest.supportedYears.contains(target)
                ? manifest.tracks.filter { $0.releaseYear == target }
                : nil
        }
        let candidates = exact?.isEmpty == false ? exact! : manifest.fallback
        guard !candidates.isEmpty else { return nil }
        let digest = AuditContentHasher.sha256Hex(memoryID.uuidString.lowercased())
        let prefix = String(digest.prefix(16))
        let value = UInt64(prefix, radix: 16) ?? 0
        let track = candidates[Int(value % UInt64(candidates.count))]
        return MusicSuggestion(
            id: track.id,
            title: track.title,
            artist: track.artist,
            releaseYear: track.releaseYear,
            source: .bundled,
            isPlayable: false
        )
    }
}

public actor AwakeningMusicService {
    private let library: BundledMusicLibrary
    private let deviceProvider: any DeviceMusicLibraryProviding

    public init(
        library: BundledMusicLibrary,
        deviceProvider: any DeviceMusicLibraryProviding = SystemDeviceMusicLibraryProvider()
    ) {
        self.library = library
        self.deviceProvider = deviceProvider
    }

    public func suggestion(
        memoryID: UUID,
        year: Int?,
        matchDeviceMusic: Bool
    ) async -> MusicSuggestion? {
        let fallback = library.suggestion(memoryID: memoryID, year: year)
        guard matchDeviceMusic,
              await deviceProvider.requestAuthorization() == .authorized,
              let tracks = try? await deviceProvider.localTracks() else {
            return fallback
        }

        let local = tracks.filter { !$0.isCloudItem && $0.isPlayable }
        let yearMatches = year.map { target in local.filter { $0.releaseYear == target } } ?? []
        let candidates = yearMatches.isEmpty ? local : yearMatches
        guard !candidates.isEmpty else { return fallback }
        let digest = AuditContentHasher.sha256Hex(memoryID.uuidString.lowercased())
        let value = UInt64(String(digest.prefix(16)), radix: 16) ?? 0
        let track = candidates[Int(value % UInt64(candidates.count))]
        return MusicSuggestion(
            id: track.id,
            title: track.title,
            artist: track.artist,
            releaseYear: track.releaseYear,
            source: .device,
            isPlayable: track.isPlayable
        )
    }
}

public actor SystemDeviceMusicLibraryProvider: DeviceMusicLibraryProviding {
    public init() {}

    public func requestAuthorization() async -> DeviceMusicAuthorization {
        let current = await MainActor.run { MPMediaLibrary.authorizationStatus() }
        if current != .notDetermined { return Self.map(current) }
        return await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: Self.map(status))
            }
        }
    }

    public func localTracks() async throws -> [DeviceMusicTrack] {
        await MainActor.run {
            let items = MPMediaQuery.songs().items ?? []
            return items.compactMap { item in
                guard let title = item.title, !title.isEmpty else { return nil }
                let cloud = (item.value(forProperty: MPMediaItemPropertyIsCloudItem) as? NSNumber)?.boolValue
                    ?? false
                let assetURL = item.value(forProperty: MPMediaItemPropertyAssetURL) as? URL
                return DeviceMusicTrack(
                    id: String(item.persistentID),
                    title: title,
                    artist: item.artist ?? String(localized: "Unknown artist"),
                    releaseYear: nil,
                    isCloudItem: cloud,
                    isPlayable: assetURL != nil
                )
            }
        }
    }

    private nonisolated static func map(
        _ status: MPMediaLibraryAuthorizationStatus
    ) -> DeviceMusicAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .restricted
        }
    }
}
