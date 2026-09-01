// ==========================================
// File: DiscoveryPresentation.swift
// Specification: docs/01-spec/用户故事与验收标准规格书.md
//                → Home/Search Discovery 展示细则
// Task: 4.0a - Discovery Balanced Canvas with live Home/Search data
// AC coverage: AC-1 (displayable mapping), AC-2 (deterministic layout),
//              AC-3 (truthful empty state), AC-4 (semantic order)
// Architecture: docs/ui/architecture.md §§7-8
// Generated: 2026-09-01
// ==========================================

import Foundation

enum DiscoveryPresentationKind: String, Equatable, Sendable {
    case scanEligible
    case continuousReading
}

enum DiscoveryLayoutMode: Equatable, Sendable {
    case singleColumn
    case adaptiveMasonry
}

struct DiscoveryLayoutEnvironment: Equatable, Sendable {
    let contentWidth: CGFloat
    let usesAccessibilityDynamicType: Bool
    let voiceOverEnabled: Bool
}

enum DiscoveryPresentationRules {
    nonisolated static let maximumScanSummaryLength = 160
    nonisolated static let minimumColumnWidth: CGFloat = 164
    nonisolated static let columnSpacing: CGFloat = 12
    nonisolated static let minimumMasonryContentWidth = (minimumColumnWidth * 2) + columnSpacing

    static func kind(
        sourceType: String,
        sourceResolved: Bool,
        summary: String?
    ) -> DiscoveryPresentationKind {
        let normalizedSourceType = sourceType.lowercased()
        if sourceResolved,
           normalizedSourceType == "photo" || normalizedSourceType == "video" ||
           normalizedSourceType == "video_frame" {
            return .scanEligible
        }

        guard sourceResolved, isIndependentShortSummary(summary) else {
            return .continuousReading
        }
        return .scanEligible
    }

    static func isIndependentShortSummary(_ summary: String?) -> Bool {
        guard let summary else { return false }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximumScanSummaryLength
    }
}

enum DiscoveryLayoutPolicy {
    static func homeMode(
        visibleMemoryCount: Int,
        sectionItemCount: Int,
        environment: DiscoveryLayoutEnvironment
    ) -> DiscoveryLayoutMode {
        guard visibleMemoryCount >= 20, sectionItemCount >= 6 else {
            return .singleColumn
        }
        return environmentAllowsMasonry(environment) ? .adaptiveMasonry : .singleColumn
    }

    static func searchMode(
        presentationKinds: [DiscoveryPresentationKind],
        environment: DiscoveryLayoutEnvironment
    ) -> DiscoveryLayoutMode {
        guard presentationKinds.count >= 6 else { return .singleColumn }
        let scanEligibleCount = presentationKinds.count { $0 == .scanEligible }
        guard scanEligibleCount * 2 > presentationKinds.count else {
            return .singleColumn
        }
        return environmentAllowsMasonry(environment) ? .adaptiveMasonry : .singleColumn
    }

    private static func environmentAllowsMasonry(
        _ environment: DiscoveryLayoutEnvironment
    ) -> Bool {
        environment.contentWidth >= DiscoveryPresentationRules.minimumMasonryContentWidth &&
            !environment.usesAccessibilityDynamicType &&
            !environment.voiceOverEnabled
    }
}

struct DiscoverySourceMetadata: Equatable, Sendable {
    let resolved: Bool
    let aspectRatio: CGFloat?
    let locationLabel: String?

    init(
        resolved: Bool,
        aspectRatio: CGFloat? = nil,
        locationLabel: String? = nil
    ) {
        self.resolved = resolved
        self.aspectRatio = aspectRatio
        self.locationLabel = locationLabel
    }
}

struct DiscoveryCardPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceLocator: String
    let sourceType: String
    let timestamp: TimeInterval
    let summary: String?
    let aspectRatio: CGFloat?
    let locationLabel: String?
    let presentationKind: DiscoveryPresentationKind
    let sourceLanguage: String?
    let crossLanguageMatch: Bool
    let lowConfidence: Bool
}

enum DiscoveryPresentationMapper {
    static func mapSearchResults(
        _ results: [SearchResultItem],
        metadataBySourceLocator: [String: DiscoverySourceMetadata]
    ) -> [DiscoveryCardPresentation] {
        results.compactMap { item in
            guard let metadata = metadataBySourceLocator[item.assetId], metadata.resolved else {
                return nil
            }

            let trimmedSummary = item.originalText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = trimmedSummary.flatMap { $0.isEmpty ? nil : $0 }
            let isMedia = Self.isMediaSource(item.sourceType)
            let hasDisplayContent = isMedia
                ? metadata.aspectRatio.map { $0 > 0 } == true
                : summary != nil
            guard !item.assetId.isEmpty,
                  hasDisplayContent else {
                return nil
            }

            return DiscoveryCardPresentation(
                id: item.id,
                sourceLocator: item.assetId,
                sourceType: item.sourceType,
                timestamp: item.timestamp,
                summary: summary,
                aspectRatio: metadata.aspectRatio,
                locationLabel: metadata.locationLabel,
                presentationKind: DiscoveryPresentationRules.kind(
                    sourceType: item.sourceType,
                    sourceResolved: metadata.resolved,
                    summary: summary
                ),
                sourceLanguage: item.sourceLanguage,
                crossLanguageMatch: item.crossLanguageMatch,
                lowConfidence: item.lowConfidence
            )
        }
    }

    static func mapMemories(
        _ memories: [Memory],
        metadataBySourceLocator: [String: DiscoverySourceMetadata]
    ) -> [DiscoveryCardPresentation] {
        let items = memories.map { memory in
            SearchResultItem(
                id: memory.memoryId,
                assetId: memory.sourceLocator,
                sourceType: memory.sourceType,
                timestamp: (memory.originalTimestamp ?? memory.createdAt).timeIntervalSince1970,
                originalText: memory.canonicalText,
                sourceLanguage: nil,
                crossLanguageMatch: false,
                cosineSimilarity: 0
            )
        }
        return mapSearchResults(items, metadataBySourceLocator: metadataBySourceLocator)
    }

    private static func isMediaSource(_ sourceType: String) -> Bool {
        switch sourceType.lowercased() {
        case "photo", "video", "video_frame": true
        default: false
        }
    }
}

enum DiscoveryZeroMemoryState: Equatable, Sendable {
    case activeScan(processed: Int, total: Int)
    case importGuidance
    case authorizationGuidance
}

enum DiscoveryEmptyStatePolicy {
    static func zeroMemoryState(
        activeProgress: [TaskProgress],
        hasAuthorizedSource: Bool
    ) -> DiscoveryZeroMemoryState {
        if let progress = activeProgress.first(where: Self.isActiveScan) {
            return .activeScan(
                processed: min(progress.lastProcessedIndex, progress.totalCount),
                total: progress.totalCount
            )
        }
        return hasAuthorizedSource ? .importGuidance : .authorizationGuidance
    }

    private static func isActiveScan(_ progress: TaskProgress) -> Bool {
        (progress.taskType == .fullIndex || progress.taskType == .dataSourceSync) &&
            progress.totalCount > 0 &&
            progress.lastProcessedIndex < progress.totalCount
    }
}

struct DiscoveryMasonryPacking: Equatable, Sendable {
    let semanticOrder: [UUID]
    let columns: [[UUID]]

    static func pack(
        ids: [UUID],
        estimatedHeights: [CGFloat],
        columnCount: Int
    ) -> Self {
        guard columnCount > 0 else {
            return Self(semanticOrder: ids, columns: [])
        }

        var columns = Array(repeating: [UUID](), count: columnCount)
        var heights = Array(repeating: CGFloat.zero, count: columnCount)
        for (index, id) in ids.enumerated() {
            let target = heights.enumerated().min { lhs, rhs in
                lhs.element == rhs.element ? lhs.offset < rhs.offset : lhs.element < rhs.element
            }?.offset ?? 0
            columns[target].append(id)
            heights[target] += estimatedHeights.indices.contains(index) ? estimatedHeights[index] : 0
        }
        return Self(semanticOrder: ids, columns: columns)
    }
}
