// ==========================================
// 文件: HomeViewModelTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-001 AC-4, AWK-002 AC-3, AWK-003 AC-4, AWK-005 AC-1, US-RES-001 AC-3
// 任务: 3.1 - HomeView + HomeViewModel 单元测试
// 架构约束: AGENTS.md §8.1 (@MainActor + state enum), §8.2 (状态流转)
// 生成时间: 2026-07-27
// ==========================================

import Testing
import Foundation
@testable import Echo

@MainActor
struct HomeViewModelTests {

    // MARK: - AWK-001 AC-4: 生成交互式回忆卡片

    @Test("Initial state is idle with empty cards")
    func test_AC_AWK001_4_initialStateIsIdle() {
        let vm = HomeViewModel()
        #expect(vm.viewState == .idle)
        #expect(vm.awakeningCards.isEmpty)
        #expect(vm.isOffline == false)
    }

    // MARK: - AWK-001 AC-4 / AWK-002 AC-3 / AWK-003 AC-4: Card lifecycle

    @Test("appendAwakeningCard inserts card at front with correct mapping")
    func test_AC_AWK001_4_appendCardMapsCorrectly() {
        let vm = HomeViewModel()
        let card = AwakeningCard(
            cardId: UUID(),
            memoryIds: [UUID()],
            triggerType: "geofenceOnly",
            regionId: "Test Region",
            createdAt: Date()
        )
        vm.appendAwakeningCard(card)
        #expect(vm.awakeningCards.count == 1)
        let model = vm.awakeningCards[0]
        #expect(model.triggerType == "geofenceOnly")
        #expect(model.sourceLabel == "Test Region")
        #expect(model.symbolName == "mappin.circle.fill")
    }

    @Test("appendAwakeningCard with anniversary trigger maps to clock symbol")
    func test_AC_AWK002_3_anniversaryCardMapping() {
        let vm = HomeViewModel()
        let card = AwakeningCard(
            cardId: UUID(),
            memoryIds: [UUID()],
            triggerType: "anniversary",
            regionId: "Paris 2024",
            createdAt: Date()
        )
        vm.appendAwakeningCard(card)
        #expect(vm.awakeningCards.count == 1)
        #expect(vm.awakeningCards[0].triggerType == "anniversary")
        #expect(vm.awakeningCards[0].symbolName == "clock.arrow.circlepath")
        #expect(vm.awakeningCards[0].title == "On this day")
    }

    @Test("appendAwakeningCard with emotion triggers map to correct symbols")
    func test_AC_AWK003_4_emotionCardMapping() {
        let vm = HomeViewModel()

        let negativeCard = AwakeningCard(
            cardId: UUID(), memoryIds: [UUID()],
            triggerType: "emotionNegative", regionId: "Home", createdAt: Date()
        )
        vm.appendAwakeningCard(negativeCard)
        #expect(vm.awakeningCards[0].symbolName == "sparkles")

        let neutralCard = AwakeningCard(
            cardId: UUID(), memoryIds: [UUID()],
            triggerType: "emotionNeutral", regionId: "Office", createdAt: Date()
        )
        vm.appendAwakeningCard(neutralCard)
        #expect(vm.awakeningCards[0].symbolName == "leaf.circle.fill")
    }

    @Test("appendAwakeningCard inserts newest at index 0")
    func test_appendAwakeningCard_insertOrder() {
        let vm = HomeViewModel()
        let card1 = AwakeningCard(cardId: UUID(), memoryIds: [], triggerType: "geofenceOnly", regionId: "A", createdAt: Date())
        let card2 = AwakeningCard(cardId: UUID(), memoryIds: [], triggerType: "anniversary", regionId: "B", createdAt: Date())

        vm.appendAwakeningCard(card1)
        vm.appendAwakeningCard(card2)

        #expect(vm.awakeningCards.count == 2)
        #expect(vm.awakeningCards[0].sourceLabel == "B")
        #expect(vm.awakeningCards[1].sourceLabel == "A")
    }

    // MARK: - AWK-005 AC-1: Card model contains text content

    @Test("AwakeningCardModel produces non-empty title and subtitle for all trigger types")
    func test_AC_AWK005_1_cardModelHasTextContent() {
        let triggerTypes = ["geofenceOnly", "emotionNegative", "emotionNeutral", "anniversary", "unknown"]

        for triggerType in triggerTypes {
            let card = AwakeningCard(
                cardId: UUID(), memoryIds: [UUID()],
                triggerType: triggerType, regionId: "Test", createdAt: Date()
            )
            let model = AwakeningCardModel(from: card)
            #expect(!model.title.isEmpty, "title should not be empty for \(triggerType)")
            #expect(!model.subtitle.isEmpty, "subtitle should not be empty for \(triggerType)")
            #expect(!model.symbolName.isEmpty, "symbolName should not be empty for \(triggerType)")
        }
    }

    @Test("AwakeningCardModel relativeTimeDescription formats correctly")
    func test_AC_AWK005_1_relativeTimeDescription() {
        let now = Date()
        let justNow = AwakeningCardModel(from: AwakeningCard(
            cardId: UUID(), memoryIds: [], triggerType: "geofenceOnly",
            regionId: "X", createdAt: now.addingTimeInterval(-30)
        ))
        #expect(justNow.relativeTimeDescription == "Just now")

        let minutesAgo = AwakeningCardModel(from: AwakeningCard(
            cardId: UUID(), memoryIds: [], triggerType: "geofenceOnly",
            regionId: "X", createdAt: now.addingTimeInterval(-120)
        ))
        #expect(minutesAgo.relativeTimeDescription == "2m ago")

        let hoursAgo = AwakeningCardModel(from: AwakeningCard(
            cardId: UUID(), memoryIds: [], triggerType: "geofenceOnly",
            regionId: "X", createdAt: now.addingTimeInterval(-7200)
        ))
        #expect(hoursAgo.relativeTimeDescription == "2h ago")

        let daysAgo = AwakeningCardModel(from: AwakeningCard(
            cardId: UUID(), memoryIds: [], triggerType: "geofenceOnly",
            regionId: "X", createdAt: now.addingTimeInterval(-172800)
        ))
        #expect(daysAgo.relativeTimeDescription == "2d ago")
    }

    // MARK: - RES-001 AC-3: Offline indicator

    @Test("setOffline toggles isOffline flag")
    func test_AC_RES001_3_setOffline() {
        let vm = HomeViewModel()
        #expect(vm.isOffline == false)

        vm.setOffline(true)
        #expect(vm.isOffline == true)

        vm.setOffline(false)
        #expect(vm.isOffline == false)
    }

    // MARK: - State transitions (AGENTS.md §8.2)

    @Test("loadAwakeningCards transitions idle → loading → completed")
    func test_loadAwakeningCards_stateTransitions() async {
        let vm = HomeViewModel()
        #expect(vm.viewState == .idle)

        // Trigger loading (runs asynchronously)
        vm.loadAwakeningCards()
        #expect(vm.viewState == .loading)

        // Wait for completion (300ms sleep in impl)
        try? await Task.sleep(nanoseconds: 500_000_000)

        #expect(vm.viewState == .completed)
    }

    @Test("loadAwakeningCardsPreloaded sets state to completed")
    func test_loadAwakeningCardsPreloaded() {
        let vm = HomeViewModel()
        vm.loadAwakeningCardsPreloaded()
        #expect(vm.viewState == .completed)
    }

    @Test("cancelLoading sets state to cancelled")
    func test_cancelLoading() {
        let vm = HomeViewModel()
        vm.loadAwakeningCards()
        #expect(vm.viewState == .loading)

        vm.cancelLoading()
        #expect(vm.viewState == .cancelled)
    }

    @Test("dismissError resets state to idle")
    func test_dismissError() {
        let vm = HomeViewModel()
        vm.loadAwakeningCardsPreloaded()
        #expect(vm.viewState == .completed)

        vm.dismissError()
        #expect(vm.viewState == .idle)
    }

    @Test("refresh delegates to loadAwakeningCards")
    func test_refresh_startsLoading() {
        let vm = HomeViewModel()
        vm.refresh()
        #expect(vm.viewState == .loading)
    }

    // MARK: - Duplicate load prevention

    @Test("loadAwakeningCards ignores duplicate calls while loading")
    func test_loadAwakeningCards_ignoresDuplicateWhileLoading() {
        let vm = HomeViewModel()
        vm.loadAwakeningCards()
        #expect(vm.viewState == .loading)

        // Second call while loading should be ignored
        vm.loadAwakeningCards()
        #expect(vm.viewState == .loading)
    }

    // MARK: - ViewState Equatable

    @Test("ViewState equatable works correctly")
    func test_viewStateEquatable() {
        #expect(HomeViewModel.ViewState.idle == .idle)
        #expect(HomeViewModel.ViewState.loading == .loading)
        #expect(HomeViewModel.ViewState.completed == .completed)
        #expect(HomeViewModel.ViewState.cancelled == .cancelled)
        #expect(HomeViewModel.ViewState.error(.l2Recoverable(message: "a")) != .error(.l2Recoverable(message: "b")))
        #expect(HomeViewModel.ViewState.error(.l2Recoverable(message: "x")) == .error(.l2Recoverable(message: "x")))
    }
}
