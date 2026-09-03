// ==========================================
// File: OfflineMusic.swift
// Specification: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-005 AC-1
// Task: 4.0d - Interactive Awakening Card production closure
// AC coverage: AC-1 (metadata-only bundled suggestions and local-device enhancement)
// Architecture: ADR-016 D-1/D-2; AGENTS.md R-001/R-005
// Generated: 2026-09-02
// ==========================================

import Foundation

public nonisolated enum MusicSuggestionSource: String, Sendable, Codable, Equatable {
    case bundled
    case device
}

public nonisolated struct OfflineMusicTrack: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let artist: String
    public let releaseYear: Int?
    public let tags: [String]
    public let audioResource: String?
    public let artworkResource: String?
    public let lyrics: String?
    public let url: String?

    public init(
        id: String,
        title: String,
        artist: String,
        releaseYear: Int?,
        tags: [String] = [],
        audioResource: String? = nil,
        artworkResource: String? = nil,
        lyrics: String? = nil,
        url: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.releaseYear = releaseYear
        self.tags = tags
        self.audioResource = audioResource
        self.artworkResource = artworkResource
        self.lyrics = lyrics
        self.url = url
    }
}

public nonisolated struct OfflineMusicManifest: Sendable, Codable, Equatable {
    public let schemaVersion: String
    public let supportedYears: [Int]
    public let provenance: String
    public let license: String
    public let tracks: [OfflineMusicTrack]
    public let fallback: [OfflineMusicTrack]
}

public nonisolated struct MusicSuggestion: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let artist: String
    public let releaseYear: Int?
    public let source: MusicSuggestionSource
    public let isPlayable: Bool
}

public nonisolated enum DeviceMusicAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

public nonisolated struct DeviceMusicTrack: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let artist: String
    public let releaseYear: Int?
    public let isCloudItem: Bool
    public let isPlayable: Bool

    public init(
        id: String,
        title: String,
        artist: String,
        releaseYear: Int?,
        isCloudItem: Bool,
        isPlayable: Bool
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.releaseYear = releaseYear
        self.isCloudItem = isCloudItem
        self.isPlayable = isPlayable
    }
}

