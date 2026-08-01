// ==========================================
// 文件: SearchViewModelTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RET-001 AC-3 (结果展示),
//            US-RET-006 AC-2/AC-4 (低置信度横幅), US-FBK-001 AC-1 (👍/👎 按钮),
//            US-FBK-003 AC-1 (Bad Case 标记)
// 任务: 3.2 - SearchView + SearchViewModel 单元测试
// AC 覆盖: US-RET-001 AC-3 ✅, US-RET-006 ✅, US-FBK-001 ✅, US-FBK-003 ✅
// 架构约束: AGENTS.md §8.1 (@MainActor + state enum), §8.2 (状态流转),
//           docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约 — 不保存第二份领域真相)
// 生成时间: 2026-08-01
// ==========================================

import Testing
import Foundation
@testable import Echo

@MainActor
struct SearchViewModelTests {

    // MARK: - Fixture Helpers

    private func makeResultItem(
        id: UUID = UUID(),
        sourceType: String = "photo",
        originalText: String? = nil,
        cosineSimilarity: Float = 0.9,
        lowConfidence: Bool = false,
        timestamp: TimeInterval = 1723507200
    ) -> SearchResultItem {
        SearchResultItem(
            id: id,
            assetId: "asset-\(id.uuidString)",
            sourceType: sourceType,
            timestamp: timestamp,
            originalText: originalText,
            sourceLanguage: originalText == nil ? nil : "zh-Hans",
            crossLanguageMatch: false,
            cosineSimilarity: cosineSimilarity,
            alignmentScore: lowConfidence ? 0.55 : nil,
            feedbackAdjustment: nil,
            lowConfidence: lowConfidence,
            fallbackReason: lowConfidence ? "cross_language_low_alignment" : nil,
            unappliedFilters: []
        )
    }

    // MARK: - RET-001 AC-3: Result display

    @Test("Initial state is idle with empty results")
    func test_AC_RET001_3_initialState() {
        let vm = SearchViewModel()
        #expect(vm.viewState == .idle)
        #expect(vm.results.isEmpty)
        #expect(vm.hasSearched == false)
        #expect(vm.query.isEmpty)
    }

    @Test("loadPreloadedResults maps SearchResultItem to UI models")
    func test_AC_RET001_3_loadPreloadedMapsResults() {
        let vm = SearchViewModel()
        let item = makeResultItem(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sourceType: "note",
            originalText: "昨晚在公园遇到一只橘猫",
            cosineSimilarity: 0.87
        )

        vm.loadPreloadedResults([item])

        #expect(vm.viewState == .completed)
        #expect(vm.hasSearched == true)
        #expect(vm.results.count == 1)
        #expect(vm.results[0].id == item.id)
        #expect(vm.results[0].sourceType == "note")
        #expect(vm.results[0].summary == "昨晚在公园遇到一只橘猫")
        #expect(vm.results[0].similarityPercent == "87%")
    }

    @Test("SearchResultModel summary falls back to type label for media")
    func test_AC_RET001_3_summaryFallback() {
        let vm = SearchViewModel()
        let photoItem = makeResultItem(sourceType: "photo", originalText: nil)

        vm.loadPreloadedResults([photoItem])

        #expect(vm.results[0].summary == "A photo memory")
        #expect(vm.results[0].sourceTypeLabel == "Photo")
    }

    @Test("loadPreloadedResults with empty array gives empty state")
    func test_AC_RET001_3_emptyPreloaded() {
        let vm = SearchViewModel()
        vm.loadPreloadedResults([])

        #expect(vm.viewState == .completed)
        #expect(vm.hasSearched == true)
        #expect(vm.results.isEmpty)
    }

    @Test("clearResults resets to idle state")
    func test_clearResults_resetsState() {
        let vm = SearchViewModel()
        vm.loadPreloadedResults([makeResultItem()])
        #expect(vm.viewState == .completed)

        vm.clearResults()
        #expect(vm.viewState == .idle)
        #expect(vm.results.isEmpty)
        #expect(vm.hasSearched == false)
    }

    // MARK: - RET-006 AC-2/AC-4: Low confidence

    @Test("hasLowConfidence is true when any result is low confidence")
    func test_AC_RET006_2_lowConfidenceFlag() {
        let vm = SearchViewModel()
        let normal = makeResultItem(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let lowConf = makeResultItem(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, lowConfidence: true)

        vm.loadPreloadedResults([normal])
        #expect(vm.hasLowConfidence == false)

        vm.loadPreloadedResults([normal, lowConf])
        #expect(vm.hasLowConfidence == true)
    }

    @Test("Low confidence result preserves fallback reason")
    func test_AC_RET006_4_lowConfidenceFallbackReason() {
        let vm = SearchViewModel()
        let lowConf = makeResultItem(lowConfidence: true)

        vm.loadPreloadedResults([lowConf])

        #expect(vm.results[0].lowConfidence == true)
        #expect(vm.results[0].fallbackReason == "cross_language_low_alignment")
        #expect(vm.results[0].alignmentScore == 0.55)
    }

    // MARK: - FBK-001 AC-1: Like / Dislike buttons

    @Test("recordLike updates local feedback state to liked")
    func test_AC_FBK001_1_recordLike() {
        let vm = SearchViewModel()
        let item = makeResultItem(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        vm.loadPreloadedResults([item])

        vm.recordLike(vm.results[0])

        #expect(vm.feedbackStates[item.id] == .liked)
    }

    @Test("recordDislike updates local feedback state to disliked")
    func test_AC_FBK001_1_recordDislike() {
        let vm = SearchViewModel()
        let item = makeResultItem(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        vm.loadPreloadedResults([item])

        vm.recordDislike(vm.results[0])

        #expect(vm.feedbackStates[item.id] == .disliked)
    }

    @Test("Feedback state is none initially for each result")
    func test_AC_FBK001_1_feedbackNoneInitially() {
        let vm = SearchViewModel()
        let item = makeResultItem(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        vm.loadPreloadedResults([item])

        #expect(vm.feedbackStates[item.id] == .none)
    }

    // MARK: - FBK-003 AC-1: Bad Case marking

    @Test("markBadCase updates local feedback state to badCase")
    func test_AC_FBK003_1_markBadCase() {
        let vm = SearchViewModel()
        let item = makeResultItem(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        vm.loadPreloadedResults([item])

        vm.markBadCase(vm.results[0])

        #expect(vm.feedbackStates[item.id] == .badCase)
    }

    // MARK: - State transitions (AGENTS.md §8.2)

    @Test("submitQuery transitions idle → loading → completed")
    func test_submitQuery_stateTransitions() async {
        let vm = SearchViewModel()
        #expect(vm.viewState == .idle)

        vm.submitQuery("猫")
        #expect(vm.viewState == .loading)
        #expect(vm.query == "猫")

        // Wait for 300ms loading simulation to complete
        try? await Task.sleep(nanoseconds: 500_000_000)

        #expect(vm.viewState == .completed)
        #expect(vm.hasSearched == true)
    }

    @Test("submitQuery ignores empty and whitespace queries")
    func test_submitQuery_ignoresEmpty() {
        let vm = SearchViewModel()
        vm.submitQuery("   ")
        #expect(vm.viewState == .idle)

        vm.submitQuery("")
        #expect(vm.viewState == .idle)
    }

    @Test("retry with no query returns to idle")
    func test_retry_noQuery() {
        let vm = SearchViewModel()
        vm.retry()
        #expect(vm.viewState == .idle)
    }

    @Test("retry resubmits last query")
    func test_retry_resubmitsQuery() {
        let vm = SearchViewModel()
        vm.submitQuery("测试")
        #expect(vm.viewState == .loading)

        vm.cancelSearch()
        #expect(vm.viewState == .cancelled)

        vm.retry()
        #expect(vm.viewState == .loading)
        #expect(vm.query == "测试")
    }

    @Test("cancelSearch sets state to cancelled")
    func test_cancelSearch() {
        let vm = SearchViewModel()
        vm.submitQuery("猫")
        #expect(vm.viewState == .loading)

        vm.cancelSearch()
        #expect(vm.viewState == .cancelled)
    }

    @Test("dismissError resets state to idle")
    func test_dismissError() {
        let vm = SearchViewModel()
        vm.loadPreloadedResults([makeResultItem()])
        #expect(vm.viewState == .completed)

        vm.dismissError()
        #expect(vm.viewState == .idle)
    }

    @Test("submitQuery ignores duplicate calls while loading")
    func test_submitQuery_ignoresDuplicateWhileLoading() {
        let vm = SearchViewModel()
        vm.submitQuery("第一")
        #expect(vm.viewState == .loading)

        vm.submitQuery("第二")
        // Query should not be overwritten while loading
        #expect(vm.query == "第一")
    }

    // MARK: - UI-slice stub mode (fixture persistence)

    @Test("submitQuery in UI-slice mode returns preloaded stub results (fixture not lost)")
    func test_submitQuery_returnsStubResults() async {
        let vm = SearchViewModel()
        vm.loadPreloadedResults([makeResultItem(), makeResultItem(sourceType: "note", originalText: "note text")])
        #expect(vm.results.count == 2)

        vm.submitQuery("猫")
        #expect(vm.viewState == .loading)

        try? await Task.sleep(nanoseconds: 500_000_000)

        #expect(vm.viewState == .completed)
        #expect(vm.results.count == 2, "UI-slice search must keep stub results, not clear them")
    }

    @Test("submitQuery in UI-slice mode with no stub enters empty completed state")
    func test_submitQuery_withoutStub_entersEmpty() async {
        let vm = SearchViewModel()
        vm.submitQuery("nothing")
        #expect(vm.viewState == .loading)

        try? await Task.sleep(nanoseconds: 500_000_000)

        #expect(vm.viewState == .completed)
        #expect(vm.results.isEmpty)
        #expect(vm.hasSearched == true)
    }

    // MARK: - ViewState Equatable

    @Test("ViewState equatable works correctly")
    func test_viewStateEquatable() {
        #expect(SearchViewModel.ViewState.idle == .idle)
        #expect(SearchViewModel.ViewState.loading == .loading)
        #expect(SearchViewModel.ViewState.completed == .completed)
        #expect(SearchViewModel.ViewState.cancelled == .cancelled)
        #expect(SearchViewModel.ViewState.error(.l2Recoverable(message: "a")) != .error(.l2Recoverable(message: "b")))
        #expect(SearchViewModel.ViewState.error(.l2Recoverable(message: "x")) == .error(.l2Recoverable(message: "x")))
    }

    // MARK: - Adapter: no second domain truth

    @Test("SearchResultModel does not modify original Core values")
    func test_adapter_noSecondTruth() {
        let item = makeResultItem(cosineSimilarity: 0.9)
        let model = SearchResultModel(from: item)

        // Adapter only transforms presentation fields; original values preserved
        #expect(model.cosineSimilarity == item.cosineSimilarity)
        #expect(model.id == item.id)
        #expect(model.originalText == item.originalText)
    }

    @Test("SearchResultModel dateDescription formats timestamp")
    func test_dateDescription() {
        let vm = SearchViewModel()
        vm.loadPreloadedResults([makeResultItem(timestamp: 1723507200)])
        #expect(!vm.results[0].dateDescription.isEmpty)
    }

    // MARK: - Error level mapping (AGENTS.md §4.4)

    @Test("L3 SearchError maps to l3Blocking (no retry)")
    func test_errorLevel_L3_mapsToBlocking() {
        let state = SearchViewModel.mapError(SearchError.embeddingFailed(underlying: NSError(domain: "test", code: 1)))
        guard case .error(let level) = state else {
            Issue.record("Expected .error state, got \(state)")
            return
        }
        guard case .l3Blocking = level else {
            Issue.record("L3 error must map to .l3Blocking, got \(level)")
            return
        }
    }

    @Test("L2 SearchError maps to l2Recoverable (retry shown)")
    func test_errorLevel_L2_mapsToRecoverable() {
        let state = SearchViewModel.mapError(SearchError.privacyDenied(sourceTypes: ["photo"]))
        guard case .error(let level) = state else {
            Issue.record("Expected .error state, got \(state)")
            return
        }
        guard case .l2Recoverable = level else {
            Issue.record("L2 error must map to .l2Recoverable, got \(level)")
            return
        }
    }

    @Test("Non-SearchError falls back to l2Recoverable")
    func test_errorLevel_unknownErrorFallsBack() {
        let state = SearchViewModel.mapError(NSError(domain: "unknown", code: -1))
        guard case .error(let level) = state else {
            Issue.record("Expected .error state, got \(state)")
            return
        }
        guard case .l2Recoverable = level else {
            Issue.record("Unknown error must fall back to .l2Recoverable, got \(level)")
            return
        }
    }
}
