// ==========================================
// File: AwakeningCardInteraction.swift
// Specification: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-005 AC-2/3/5
// Task: 4.0d - Interactive Awakening Card production closure
// AC coverage: AC-2 (stable next), AC-3 (typed Focus route), AC-5 (interaction actions)
// Architecture: ADR-016 D-4/D-5; AGENTS.md R-007/R-008
// Generated: 2026-09-02
// ==========================================

import Foundation

public nonisolated enum AwakeningCardAction: String, Sendable, Codable, Equatable {
    case next
    case record
    case jump
}

public nonisolated struct AwakeningCardNavigator: Sendable, Equatable {
    public let memoryIDs: [UUID]
    public private(set) var index: Int

    public init(memoryIDs: [UUID], index: Int = 0) {
        self.memoryIDs = memoryIDs
        self.index = memoryIDs.isEmpty ? 0 : min(max(index, 0), memoryIDs.count - 1)
    }

    public var currentMemoryID: UUID? {
        memoryIDs.indices.contains(index) ? memoryIDs[index] : nil
    }

    public var canAdvance: Bool {
        memoryIDs.indices.contains(index + 1)
    }

    @discardableResult
    public mutating func advance() -> UUID? {
        guard canAdvance else { return nil }
        index += 1
        return currentMemoryID
    }
}

public nonisolated enum AwakeningFocusRoute: Hashable, Sendable, Identifiable {
    case media(memoryID: UUID, sourceLocator: String)
    case text(memoryID: UUID, sourceLocator: String)
    case voice(memoryID: UUID, sourceLocator: String)
    case unavailable(memoryID: UUID)

    public var memoryID: UUID {
        switch self {
        case .media(let memoryID, _), .text(let memoryID, _), .voice(let memoryID, _),
             .unavailable(let memoryID):
            memoryID
        }
    }

    public var id: String {
        switch self {
        case .media(let memoryID, let locator): "media:\(memoryID):\(locator)"
        case .text(let memoryID, let locator): "text:\(memoryID):\(locator)"
        case .voice(let memoryID, let locator): "voice:\(memoryID):\(locator)"
        case .unavailable(let memoryID): "unavailable:\(memoryID)"
        }
    }

    public static func resolve(
        memoryID: UUID,
        sourceType: String,
        sourceLocator: String
    ) -> AwakeningFocusRoute {
        guard !sourceLocator.isEmpty else { return .unavailable(memoryID: memoryID) }
        switch sourceType.lowercased() {
        case "photo", "video", "video_frame", "video_audio":
            return .media(memoryID: memoryID, sourceLocator: sourceLocator)
        case "voice":
            return .voice(memoryID: memoryID, sourceLocator: sourceLocator)
        case "note", "text":
            return .text(memoryID: memoryID, sourceLocator: sourceLocator)
        default:
            return .unavailable(memoryID: memoryID)
        }
    }
}
