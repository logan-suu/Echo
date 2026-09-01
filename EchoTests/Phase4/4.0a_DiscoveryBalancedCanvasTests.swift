// ==========================================
// File: 4.0a_DiscoveryBalancedCanvasTests.swift
// Specification: docs/01-spec/用户故事与验收标准规格书.md
//                 → Home/Search Discovery 展示细则
// Task: 4.0a - Discovery Balanced Canvas with live Home/Search data
// AC coverage: AC-1 (displayable live-data mapping), AC-2 (deterministic
//              layout eligibility), AC-3 (truthful empty progress),
//              AC-4 (stable identity/order and accessibility fallback),
//              AC-5 (US-PRV-001 AC-7 search-operation compatibility)
// Architecture: docs/ui/architecture.md §§7-8
// Generated: 2026-09-01
// ==========================================

import Foundation
import Testing
@testable import Echo

@Suite("DiscoveryBalancedCanvasTests", .serialized)
@MainActor
struct DiscoveryBalancedCanvasTests {
    @Test("AC-1: presentation kind uses source resolution and the exact 160-character boundary")
    func test_AC1_presentationKindBoundary() {
        #expect(
            DiscoveryPresentationRules.kind(
                sourceType: "photo",
                sourceResolved: true,
                summary: nil
            ) == .scanEligible
        )
        #expect(
            DiscoveryPresentationRules.kind(
                sourceType: "photo",
                sourceResolved: false,
                summary: nil
            ) == .continuousReading
        )
        #expect(
            DiscoveryPresentationRules.kind(
                sourceType: "note",
                sourceResolved: true,
                summary: String(repeating: "记", count: 160)
            ) == .scanEligible
        )
        #expect(
            DiscoveryPresentationRules.kind(
                sourceType: "note",
                sourceResolved: true,
                summary: String(repeating: "记", count: 161)
            ) == .continuousReading
        )
        #expect(
            DiscoveryPresentationRules.kind(
                sourceType: "voice",
                sourceResolved: true,
                summary: "   "
            ) == .continuousReading
        )
    }

    @Test("AC-1: displayable mapping drops unresolved sources without changing surviving identity or order")
    func test_AC1_displayableMappingPreservesIdentityAndOrder() {
        let firstID = UUID()
        let missingID = UUID()
        let lastID = UUID()
        let results = [
            makeResult(id: firstID, assetID: "photo-1", sourceType: "photo", text: nil),
            makeResult(id: missingID, assetID: "photo-missing", sourceType: "photo", text: nil),
            makeResult(id: lastID, assetID: "note-1", sourceType: "note", text: "A concise memory"),
        ]
        let metadata = [
            "photo-1": DiscoverySourceMetadata(resolved: true, aspectRatio: 4.0 / 3.0),
            "photo-missing": DiscoverySourceMetadata(resolved: false),
            "note-1": DiscoverySourceMetadata(resolved: true),
        ]

        let mapped = DiscoveryPresentationMapper.mapSearchResults(
            results,
            metadataBySourceLocator: metadata
        )

        #expect(mapped.map(\.id) == [firstID, lastID])
        #expect(mapped.map(\.sourceLocator) == ["photo-1", "note-1"])
        #expect(abs((mapped[0].aspectRatio ?? 0) - (4.0 / 3.0)) < 0.0001)
        #expect(mapped[1].presentationKind == .scanEligible)
    }

    @Test("AC-2: Home requires 20 visible memories, 6 section cards and the exact width gate")
    func test_AC2_homeLayoutEligibility() {
        #expect(
            DiscoveryLayoutPolicy.homeMode(
                visibleMemoryCount: 19,
                sectionItemCount: 6,
                environment: eligibleEnvironment
            ) == .singleColumn
        )
        #expect(
            DiscoveryLayoutPolicy.homeMode(
                visibleMemoryCount: 20,
                sectionItemCount: 5,
                environment: eligibleEnvironment
            ) == .singleColumn
        )
        #expect(
            DiscoveryLayoutPolicy.homeMode(
                visibleMemoryCount: 20,
                sectionItemCount: 6,
                environment: eligibleEnvironment
            ) == .adaptiveMasonry
        )
        #expect(
            DiscoveryLayoutPolicy.homeMode(
                visibleMemoryCount: 20,
                sectionItemCount: 6,
                environment: .init(
                    contentWidth: 339,
                    usesAccessibilityDynamicType: false,
                    voiceOverEnabled: false
                )
            ) == .singleColumn
        )
    }

    @Test("AC-2: Search requires at least 6 items and a strict scanEligible majority")
    func test_AC2_searchLayoutEligibility() {
        #expect(
            DiscoveryLayoutPolicy.searchMode(
                presentationKinds: Array(repeating: .scanEligible, count: 5),
                environment: eligibleEnvironment
            ) == .singleColumn
        )
        #expect(
            DiscoveryLayoutPolicy.searchMode(
                presentationKinds: [
                    .scanEligible, .scanEligible, .scanEligible,
                    .continuousReading, .continuousReading, .continuousReading,
                ],
                environment: eligibleEnvironment
            ) == .singleColumn
        )
        #expect(
            DiscoveryLayoutPolicy.searchMode(
                presentationKinds: [
                    .scanEligible, .scanEligible, .scanEligible, .scanEligible,
                    .continuousReading, .continuousReading,
                ],
                environment: eligibleEnvironment
            ) == .adaptiveMasonry
        )
    }

    @Test("AC-2: Accessibility Dynamic Type and VoiceOver force a stable single column")
    func test_AC2_accessibilityFallback() {
        let kinds = Array(repeating: DiscoveryPresentationKind.scanEligible, count: 6)

        #expect(
            DiscoveryLayoutPolicy.searchMode(
                presentationKinds: kinds,
                environment: .init(
                    contentWidth: 340,
                    usesAccessibilityDynamicType: true,
                    voiceOverEnabled: false
                )
            ) == .singleColumn
        )
        #expect(
            DiscoveryLayoutPolicy.searchMode(
                presentationKinds: kinds,
                environment: .init(
                    contentWidth: 340,
                    usesAccessibilityDynamicType: false,
                    voiceOverEnabled: true
                )
            ) == .singleColumn
        )
    }

    @Test("AC-3: zero-memory state shows progress only for a real active scan")
    func test_AC3_truthfulZeroMemoryState() {
        let active = TaskProgress(
            taskId: "scan-1",
            taskType: .fullIndex,
            lastProcessedIndex: 32,
            totalCount: 128
        )

        #expect(
            DiscoveryEmptyStatePolicy.zeroMemoryState(
                activeProgress: [active],
                hasAuthorizedSource: true
            ) == .activeScan(processed: 32, total: 128)
        )
        #expect(
            DiscoveryEmptyStatePolicy.zeroMemoryState(
                activeProgress: [],
                hasAuthorizedSource: true
            ) == .importGuidance
        )
        #expect(
            DiscoveryEmptyStatePolicy.zeroMemoryState(
                activeProgress: [],
                hasAuthorizedSource: false
            ) == .authorizationGuidance
        )
    }

    @Test("AC-3: Home adapter consumes policy, canonical memory, source metadata and real progress")
    func test_AC3_homeAdapterUsesOnlyAuthorizedResolvableLiveData() async throws {
        let photoID = UUID()
        let deniedID = UUID()
        let missingID = UUID()
        let memories = [
            Memory(memoryId: photoID, sourceLocator: "photo-live", sourceType: "photo"),
            Memory(memoryId: deniedID, sourceLocator: "third-party", canonicalText: "Denied", sourceType: "thirdParty"),
            Memory(memoryId: missingID, sourceLocator: "photo-missing", sourceType: "photo"),
        ]
        let progress = TaskProgress(
            taskId: "scan-live",
            taskType: .fullIndex,
            lastProcessedIndex: 8,
            totalCount: 40
        )
        let adapter = HomeDiscoveryAdapter(
            memoryReader: FakeMemoryReader(memories: memories),
            progressReader: FakeProgressReader(progress: [progress]),
            policyReader: FakePolicyReader(
                policy: UserPolicy(authorizedSourceTypes: ["photo", "note", "voice", "video"])
            ),
            sourceResolver: FakeSourceResolver(metadata: [
                "photo-live": DiscoverySourceMetadata(resolved: true, aspectRatio: 3.0 / 2.0),
                "third-party": DiscoverySourceMetadata(resolved: true),
                "photo-missing": DiscoverySourceMetadata(resolved: false),
            ])
        )

        let snapshot = try await adapter.load(limit: 50)

        #expect(snapshot.cards.map(\.id) == [photoID])
        #expect(snapshot.visibleMemoryCount == 1)
        #expect(snapshot.zeroMemoryState == .activeScan(processed: 8, total: 40))
        #expect(snapshot.hasAuthorizedSource)
    }

    @Test("AC-3: a third-party-only policy is authorized import guidance")
    func test_AC3_thirdPartyOnlyPolicyIsAuthorized() async throws {
        let adapter = HomeDiscoveryAdapter(
            memoryReader: FakeMemoryReader(memories: []),
            progressReader: FakeProgressReader(progress: []),
            policyReader: FakePolicyReader(
                policy: UserPolicy(authorizedSourceTypes: ["thirdParty"])
            ),
            sourceResolver: FakeSourceResolver(metadata: [:])
        )

        let snapshot = try await adapter.load(limit: 50)

        #expect(snapshot.hasAuthorizedSource)
        #expect(snapshot.zeroMemoryState == .importGuidance)
    }

    @Test("AC-4: cancelling during source resolution cannot publish completed results")
    @MainActor
    func test_AC4_cancelledSourceResolutionDoesNotCompleteSearch() async throws {
        let database = DatabaseManager.shared
        try await database.open()
        let privacy = PrivacyActor(db: database)
        try await privacy.loadPolicy()
        let originalPolicy = await privacy.getPolicy()
        try await privacy.updatePolicy(UserPolicy(
            authorizedSourceTypes: ["photo", "note"],
            policyVersion: originalPolicy.policyVersion + 1
        ))
        let resolver = ControlledSourceResolver()
        let viewModel = SearchViewModel(
            searchPipeline: SearchPipeline(
                embedder: StubEmbedder(),
                privacyActor: privacy,
                vectorStore: VectorStoreActor(dimension: 512)
            ),
            composition: nil,
            sourceResolver: resolver
        )

        viewModel.submitQuery("Waterfall")
        await resolver.waitUntilStarted()
        viewModel.onDisappear()
        await resolver.complete()
        for _ in 0..<100 where viewModel.viewState == .cancelled {
            await Task.yield()
        }

        #expect(viewModel.viewState == .cancelled)
        #expect(viewModel.results.isEmpty)
        try await privacy.updatePolicy(originalPolicy)
    }

    @Test("AC-4: cancelling Home discovery cannot publish a partial snapshot")
    @MainActor
    func test_AC4_cancelledHomeDiscoveryDoesNotPublishSnapshot() async {
        let card = DiscoveryCardPresentation(
            id: UUID(),
            sourceLocator: "note-cancelled",
            sourceType: "note",
            timestamp: 1_700_000_000,
            summary: "Must not publish",
            aspectRatio: nil,
            locationLabel: nil,
            presentationKind: .scanEligible,
            sourceLanguage: "en-US",
            crossLanguageMatch: false,
            lowConfidence: false
        )
        let service = ControlledHomeDiscoveryService(
            snapshot: HomeDiscoverySnapshot(
                cards: [card],
                visibleMemoryCount: 1,
                zeroMemoryState: .importGuidance,
                hasAuthorizedSource: true
            )
        )
        let viewModel = HomeViewModel(
            discoveryAdapter: service,
            searchCapability: FakeHomeSearchCapability(available: true)
        )

        viewModel.loadAwakeningCards()
        await service.waitUntilStarted()
        viewModel.onDisappear()
        await service.complete()
        for _ in 0..<100 where viewModel.viewState == .cancelled {
            await Task.yield()
        }

        #expect(viewModel.viewState == .cancelled)
        #expect(viewModel.discoveryCards.isEmpty)
        #expect(viewModel.visibleMemoryCount == 0)
        #expect(!viewModel.canOfferSearchSuggestions)
    }

    @Test("AC-4: masonry packing never mutates semantic item order")
    func test_AC4_semanticOrderIsIndependentFromPacking() {
        let ids = (1...8).map { _ in UUID() }
        let packed = DiscoveryMasonryPacking.pack(
            ids: ids,
            estimatedHeights: [220, 140, 180, 260, 130, 200, 170, 150],
            columnCount: 2
        )

        #expect(packed.semanticOrder == ids)
        #expect(Set(packed.columns.flatMap { $0 }) == Set(ids))
        #expect(packed.columns.flatMap { $0 }.count == ids.count)
    }

    @Test("AC-4: Ask Echo suggestions require a live Search capability and carry an executable query")
    func test_AC4_askEchoCapabilityAndRoute() async {
        let card = DiscoveryCardPresentation(
            id: UUID(),
            sourceLocator: "note-live",
            sourceType: "note",
            timestamp: 1_700_000_000,
            summary: "A live memory",
            aspectRatio: nil,
            locationLabel: nil,
            presentationKind: .scanEligible,
            sourceLanguage: "en-US",
            crossLanguageMatch: false,
            lowConfidence: false
        )
        let viewModel = HomeViewModel(
            discoveryAdapter: FakeHomeDiscoveryService(
                snapshot: HomeDiscoverySnapshot(
                    cards: [card],
                    visibleMemoryCount: 1,
                    zeroMemoryState: .importGuidance,
                    hasAuthorizedSource: true
                )
            ),
            searchCapability: FakeHomeSearchCapability(available: true)
        )

        viewModel.loadAwakeningCards()
        for _ in 0..<100 where viewModel.viewState == .loading {
            await Task.yield()
        }

        let suggestion = viewModel.searchSuggestions.first
        #expect(suggestion?.queryKey == "memories from this month")

        let appViewModel = AppViewModel()
        appViewModel.openSearch(query: suggestion?.queryKey ?? "")
        #expect(appViewModel.selectedTab == .search)
        #expect(appViewModel.consumePendingSearchQuery() == "memories from this month")
        #expect(appViewModel.consumePendingSearchQuery() == nil)
    }

    @Test("AC-5: a legacy policy without the search pseudo-source still permits per-source search")
    func test_AC5_searchOperationDoesNotRequirePseudoSource() async throws {
        let database = DatabaseManager.shared
        try await database.open()
        let privacy = PrivacyActor(db: database)
        try await privacy.loadPolicy()
        let originalPolicy = await privacy.getPolicy()
        let legacyPolicy = UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note"],
            policyVersion: 1
        )

        do {
            try await privacy.updatePolicy(legacyPolicy)
            let pipeline = SearchPipeline(
                embedder: StubEmbedder(),
                privacyActor: privacy,
                vectorStore: VectorStoreActor(dimension: 512)
            )

            let results = try await pipeline.search(query: "Waterfall", k: 5)
            let policyAfterSearch = await privacy.getPolicy()

            #expect(results.isEmpty)
            #expect(policyAfterSearch.authorizedSourceTypes == ["photo", "note"])
            #expect(!policyAfterSearch.authorizedSourceTypes.contains("search"))
            #expect(!policyAfterSearch.authorizedSourceTypes.contains("voice"))
            try await privacy.updatePolicy(originalPolicy)
        } catch {
            try? await privacy.updatePolicy(originalPolicy)
            throw error
        }
    }

    private var eligibleEnvironment: DiscoveryLayoutEnvironment {
        .init(
            contentWidth: 340,
            usesAccessibilityDynamicType: false,
            voiceOverEnabled: false
        )
    }

    private func makeResult(
        id: UUID,
        assetID: String,
        sourceType: String,
        text: String?
    ) -> SearchResultItem {
        SearchResultItem(
            id: id,
            assetId: assetID,
            sourceType: sourceType,
            timestamp: 1_700_000_000,
            originalText: text,
            sourceLanguage: "en-US",
            crossLanguageMatch: false,
            cosineSimilarity: 0.91
        )
    }
}

private actor FakeMemoryReader: DiscoveryMemoryReading {
    let memories: [Memory]

    init(memories: [Memory]) {
        self.memories = memories
    }

    func fetchRecentMemories(limit: Int) async throws -> [Memory] {
        Array(memories.prefix(limit))
    }
}

private actor FakeProgressReader: DiscoveryProgressReading {
    let progress: [TaskProgress]

    init(progress: [TaskProgress]) {
        self.progress = progress
    }

    func loadAll() async throws -> [TaskProgress] {
        progress
    }
}

private actor FakePolicyReader: DiscoveryPolicyReading {
    let policy: UserPolicy

    init(policy: UserPolicy) {
        self.policy = policy
    }

    func getPolicy() async -> UserPolicy {
        policy
    }
}

private actor FakeSourceResolver: DiscoverySourceResolving {
    let metadata: [String: DiscoverySourceMetadata]

    init(metadata: [String: DiscoverySourceMetadata]) {
        self.metadata = metadata
    }

    func resolve(
        _ references: [DiscoverySourceReference]
    ) async -> [String: DiscoverySourceMetadata] {
        metadata.filter { key, _ in references.contains { $0.sourceLocator == key } }
    }
}

private actor ControlledSourceResolver: DiscoverySourceResolving {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func resolve(
        _ references: [DiscoverySourceReference]
    ) async -> [String: DiscoverySourceMetadata] {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return [:]
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func complete() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FakeHomeDiscoveryService: HomeDiscoveryServing {
    let snapshot: HomeDiscoverySnapshot

    init(snapshot: HomeDiscoverySnapshot) {
        self.snapshot = snapshot
    }

    func load(limit: Int) async throws -> HomeDiscoverySnapshot {
        snapshot
    }
}

private actor ControlledHomeDiscoveryService: HomeDiscoveryServing {
    private let snapshot: HomeDiscoverySnapshot
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(snapshot: HomeDiscoverySnapshot) {
        self.snapshot = snapshot
    }

    func load(limit: Int) async throws -> HomeDiscoverySnapshot {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return snapshot
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func complete() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private struct FakeHomeSearchCapability: HomeSearchCapabilityServing {
    let available: Bool

    func isSearchAvailable() async -> Bool {
        available
    }
}
