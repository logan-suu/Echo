// ==========================================
// File: DiscoveryLiveDataAdapter.swift
// Specification: docs/01-spec/用户故事与验收标准规格书.md
//                → Home/Search Discovery 展示细则
// Task: 4.0a - Discovery Balanced Canvas with live Home/Search data
// AC coverage: AC-1 (live canonical data), AC-3 (truthful ProgressActor state)
// Architecture: docs/ui/architecture.md §7 (thin read-only adapters)
// Generated: 2026-09-01
// ==========================================

@preconcurrency import Photos
import Foundation

protocol DiscoveryMemoryReading: Sendable {
    func fetchRecentMemories(limit: Int) async throws -> [Memory]
}

extension CanonicalMemoryRepositoryActor: DiscoveryMemoryReading {}

protocol DiscoveryProgressReading: Sendable {
    func loadAll() async throws -> [TaskProgress]
}

extension ProgressActor: DiscoveryProgressReading {}

protocol DiscoveryPolicyReading: Sendable {
    func getPolicy() async -> UserPolicy
}

extension PrivacyActor: DiscoveryPolicyReading {}

nonisolated struct DiscoverySourceReference: Equatable, Sendable {
    let sourceLocator: String
    let sourceType: String
    let summary: String?
}

protocol DiscoverySourceResolving: Sendable {
    func resolve(
        _ references: [DiscoverySourceReference]
    ) async -> [String: DiscoverySourceMetadata]
}

struct LiveDiscoverySourceResolver: DiscoverySourceResolving {
    nonisolated func resolve(
        _ references: [DiscoverySourceReference]
    ) async -> [String: DiscoverySourceMetadata] {
        await MainActor.run {
            var resolved: [String: DiscoverySourceMetadata] = [:]
            let mediaReferences = references.filter { Self.isMedia($0.sourceType) }
            let nonMediaReferences = references.filter { !Self.isMedia($0.sourceType) }

            for reference in nonMediaReferences where !reference.sourceLocator.isEmpty {
                let summary = reference.summary?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if summary?.isEmpty == false {
                    resolved[reference.sourceLocator] = DiscoverySourceMetadata(resolved: true)
                }
            }

            let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard authorization == .authorized || authorization == .limited else {
                return resolved
            }

            let locators = mediaReferences.map(\.sourceLocator).filter { !$0.isEmpty }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: locators, options: nil)
            assets.enumerateObjects { asset, _, _ in
                guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return }
                resolved[asset.localIdentifier] = DiscoverySourceMetadata(
                    resolved: true,
                    aspectRatio: CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
                )
            }
            return resolved
        }
    }

    nonisolated private static func isMedia(_ sourceType: String) -> Bool {
        switch sourceType.lowercased() {
        case "photo", "video", "video_frame": true
        default: false
        }
    }
}

struct HomeDiscoverySnapshot: Equatable, Sendable {
    let cards: [DiscoveryCardPresentation]
    let visibleMemoryCount: Int
    let zeroMemoryState: DiscoveryZeroMemoryState
    let hasAuthorizedSource: Bool
}

protocol HomeDiscoveryServing: Sendable {
    func load(limit: Int) async throws -> HomeDiscoverySnapshot
}

@MainActor
protocol HomeSearchCapabilityServing {
    func isSearchAvailable() async -> Bool
}

@MainActor
struct LiveHomeSearchCapability: HomeSearchCapabilityServing {
    let composition: AppComposition

    init(composition: AppComposition = .shared) {
        self.composition = composition
    }

    func isSearchAvailable() async -> Bool {
        await LiveAppAdapters.makeSearchPipeline(composition: composition) != nil
    }
}

actor HomeDiscoveryAdapter: HomeDiscoveryServing {
    private let memoryReader: any DiscoveryMemoryReading
    private let progressReader: any DiscoveryProgressReading
    private let policyReader: any DiscoveryPolicyReading
    private let sourceResolver: any DiscoverySourceResolving

    init(
        memoryReader: any DiscoveryMemoryReading,
        progressReader: any DiscoveryProgressReading,
        policyReader: any DiscoveryPolicyReading,
        sourceResolver: any DiscoverySourceResolving
    ) {
        self.memoryReader = memoryReader
        self.progressReader = progressReader
        self.policyReader = policyReader
        self.sourceResolver = sourceResolver
    }

    func load(limit: Int) async throws -> HomeDiscoverySnapshot {
        async let memoriesRequest = memoryReader.fetchRecentMemories(limit: limit)
        async let progressRequest = progressReader.loadAll()
        async let policyRequest = policyReader.getPolicy()
        let (memories, progress, policy) = try await (
            memoriesRequest,
            progressRequest,
            policyRequest
        )

        let authorizedMemories = memories.filter { memory in
            policy.isAuthorized(sourceType: Self.policySourceType(for: memory.sourceType))
        }
        let references = authorizedMemories.map {
            DiscoverySourceReference(
                sourceLocator: $0.sourceLocator,
                sourceType: $0.sourceType,
                summary: $0.canonicalText
            )
        }
        let metadata = await sourceResolver.resolve(references)
        let cards = await DiscoveryPresentationMapper.mapMemories(
            authorizedMemories,
            metadataBySourceLocator: metadata
        )
        let hasAuthorizedSource = policy.authorizedSourceTypes.contains { sourceType in
            ["photo", "video", "note", "voice", "text"].contains(sourceType)
        }

        return HomeDiscoverySnapshot(
            cards: cards,
            visibleMemoryCount: cards.count,
            zeroMemoryState: await DiscoveryEmptyStatePolicy.zeroMemoryState(
                activeProgress: progress,
                hasAuthorizedSource: hasAuthorizedSource
            ),
            hasAuthorizedSource: hasAuthorizedSource
        )
    }

    nonisolated private static func policySourceType(for sourceType: String) -> String {
        switch sourceType.lowercased() {
        case "text": "note"
        case "video_frame", "video_audio": "video"
        default: sourceType
        }
    }
}
