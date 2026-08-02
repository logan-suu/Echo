// ==========================================
// 文件: Phase3IntegrationTests.swift
// 对应规格: docs/02-architecture/数据流全链路技术说明文档.md §1 (UI→VM→Pipeline→Actor 单向数据流),
//            §2 (SearchPipeline 检索), §5 (AwakeningPipeline 唤醒), §6 (FeedbackPipeline 反馈),
//            §8 (断点续传与进度管理)
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约 — 薄适配器不保存第二份领域真相)
// 任务: 3.10 - Phase 3 集成测试：UI 与 Pipeline 联调验证
// 测试范围: SearchViewModel ↔ SearchPipeline + FeedbackPipeline, HomeViewModel ↔ AwakeningPipeline,
//           BackgroundTaskViewModel ↔ ProgressActor, ResumeProgressViewModel ↔ ProgressActor,
//           MemoryDetailViewModel ↔ TranslationService + TranslationCache 跨层联调
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum), §8.2 (状态流转),
//           §4.1 (Pipeline 契约), §4.2 (Actor 隔离), R-006 (PrivacyCheckpoint), R-008 (跨 Actor await),
//           docs/ui/architecture.md §7.1 (适配器契约)
// 重要: @MainActor 标注因 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// 生成时间: 2026-08-03
// ==========================================

import Testing
import Foundation
import ProximaKit
@testable import Echo

// MARK: - Helpers

func makePhase3TestTextMetadata(assetId: String, text: String, sourceType: String = "text") -> Data {
    let memory = MemoryEntry(
        assetId: assetId,
        embedding: Array(repeating: 1.0, count: 512),
        sourceType: sourceType,
        timestamp: Date(),
        exifMetadata: nil,
        privacyBlurApplied: false,
        traceID: UUID().uuidString,
        originalText: text
    )
    return try! memory.encodeMetadata()
}

func makePhase3DirectionalVector(direction: Float, dimension: Int = 512) -> [Float] {
    let remaining = (1.0 - direction * direction) / Float(dimension - 1)
    let fill = remaining > 0 ? sqrt(max(0, remaining)) : 0.0
    var vec = [direction]
    vec.append(contentsOf: Array(repeating: fill, count: dimension - 1))
    return vec
}

// MARK: - Phase 3 Integration Test Suite

@Suite("Phase3Integration - UI 与 Pipeline 联调", .serialized)
struct Phase3IntegrationTests {
    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
        try await db.execute(sql: "DELETE FROM FeedbackStore")
        try await db.execute(sql: "DELETE FROM TaskProgress")
        try await db.execute(sql: "DELETE FROM PendingOperations")
        try await PrivacyActor.shared.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice", "search", "geofence", "text"],
            policyVersion: 1
        ))
    }

    // MARK: - Suite 1: SearchViewModel ↔ SearchPipeline

    @Suite("SearchPipelineUIIntegration")
    @MainActor
    struct SearchPipelineUIIntegrationTests {
        let vectorStore = VectorStoreActor(dimension: 512)
        let stubEmbedder = StubEmbedder()
        let searchPipeline: SearchPipeline
        let feedbackPipeline: FeedbackPipeline

        init() async throws {
            let db = DatabaseManager.shared
            try await db.open()
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await db.execute(sql: "DELETE FROM FeedbackStore")
            try await db.execute(sql: "DELETE FROM ExcludedAssets")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(
                preferredLanguage: "zh-Hans",
                authorizedSourceTypes: ["search", "photo", "note", "voice", "text"],
                policyVersion: 1
            ))
            searchPipeline = SearchPipeline(
                embedder: stubEmbedder,
                privacyActor: PrivacyActor.shared,
                vectorStore: vectorStore,
                feedbackActor: FeedbackActor.shared
            )
            feedbackPipeline = FeedbackPipeline(
                feedbackActor: FeedbackActor.shared,
                privacyActor: PrivacyActor.shared
            )
            await stubEmbedder.setNextError(nil)
        }

        /// 等待 SearchViewModel 状态从 loading 收敛（真实 Pipeline 异步搜索）。
        private func awaitSettled(
            _ vm: SearchViewModel,
            timeout: Duration = .seconds(5)
        ) async -> SearchViewModel.ViewState {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if vm.viewState != .loading {
                    return vm.viewState
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return vm.viewState
        }

        @Test("Initial state is idle before any search")
        func test_initialIdle() {
            let vm = SearchViewModel(searchPipeline: searchPipeline, feedbackPipeline: feedbackPipeline)
            #expect(vm.viewState == .idle)
            #expect(vm.results.isEmpty)
            #expect(!vm.hasSearched)
        }

        @Test("submitQuery with real pipeline returns mapped results (UI adapter contract)")
        func test_submitQueryRealPipeline() async throws {
            try await vectorStore.ingest(
                vector: makePhase3DirectionalVector(direction: 0.95),
                id: UUID(),
                metadata: makePhase3TestTextMetadata(assetId: "p3-a1", text: "iPhone photography tips")
            )
            try await vectorStore.ingest(
                vector: makePhase3DirectionalVector(direction: 0.5),
                id: UUID(),
                metadata: makePhase3TestTextMetadata(assetId: "p3-a2", text: "weekend cooking recipe")
            )
            try await vectorStore.ingest(
                vector: makePhase3DirectionalVector(direction: 0.9),
                id: UUID(),
                metadata: makePhase3TestTextMetadata(assetId: "p3-a3", text: "iPhone camera review")
            )
            await stubEmbedder.setNextEmbedding(makePhase3DirectionalVector(direction: 1.0))

            let vm = SearchViewModel(searchPipeline: searchPipeline, feedbackPipeline: feedbackPipeline)
            vm.submitQuery("iPhone photo")
            let state = await awaitSettled(vm)

            #expect(state == .completed)
            #expect(vm.hasSearched)
            #expect(vm.results.count == 3)
            // Sorted by cosineSimilarity descending (search pipeline Step 9)
            #expect(vm.results[0].cosineSimilarity >= vm.results[1].cosineSimilarity)
            #expect(vm.results[1].cosineSimilarity >= vm.results[2].cosineSimilarity)
            // Adapter mapping: sourceType + originalText preserved
            let top = vm.results[0]
            #expect(top.sourceType == "text")
            #expect(top.originalText == "iPhone photography tips")
            #expect(top.summary == "iPhone photography tips")
        }

        @Test("Empty query is ignored (stays idle)")
        func test_emptyQueryIgnored() {
            let vm = SearchViewModel(searchPipeline: searchPipeline, feedbackPipeline: feedbackPipeline)
            vm.submitQuery("   ")
            #expect(vm.viewState == .idle)
            #expect(!vm.hasSearched)
        }

        @Test("Privacy denial maps to L2 recoverable error state (R-006 through UI layer)")
        func test_privacyDeniedErrorState() async throws {
            try await PrivacyActor.shared.updatePolicy(UserPolicy(
                preferredLanguage: "zh-Hans",
                authorizedSourceTypes: ["photo"],  // search NOT authorized
                policyVersion: 1
            ))

            await stubEmbedder.setNextEmbedding(makePhase3DirectionalVector(direction: 1.0))
            let vm = SearchViewModel(searchPipeline: searchPipeline, feedbackPipeline: feedbackPipeline)
            vm.submitQuery("anything")
            let state = await awaitSettled(vm)

            guard case .error(let level) = state else {
                Issue.record("Expected .error, got \(state)")
                return
            }
            guard case .l2Recoverable = level else {
                Issue.record("Expected .l2Recoverable (SearchError.privacyDenied is L2), got \(level)")
                return
            }

            // Restore policy synchronously before the test returns — the suite is
            // serialized and later tests depend on search being authorized.
            // No fire-and-forget Task (deterministic global PrivacyActor state).
            try await PrivacyActor.shared.updatePolicy(UserPolicy(
                preferredLanguage: "zh-Hans",
                authorizedSourceTypes: ["search", "photo", "note", "voice", "text"],
                policyVersion: 1
            ))
        }

        @Test("Search writes audit log through UI layer (R-006 + §9 审计)")
        func test_searchAuditThroughUI() async throws {
            let db = DatabaseManager.shared
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await vectorStore.ingest(
                vector: makePhase3DirectionalVector(direction: 0.9),
                id: UUID(),
                metadata: makePhase3TestTextMetadata(assetId: "p3-audit", text: "audit trail memory")
            )
            await stubEmbedder.setNextEmbedding(makePhase3DirectionalVector(direction: 1.0))

            let vm = SearchViewModel(searchPipeline: searchPipeline, feedbackPipeline: feedbackPipeline)
            vm.submitQuery("audit")
            _ = await awaitSettled(vm)

            let rows = try await db.executeQuery(
                sql: "SELECT 1 FROM AuditLog WHERE eventType = 'retrieval'",
                bindings: []
            )
            #expect(rows.count >= 1)
        }
    }

    // MARK: - Suite 2: SearchViewModel ↔ FeedbackPipeline (反馈联调)

    @Suite("SearchFeedbackUIIntegration")
    @MainActor
    struct SearchFeedbackUIIntegrationTests {
        let vectorStore = VectorStoreActor(dimension: 512)
        let stubEmbedder = StubEmbedder()
        let searchPipeline: SearchPipeline
        let feedbackPipeline: FeedbackPipeline
        let feedbackActor = FeedbackActor.shared

        init() async throws {
            let db = DatabaseManager.shared
            try await db.open()
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await db.execute(sql: "DELETE FROM FeedbackStore")
            try await db.execute(sql: "DELETE FROM ExcludedAssets")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(
                preferredLanguage: "zh-Hans",
                authorizedSourceTypes: ["search", "photo", "note", "voice", "text"],
                policyVersion: 1
            ))
            searchPipeline = SearchPipeline(
                embedder: stubEmbedder,
                privacyActor: PrivacyActor.shared,
                vectorStore: vectorStore,
                feedbackActor: feedbackActor
            )
            feedbackPipeline = FeedbackPipeline(
                feedbackActor: feedbackActor,
                privacyActor: PrivacyActor.shared
            )
        }

        private func awaitSettled(
            _ vm: SearchViewModel,
            timeout: Duration = .seconds(5)
        ) async -> SearchViewModel.ViewState {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if vm.viewState != .loading {
                    return vm.viewState
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return vm.viewState
        }

        private func awaitFeedbackCount(
            for memoryId: UUID,
            expected: Int,
            timeout: Duration = .seconds(5)
        ) async -> Int {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if let count = try? await feedbackActor.fetchEntries(for: memoryId).count,
                   count >= expected {
                    return count
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return (try? await feedbackActor.fetchEntries(for: memoryId).count) ?? 0
        }

        @Test("recordLike through ViewModel persists to FeedbackActor (UI→Pipeline→Actor)")
        func test_recordLikePersists() async throws {
            let id = UUID()
            try await vectorStore.ingest(
                vector: makePhase3DirectionalVector(direction: 0.95),
                id: id,
                metadata: makePhase3TestTextMetadata(assetId: "fb-like", text: "likeable memory")
            )
            await stubEmbedder.setNextEmbedding(makePhase3DirectionalVector(direction: 1.0))

            let vm = SearchViewModel(searchPipeline: searchPipeline, feedbackPipeline: feedbackPipeline)
            vm.submitQuery("like test")
            _ = await awaitSettled(vm)
            guard let result = vm.results.first else {
                Issue.record("No search results")
                return
            }

            vm.recordLike(result)
            let count = await awaitFeedbackCount(for: id, expected: 1)
            #expect(count >= 1)

            let entries = try await feedbackActor.fetchEntries(for: id)
            #expect(entries.first?.sentiment == .like)
            #expect(entries.first?.queryText == "like test")
        }

        @Test("recordDislike through ViewModel persists to FeedbackActor")
        func test_recordDislikePersists() async throws {
            let id = UUID()
            try await vectorStore.ingest(
                vector: makePhase3DirectionalVector(direction: 0.9),
                id: id,
                metadata: makePhase3TestTextMetadata(assetId: "fb-dislike", text: "dislikeable memory")
            )
            await stubEmbedder.setNextEmbedding(makePhase3DirectionalVector(direction: 1.0))

            let vm = SearchViewModel(searchPipeline: searchPipeline, feedbackPipeline: feedbackPipeline)
            vm.submitQuery("dislike test")
            _ = await awaitSettled(vm)
            guard let result = vm.results.first else {
                Issue.record("No search results")
                return
            }

            vm.recordDislike(result)
            _ = await awaitFeedbackCount(for: id, expected: 1)

            let entries = try await feedbackActor.fetchEntries(for: id)
            #expect(entries.first?.sentiment == .dislike)
        }

        @Test("markBadCase through ViewModel persists and is fetchable as bad case")
        func test_markBadCasePersists() async throws {
            let id = UUID()
            try await vectorStore.ingest(
                vector: makePhase3DirectionalVector(direction: 0.85),
                id: id,
                metadata: makePhase3TestTextMetadata(assetId: "fb-bad", text: "bad case memory")
            )
            await stubEmbedder.setNextEmbedding(makePhase3DirectionalVector(direction: 1.0))

            let vm = SearchViewModel(searchPipeline: searchPipeline, feedbackPipeline: feedbackPipeline)
            vm.submitQuery("bad test")
            _ = await awaitSettled(vm)
            guard let result = vm.results.first else {
                Issue.record("No search results")
                return
            }

            vm.markBadCase(result)
            _ = await awaitFeedbackCount(for: id, expected: 1)

            let badCases = try await feedbackActor.fetchBadCases()
            #expect(badCases.contains { $0.memoryId == id && $0.isBadCase })
        }

        @Test("Feedback re-ranking visible through UI: liked memory gets positive adjustment")
        func test_feedbackRerankingThroughUI() async throws {
            // Three memories, all above the 0.80 feedback threshold.
            let id1 = UUID(); let id2 = UUID(); let id3 = UUID()
            try await vectorStore.ingest(
                vector: makePhase3DirectionalVector(direction: 0.93),
                id: id1,
                metadata: makePhase3TestTextMetadata(assetId: "rr-1", text: "alpha memory")
            )
            try await vectorStore.ingest(
                vector: makePhase3DirectionalVector(direction: 0.91),
                id: id2,
                metadata: makePhase3TestTextMetadata(assetId: "rr-2", text: "bravo memory")
            )
            try await vectorStore.ingest(
                vector: makePhase3DirectionalVector(direction: 0.89),
                id: id3,
                metadata: makePhase3TestTextMetadata(assetId: "rr-3", text: "charlie memory")
            )
            await stubEmbedder.setNextEmbedding(makePhase3DirectionalVector(direction: 1.0))

            let vm = SearchViewModel(searchPipeline: searchPipeline, feedbackPipeline: feedbackPipeline)
            vm.submitQuery("rank test")
            _ = await awaitSettled(vm)

            // Like the lowest-ranked result (id3, cosine 0.89) → should receive +0.5 clamp.
            guard let target = vm.results.first(where: { $0.id == id3 }) else {
                Issue.record("id3 not in results")
                return
            }
            vm.recordLike(target)
            _ = await awaitFeedbackCount(for: id3, expected: 1)

            // Re-search: feedback re-ranking must lift the liked memory to rank #1.
            // finalScore(id3) = 0.89 + 0.5 (like, decay 1.0, clamp ±0.5) = 1.39
            // > finalScore(id1) = 0.93, finalScore(id2) = 0.91 (AGENTS.md §5.3).
            vm.submitQuery("rank test")
            _ = await awaitSettled(vm)
            #expect(vm.results.first?.id == id3)
            #expect(vm.results.contains { $0.id == id1 })
            #expect(vm.results.contains { $0.id == id2 })
        }
    }

    // MARK: - Suite 3: HomeViewModel ↔ AwakeningPipeline (唤醒联调)

    @Suite("HomeAwakeningUIIntegration")
    @MainActor
    struct HomeAwakeningUIIntegrationTests {
        let vectorStore = VectorStoreActor(dimension: 512)
        let stubEmbedder = StubEmbedder()
        let searchPipeline: SearchPipeline
        let stateStore: GeofenceStateStore
        let awakeningPipeline: AwakeningPipeline

        init() async throws {
            let db = DatabaseManager.shared
            try await db.open()
            try await db.execute(sql: "DELETE FROM AuditLog")
            try await db.execute(sql: "DELETE FROM ExcludedAssets")
            try await PrivacyActor.shared.updatePolicy(UserPolicy(
                preferredLanguage: "zh-Hans",
                authorizedSourceTypes: ["search", "photo", "note", "voice", "geofence", "text"],
                policyVersion: 1
            ))
            searchPipeline = SearchPipeline(
                embedder: stubEmbedder,
                privacyActor: PrivacyActor.shared,
                vectorStore: vectorStore
            )
            stateStore = GeofenceStateStore()
            await stateStore.clearAll()
            awakeningPipeline = AwakeningPipeline(
                privacyActor: PrivacyActor.shared,
                searchPipeline: searchPipeline,
                stateStore: stateStore
            )
        }

        @Test("Geofence enter with matching memory produces card mapped to UI model")
        func test_geofenceCardMappedToUI() async throws {
            try await vectorStore.ingest(
                vector: makePhase3DirectionalVector(direction: 0.95),
                id: UUID(),
                metadata: makePhase3TestTextMetadata(assetId: "awk-lake", text: "coffee by the lake")
            )
            await stubEmbedder.setNextEmbedding(makePhase3DirectionalVector(direction: 1.0))

            let result = await awakeningPipeline.handleGeofenceEnter(regionId: "lake", traceID: "p3-awk-1")
            guard case .processed(let card) = result else {
                Issue.record("Expected .processed, got \(result)")
                return
            }

            let vm = HomeViewModel(awakeningPipeline: awakeningPipeline)
            vm.appendAwakeningCard(card)

            #expect(vm.awakeningCards.count == 1)
            let model = vm.awakeningCards[0]
            #expect(model.id == card.cardId)
            #expect(model.memoryIds == card.memoryIds)
            #expect(model.triggerType == "geofenceOnly")
            #expect(model.sourceLabel == "lake")
            #expect(model.title == "Arrived at lake")
            #expect(model.symbolName == "mappin.circle.fill")
        }

        @Test("Geofence re-enter is deduplicated (.alreadyPushed) — no duplicate UI cards")
        func test_geofenceDedupNoDuplicate() async throws {
            try await vectorStore.ingest(
                vector: makePhase3DirectionalVector(direction: 0.95),
                id: UUID(),
                metadata: makePhase3TestTextMetadata(assetId: "awk-dedup", text: "dup region memory")
            )
            await stubEmbedder.setNextEmbedding(makePhase3DirectionalVector(direction: 1.0))

            let r1 = await awakeningPipeline.handleGeofenceEnter(regionId: "dup", traceID: "p3-awk-2")
            guard case .processed(let card) = r1 else {
                Issue.record("Expected .processed on first enter, got \(r1)")
                return
            }
            let r2 = await awakeningPipeline.handleGeofenceEnter(regionId: "dup", traceID: "p3-awk-3")
            guard case .alreadyPushed = r2 else {
                Issue.record("Expected .alreadyPushed on second enter, got \(r2)")
                return
            }

            let vm = HomeViewModel(awakeningPipeline: awakeningPipeline)
            vm.appendAwakeningCard(card)
            #expect(vm.awakeningCards.count == 1)
        }
    }

    // MARK: - Suite 4: BackgroundTaskViewModel ↔ ProgressActor (后台任务面板联调)

    @Suite("BackgroundTaskProgressUIIntegration")
    @MainActor
    struct BackgroundTaskProgressUIIntegrationTests {
        let progressActor = ProgressActor.shared

        init() async throws {
            let db = DatabaseManager.shared
            try await db.open()
            try await db.execute(sql: "DELETE FROM TaskProgress")
            try await db.execute(sql: "DELETE FROM AuditLog")
        }

        @Test("TaskProgress saved via ProgressActor maps to UI model via adapter")
        func test_progressPersistenceMapsToUI() async throws {
            let progress = TaskProgress(
                taskId: "p3-sync-001",
                taskType: .dataSourceSync,
                lastProcessedIndex: 32,
                totalCount: 128,
                lastProcessedId: "photo-32"
            )
            try await progressActor.save(progress: progress)

            // Persisted round-trip
            let loaded = try await progressActor.load(taskId: "p3-sync-001")
            #expect(loaded != nil)
            #expect(loaded?.lastProcessedIndex == 32)
            #expect(try await progressActor.hasPendingProgress(taskType: .dataSourceSync))

            // Adapter mapping: Core TaskProgress → UI BackgroundTaskModel
            let model = BackgroundTaskModel(from: progress)
            #expect(model.taskId == "p3-sync-001")
            #expect(model.taskType == .dataSourceSync)
            #expect(model.processedCount == 32)
            #expect(model.totalCount == 128)
            #expect(model.displayName == "Syncing photos")
        }

        @Test("Full-index progress maps to correct display name")
        func test_fullIndexDisplayName() {
            let progress = TaskProgress(taskId: "p3-index-001", taskType: .fullIndex, lastProcessedIndex: 5, totalCount: 10)
            let model = BackgroundTaskModel(from: progress)
            #expect(model.displayName == "Building vector index")
        }

        @Test("ProgressActor hasPendingProgress false after delete")
        func test_progressDeleteClearsPending() async throws {
            try await progressActor.save(progress: TaskProgress(
                taskId: "p3-del-001", taskType: .fullIndex, lastProcessedIndex: 1, totalCount: 10
            ))
            #expect(try await progressActor.hasPendingProgress(taskType: .fullIndex))
            let deleted = try await progressActor.delete(taskId: "p3-del-001")
            #expect(deleted)
            #expect(!(try await progressActor.hasPendingProgress(taskType: .fullIndex)))
        }
    }

    // MARK: - Suite 5: ResumeProgressViewModel ↔ ProgressActor (断点续传联调)

    @Suite("ResumeProgressUIIntegration")
    @MainActor
    struct ResumeProgressUIIntegrationTests {
        let progressActor = ProgressActor.shared

        init() async throws {
            let db = DatabaseManager.shared
            try await db.open()
            try await db.execute(sql: "DELETE FROM TaskProgress")
            try await db.execute(sql: "DELETE FROM AuditLog")
        }

        @Test("Prompt presented from real persisted TaskProgress; continue maps to resumed")
        func test_promptFromRealProgressContinue() async throws {
            let progress = TaskProgress(
                taskId: "p3-resume-001",
                taskType: .fullIndex,
                lastProcessedIndex: 50,
                totalCount: 100,
                lastProcessedId: "item-50"
            )
            try await progressActor.save(progress: progress)
            guard let loaded = try await progressActor.load(taskId: "p3-resume-001") else {
                Issue.record("Persisted progress not found")
                return
            }

            let vm = ResumeProgressViewModel(progressActor: progressActor, checkDelayNanoseconds: 0)
            vm.presentPrompt(loaded)

            guard case .prompt(let p) = vm.viewState else {
                Issue.record("Expected .prompt, got \(vm.viewState)")
                return
            }
            #expect(p.taskId == "p3-resume-001")
            #expect(p.lastProcessedIndex == 50)
            #expect(vm.isPromptPresented)

            vm.continueTask()
            guard case .resumed = vm.viewState else {
                Issue.record("Expected .resumed after continue, got \(vm.viewState)")
                return
            }
            #expect(vm.lastResumeTarget?.taskId == "p3-resume-001")
            #expect(!vm.isPromptPresented)
        }

        @Test("Restart maps to restarted state (US-SYS-001 AC-4 intent)")
        func test_restartIntent() async throws {
            let progress = TaskProgress(
                taskId: "p3-restart-001",
                taskType: .dataSourceSync,
                lastProcessedIndex: 10,
                totalCount: 50
            )
            try await progressActor.save(progress: progress)

            let vm = ResumeProgressViewModel(progressActor: progressActor, checkDelayNanoseconds: 0)
            vm.presentPrompt(progress)

            vm.restartTask()
            guard case .restarted = vm.viewState else {
                Issue.record("Expected .restarted, got \(vm.viewState)")
                return
            }
            #expect(vm.lastResumeTarget?.taskId == "p3-restart-001")
        }

        @Test("Dismiss closes prompt and returns to idle")
        func test_dismissPrompt() async throws {
            let progress = TaskProgress(
                taskId: "p3-dismiss-001",
                taskType: .fullIndex,
                lastProcessedIndex: 3,
                totalCount: 9
            )
            try await progressActor.save(progress: progress)

            let vm = ResumeProgressViewModel(progressActor: progressActor, checkDelayNanoseconds: 0)
            vm.presentPrompt(progress)
            #expect(vm.isPromptPresented)

            vm.dismissPrompt()
            #expect(vm.viewState == .idle)
            #expect(!vm.isPromptPresented)
        }
    }

    // MARK: - Suite 6: MemoryDetailViewModel ↔ TranslationService + TranslationCache (翻译联调)

    @Suite("MemoryDetailTranslationUIIntegration")
    @MainActor
    struct MemoryDetailTranslationUIIntegrationTests {
        private let knownZhText = "昨晚在公园遇到一只橘猫，很亲人。它在我脚边蹭了很久，后来跟着我走了一段路。"
        private let lowConfidenceZhText = "今天整个下午都在搞这个破项目，快崩了。"

        private func makeModel(
            originalText: String,
            sourceLanguage: String = "zh-Hans",
            preferredLanguage: String = "en-US"
        ) -> MemoryDetailModel {
            MemoryDetailModel(
                id: UUID(),
                assetId: "p3-detail-1",
                sourceType: "text",
                title: "公园橘猫",
                originalText: originalText,
                sourceLanguage: sourceLanguage,
                preferredLanguage: preferredLanguage,
                timestamp: Date(),
                tags: [],
                userEdited: false,
                translationVisible: false,
                translatedText: nil,
                sourceLanguageConfidence: nil,
                conflict: nil,
                mediaAssetName: nil,
                location: nil
            )
        }

        /// 等待翻译阶段从 .translating 收敛。
        private func awaitTranslationSettled(
            _ vm: MemoryDetailViewModel,
            timeout: Duration = .seconds(5)
        ) async -> MemoryDetailViewModel.TranslationPhase {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if vm.translationPhase != .translating {
                    return vm.translationPhase
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return vm.translationPhase
        }

        @Test("needsTranslation true when source language differs from preferred (US-DIS-002)")
        func test_needsTranslation() {
            let model = makeModel(originalText: knownZhText)
            #expect(model.needsTranslation)
            #expect(model.sourceLanguage == "zh-Hans")
            #expect(model.preferredLanguage == "en-US")
        }

        @Test("Toggle translation triggers service and reaches .translated with cache write (AC-2/AC-5)")
        func test_translationFlowWithCache() async throws {
            let cache = TranslationCache()
            let vm = MemoryDetailViewModel(
                translationService: FixtureTranslationService(),
                translationCache: cache
            )
            vm.loadPreloaded(makeModel(originalText: knownZhText))
            #expect(vm.viewState == .completed)

            vm.toggleTranslation()
            let phase = await awaitTranslationSettled(vm)
            #expect(phase == .translated)

            let current = vm.memory
            #expect(current?.translatedText != nil)
            #expect(current?.translatedText?.contains("orange tabby") == true)
            #expect(current?.sourceLanguageConfidence == 0.95)

            // AC-5: cache written — a second toggle reuses it without re-request.
            let key = TranslationCache.makeKey(
                sourceText: knownZhText,
                sourceLanguage: "zh-Hans",
                targetLanguage: "en-US"
            )
            #expect(await cache.lookup(key: key) != nil)
        }

        @Test("Low source-language confidence keeps original primary (AC-3, ADR-005)")
        func test_lowConfidenceTranslation() async throws {
            let cache = TranslationCache()
            let vm = MemoryDetailViewModel(
                translationService: FixtureTranslationService(),
                translationCache: cache
            )
            vm.loadPreloaded(makeModel(originalText: lowConfidenceZhText))
            #expect(vm.viewState == .completed)

            vm.toggleTranslation()
            let phase = await awaitTranslationSettled(vm)
            #expect(phase == .translated)

            // Confidence 0.55 < 0.9 → .uncertain; translated text still produced,
            // view layer decides to keep original primary (ADR-005).
            let current = vm.memory
            #expect(current?.sourceLanguageConfidence == 0.55)
            #expect(current?.translatedText != nil)
        }

        @Test("Toggle off cancels translation and resets phase to idle")
        func test_toggleOffResetsPhase() async throws {
            let vm = MemoryDetailViewModel(
                translationService: FixtureTranslationService(),
                translationCache: TranslationCache()
            )
            vm.loadPreloaded(makeModel(originalText: knownZhText))

            vm.toggleTranslation()
            _ = await awaitTranslationSettled(vm)
            #expect(vm.translationPhase == .translated)

            vm.toggleTranslation()
            #expect(vm.translationPhase == .idle)
        }
    }
}
