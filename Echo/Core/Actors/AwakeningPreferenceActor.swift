// ==========================================
// File: AwakeningPreferenceActor.swift
// Spec: docs/decisions/ADR-018-progressive-permission-orchestration.md
// Task: 4.0f - Progressive permissions and first-run production flow
// AC coverage: AC-3 persisted awakening preferences; AC-4 independent delivery opt-in;
//              AC-6 HealthKit request lifecycle without inferred read authorization
// Architecture: AGENTS.md §4.2 (actor isolation), §5.1 (SQLite through DatabaseManager)
// Generated: 2026-09-04
// ==========================================

import Foundation

public nonisolated enum HealthRequestState: String, Sendable, Equatable {
    case notRequested
    case requestCompleted
    case unsupported
}

public nonisolated enum HealthDataState: String, Sendable, Equatable {
    case samplesAvailable
    case noReadableSamples
    case unavailable
}

public nonisolated struct AwakeningPreferences: Sendable, Equatable {
    public let geofenceEnabled: Bool
    public let emotionEnabled: Bool
    public let anniversaryEnabled: Bool
    public let notificationDeliveryEnabled: Bool
    public let healthRequestState: HealthRequestState

    public static let defaults = AwakeningPreferences(
        geofenceEnabled: false,
        emotionEnabled: false,
        anniversaryEnabled: false,
        notificationDeliveryEnabled: false,
        healthRequestState: .notRequested
    )
}

public actor AwakeningPreferenceActor {
    public static let shared = AwakeningPreferenceActor()

    private let db: DatabaseManager

    public init(db: DatabaseManager = .shared) {
        self.db = db
    }

    public func load() async throws -> AwakeningPreferences {
        let rows = try await db.executeQuery(
            sql: """
                SELECT geofenceEnabled, emotionEnabled, anniversaryEnabled,
                       notificationDeliveryEnabled, healthRequestState
                FROM AwakeningPreference WHERE id = 1
                """,
            bindings: []
        )
        guard let row = rows.first else { return .defaults }
        return AwakeningPreferences(
            geofenceEnabled: (row["geofenceEnabled"]?.intValue ?? 0) != 0,
            emotionEnabled: (row["emotionEnabled"]?.intValue ?? 0) != 0,
            anniversaryEnabled: (row["anniversaryEnabled"]?.intValue ?? 0) != 0,
            notificationDeliveryEnabled: (row["notificationDeliveryEnabled"]?.intValue ?? 0) != 0,
            healthRequestState: HealthRequestState(
                rawValue: row["healthRequestState"]?.stringValue ?? ""
            ) ?? .notRequested
        )
    }

    public func setGeofenceEnabled(_ enabled: Bool) async throws {
        try await update(column: "geofenceEnabled", value: .int(enabled ? 1 : 0))
    }

    public func setEmotionEnabled(_ enabled: Bool) async throws {
        try await update(column: "emotionEnabled", value: .int(enabled ? 1 : 0))
    }

    public func setAnniversaryEnabled(_ enabled: Bool) async throws {
        try await update(column: "anniversaryEnabled", value: .int(enabled ? 1 : 0))
    }

    public func setNotificationDeliveryEnabled(_ enabled: Bool) async throws {
        try await update(column: "notificationDeliveryEnabled", value: .int(enabled ? 1 : 0))
    }

    public func setHealthRequestState(_ state: HealthRequestState) async throws {
        try await update(column: "healthRequestState", value: .text(state.rawValue))
    }

    private func update(column: String, value: DBBinding) async throws {
        let current = try await load()
        try await db.executeWrite(
            sql: """
                INSERT OR REPLACE INTO AwakeningPreference (
                    id, geofenceEnabled, emotionEnabled, anniversaryEnabled,
                    notificationDeliveryEnabled, healthRequestState, updatedAt
                ) VALUES (1, ?, ?, ?, ?, ?, ?)
                """,
            bindings: [
                column == "geofenceEnabled" ? value : .int(current.geofenceEnabled ? 1 : 0),
                column == "emotionEnabled" ? value : .int(current.emotionEnabled ? 1 : 0),
                column == "anniversaryEnabled" ? value : .int(current.anniversaryEnabled ? 1 : 0),
                column == "notificationDeliveryEnabled" ? value : .int(current.notificationDeliveryEnabled ? 1 : 0),
                column == "healthRequestState" ? value : .text(current.healthRequestState.rawValue),
                .double(Date().timeIntervalSince1970),
            ]
        )
    }
}
