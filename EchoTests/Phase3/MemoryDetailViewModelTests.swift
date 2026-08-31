// ==========================================
// 文件: MemoryDetailViewModelTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-007, US-DIS-002, US-PRV-004
//            docs/ui/echo-memory-canvas-style.md §3.2 (Focus), docs/ui/architecture.md §6~7
// 任务: 3.3 - MemoryDetailView + ViewModel
// AC 覆盖: US-AWK-007 AC-1/AC-2/AC-4, US-DIS-002 AC-3/AC-4, US-PRV-004 AC-1
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum),
//           docs/ui/architecture.md §7 (Adapter 不保存第二份领域真相)
// 生成时间: 2026-08-01
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - MemoryDetailViewModel Tests

/// US-AWK-007 AC-1: 记忆详情页提供"编辑"入口，允许修改标题、描述、标签、时间戳。
/// US-DIS-002 AC-4: 提供原文/译文切换按钮。
/// US-PRV-004 AC-1: 删除操作触发弹窗，提供"仅从 Echo 移除"/"同时删除原始文件"两个选项。
@Suite("MemoryDetailViewModel", .serialized)
@MainActor
struct MemoryDetailViewModelTests {

    private func makeLoadedVM() -> MemoryDetailViewModel {
        let vm = MemoryDetailViewModel()
        vm.loadPreloaded(MemoryDetailFixtureLoader.load("memory-detail-loaded")!)
        return vm
    }

    /// 3F.9: 生产默认 translationService 已切换为 AppleTranslationService。
    /// fixture 翻译路径（US-DIS-002）显式注入 FixtureTranslationService + 内存缓存保持确定性。
    private func makeFixtureTranslationVM(
        cache: (any TranslationCaching)? = nil
    ) -> MemoryDetailViewModel {
        MemoryDetailViewModel(
            translationService: FixtureTranslationService(),
            translationCache: cache ?? TranslationCache()
        )
    }

    // MARK: - State Transitions

    @Test("AC: idle → loading → completed via load(memoryId:)")
    func loadTransitionsToCompleted() async {
        let vm = MemoryDetailViewModel()
        #expect(vm.isFixtureBacked == false)
        vm.loadPreloaded(MemoryDetailFixtureLoader.load("memory-detail-loaded")!)
        #expect(vm.viewState == .completed)
        #expect(vm.memory != nil)
        #expect(vm.isFixtureBacked == true)
    }

    @Test("AC: load without fixture resolves to L2 error")
    func loadWithoutFixtureErrors() async {
        let vm = MemoryDetailViewModel()
        vm.load(memoryId: UUID())
        try? await Task.sleep(nanoseconds: 350_000_000)
        #expect(vm.viewState == .error(.l2Recoverable(message: "Unable to load this memory. Please try again.")))
    }

    @Test("Cancelled canonical load cannot overwrite the cancelled state")
    func cancelledCanonicalLoadStaysCancelled() async throws {
        try await DatabaseManager.shared.open()
        let vm = MemoryDetailViewModel(canonicalRepository: .shared)

        vm.load(memoryId: UUID())
        vm.onDisappear()
        try await Task.sleep(for: .milliseconds(30))

        #expect(vm.viewState == .cancelled)
    }

    // MARK: - US-DIS-002 Translation

    @Test("US-DIS-002 AC-4: toggleTranslation flips visibility only when locale differs")
    func toggleTranslationOnlyWhenNeeded() {
        let vm = makeLoadedVM()
        // zh-Hans memory + en-US preferred → needsTranslation
        #expect(vm.memory?.needsTranslation == true)
        vm.toggleTranslation()
        #expect(vm.memory?.translationVisible == true)
        vm.toggleTranslation()
        #expect(vm.memory?.translationVisible == false)
    }

    @Test("US-DIS-002 AC-4: toggleTranslation no-op when locale matches preferred")
    func toggleTranslationNoopWhenSameLocale() {
        let vm = MemoryDetailViewModel()
        let sameLocale = MemoryDetailModel(
            id: UUID(),
            assetId: "note-en-1",
            sourceType: "note",
            title: "Summer plans",
            originalText: "A note about summer plans",
            sourceLanguage: "en-US",
            preferredLanguage: "en-US",
            timestamp: Date(timeIntervalSince1970: 1723593600)
        )
        vm.loadPreloaded(sameLocale)
        #expect(vm.memory?.needsTranslation == false)
        vm.toggleTranslation()
        #expect(vm.memory?.translationVisible == false)
    }

    @Test("US-DIS-002 AC-3: low source-language detection confidence retains original + language label")
    func lowConfidenceRetainsOriginal() {
        let vm = MemoryDetailViewModel()
        let lowConf = MemoryDetailModel(
            id: UUID(),
            assetId: "note-zh-6",
            sourceType: "note",
            title: "低置信度",
            originalText: "一段低置信度译文记忆",
            sourceLanguage: "zh-Hans",
            preferredLanguage: "en-US",
            timestamp: Date(timeIntervalSince1970: 1723420800),
            translationVisible: true,
            translatedText: "A low-confidence translation.",
            sourceLanguageConfidence: 0.55
        )
        vm.loadPreloaded(lowConf)
        #expect(vm.memory?.translationVisible == true)
        #expect(vm.memory?.sourceLanguageConfidence ?? 1.0 < 0.9)
    }

    // MARK: - US-DIS-002 On-demand Translation (Task 3.8)

    @Test("US-DIS-002 AC-1/AC-4: toggle triggers on-demand translation on expand (fixture service)")
    func toggleTriggersOnDemandTranslation() async {
        let vm = makeFixtureTranslationVM()
        let model = TranslationFixtureLoader.load("translation-zh-en-high")!
        vm.loadPreloaded(model)

        #expect(vm.memory?.translationVisible == false)
        #expect(vm.memory?.translatedText == nil)

        vm.toggleTranslation()

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(vm.memory?.translationVisible == true)
        #expect(vm.memory?.translatedText?.contains("orange tabby") == true)
        #expect(vm.translationPhase == .translated)
    }

    @Test("US-DIS-002 AC-2: cache-first — second expand after collapse uses cached result without re-fetch")
    func toggleUsesCacheOnSecondExpand() async {
        let cache = TranslationCache()
        let vm = makeFixtureTranslationVM(cache: cache)
        let model = TranslationFixtureLoader.load("translation-zh-en-high")!
        vm.loadPreloaded(model)

        vm.toggleTranslation()
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(vm.memory?.translatedText != nil)
        #expect(await cache.count == 1, "Translation must be written to cache (AC-5)")

        vm.toggleTranslation()
        vm.toggleTranslation()
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(vm.memory?.translatedText?.contains("orange tabby") == true)
        #expect(await cache.count == 1, "Cache must not grow on cache hit")
    }

    @Test("US-DIS-002 AC-1: collapse cancels in-flight translation")
    func collapseCancelsInFlightTranslation() async {
        let vm = makeFixtureTranslationVM()
        let model = TranslationFixtureLoader.load("translation-zh-en-high")!
        vm.loadPreloaded(model)

        vm.toggleTranslation()
        vm.toggleTranslation()

        #expect(vm.memory?.translationVisible == false)
        #expect(vm.translationPhase == .idle)
    }

    @Test("US-DIS-002 AC-3/AC-4: low-confidence fixture resolves with detection confidence <0.9 and retains original")
    func lowConfidenceFixtureKeepsOriginal() async {
        let vm = makeFixtureTranslationVM()
        let model = TranslationFixtureLoader.load("translation-zh-en-low")!
        vm.loadPreloaded(model)

        vm.toggleTranslation()
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(vm.memory?.translationVisible == true)
        #expect(vm.memory?.translatedText != nil)
        #expect(vm.memory?.sourceLanguageConfidence ?? 1.0 < 0.9)
    }

    @Test("US-DIS-002 AC-2: translation service error surfaces L2 error phase (retry available)")
    func translationErrorShowsL2ErrorPhase() async {
        let vm = makeFixtureTranslationVM()
        let model = TranslationFixtureLoader.load("translation-error")!
        vm.loadPreloaded(model)

        vm.toggleTranslation()
        try? await Task.sleep(nanoseconds: 300_000_000)

        if case .error = vm.translationPhase {
            #expect(true)
        } else {
            #expect(Bool(false), "Expected .error translation phase for unmapped text")
        }
        #expect(vm.memory?.translatedText == nil, "Original must be retained on error")
    }

    @Test("US-DIS-002 AC-4: toggleTranslation no-op when translation already cached in model")
    func toggleDoesNotReFetchWhenAlreadyTranslated() async {
        let vm = MemoryDetailViewModel()
        let model = TranslationFixtureLoader.load("translation-zh-en-cached")!
        vm.loadPreloaded(model)

        #expect(vm.memory?.translatedText != nil)
        #expect(vm.translationPhase == .translated)

        vm.toggleTranslation()
        #expect(vm.memory?.translationVisible == false)
        vm.toggleTranslation()
        #expect(vm.memory?.translationVisible == true)
        #expect(vm.memory?.translatedText != nil)
    }

    // MARK: - US-AWK-007 Edit

    @Test("US-AWK-007 AC-1: presentEditSheet pre-fills form from current memory")
    func editSheetPrefillsFields() {
        let vm = makeLoadedVM()
        vm.presentEditSheet()
        #expect(vm.isEditing == true)
        #expect(vm.editTitle == "昨晚的公园散步")
        #expect(vm.editDescription.contains("橘猫"))
        #expect(vm.editTags == "公园, 橘猫")
    }

    @Test("US-AWK-007 AC-1: saveEdit persists edited fields and marks userEdited")
    func saveEditPersistsChanges() {
        let vm = makeLoadedVM()
        vm.presentEditSheet()
        vm.editTitle = "更新的标题"
        vm.editDescription = "更新后的描述"
        vm.editTags = "新标签1, 新标签2"
        vm.saveEdit()
        #expect(vm.isEditing == false)
        #expect(vm.memory?.title == "更新的标题")
        #expect(vm.memory?.originalText == "更新后的描述")
        #expect(vm.memory?.tags == ["新标签1", "新标签2"])
        #expect(vm.memory?.userEdited == true)
    }

    @Test("US-AWK-007 AC-2: saveEdit keeps originalTimestamp unchanged (backup preserved)")
    func saveEditPreservesOriginalTimestamp() {
        let vm = makeLoadedVM()
        let original = vm.memory?.timestamp
        vm.presentEditSheet()
        vm.saveEdit()
        #expect(vm.memory?.timestamp == original)
    }

    @Test("US-AWK-007 AC-1: blank title edit leaves original title")
    func saveEditKeepsTitleWhenBlank() {
        let vm = makeLoadedVM()
        let originalTitle = vm.memory?.title
        vm.presentEditSheet()
        vm.editTitle = "   "
        vm.saveEdit()
        #expect(vm.memory?.title == originalTitle)
    }

    // MARK: - US-AWK-007 Conflict (AC-4)

    @Test("US-AWK-007 AC-4: presentEditSheet blocked when conflict flagged")
    func editBlockedWhenConflict() {
        let vm = MemoryDetailViewModel()
        vm.loadPreloaded(MemoryDetailFixtureLoader.load("memory-detail-conflict")!)
        vm.presentEditSheet()
        #expect(vm.isEditing == false)
    }

    @Test("US-AWK-007 AC-4: resolveConflict(keep: .local) clears conflict, keeps user edit, marks userEdited")
    func conflictKeepLocal() {
        let vm = MemoryDetailViewModel()
        vm.loadPreloaded(MemoryDetailFixtureLoader.load("memory-detail-conflict")!)
        #expect(vm.memory?.conflict != nil)
        vm.resolveConflict(keep: .local)
        #expect(vm.memory?.conflict == nil)
        #expect(vm.memory?.userEdited == true)
        #expect(vm.memory?.originalText == "今天去杭州出差。")
    }

    @Test("US-AWK-007 AC-4: resolveConflict(keep: .external) adopts external version")
    func conflictKeepExternal() {
        let vm = MemoryDetailViewModel()
        vm.loadPreloaded(MemoryDetailFixtureLoader.load("memory-detail-conflict")!)
        vm.resolveConflict(keep: .external)
        #expect(vm.memory?.conflict == nil)
        #expect(vm.memory?.originalText == "今天去杭州出差，客户改期到下周。")
    }

    // MARK: - US-PRV-004 Delete

    @Test("US-PRV-004 AC-1: presentDeleteConfirmation presents dialog")
    func deleteConfirmationPresents() {
        let vm = makeLoadedVM()
        vm.presentDeleteConfirmation()
        #expect(vm.showDeleteConfirmation == true)
    }

    @Test("US-PRV-004 AC-2: removeFromEcho dismisses dialog, clears memory, flags removed (🔮 ExcludedAssets write)")
    func removeFromEchoDismisses() {
        let vm = makeLoadedVM()
        vm.presentDeleteConfirmation()
        vm.removeFromEcho()
        #expect(vm.showDeleteConfirmation == false)
        #expect(vm.memory == nil)
        #expect(vm.hasRemovedMemory == true)
        #expect(vm.viewState == .idle)
    }

    @Test("US-PRV-004 AC-3: deleteOriginal dismisses dialog, clears memory, flags removed (no ExcludedAssets write)")
    func deleteOriginalDismisses() {
        let vm = makeLoadedVM()
        vm.presentDeleteConfirmation()
        vm.deleteOriginal()
        #expect(vm.showDeleteConfirmation == false)
        #expect(vm.memory == nil)
        #expect(vm.hasRemovedMemory == true)
        #expect(vm.viewState == .idle)
    }

    // MARK: - Error / Retry

    @Test("AC: retry with stub restores completed state")
    func retryRestoresCompleted() {
        let vm = makeLoadedVM()
        vm.simulateError(.l2Recoverable(message: "Unable to load this memory. Please try again."))
        #expect(vm.viewState == .error(.l2Recoverable(message: "Unable to load this memory. Please try again.")))
        vm.retry()
        #expect(vm.viewState == .completed)
    }

    // MARK: - Regression: Tab switch preserves detail (2026-08-02)

    @Test("onDisappear preserves completed detail (tab switch keeps content)")
    func test_onDisappear_preservesCompleted() {
        let vm = makeLoadedVM()
        #expect(vm.viewState == .completed)

        // TabView switch triggers onDisappear — loaded detail must survive
        vm.onDisappear()

        #expect(vm.viewState == .completed, "Loaded detail must survive onDisappear")
        #expect(vm.memory != nil, "Memory content must remain after tab switch")
    }

    @Test("onDisappear cancels in-flight load (loading → cancelled)")
    func test_onDisappear_loadingCancels() {
        let vm = MemoryDetailViewModel()
        vm.load(memoryId: UUID())
        #expect(vm.viewState == .loading)

        vm.onDisappear()
        #expect(vm.viewState == .cancelled)
    }
}
