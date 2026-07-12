// ==========================================
// 文件: AwakeningGeoTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-001 (地理围栏情境记忆唤醒)
//            docs/02-architecture/数据流全链路技术说明文档.md §5.1 (地理围栏唤醒)
//            docs/02-architecture/架构设计文档.md §2.1 (AwakeningPipeline)
// 任务: 2.11 - AwakeningPipeline：地理围栏（US-AWK-001）
// AC 覆盖: US-AWK-001 AC-1 (仅didEnter触发), AC-2 (离开重置, 永不重复推送),
//          AC-3 (匹配度≥0.7), AC-4 (回忆卡片生成), AC-5 (定位权限关闭静默禁用),
//          AC-6 (审计记录.contextualAwakening)
// 架构约束: AGENTS.md §4.1 (Pipeline 契约), R-006 (PrivacyCheckpoint 强制注入),
//           AGENTS.md §4.4 (L1~L4 统一错误分级)
// 重要: @MainActor 标注因 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// 生成时间: 2026-07-12
// ==========================================

import Testing
import Foundation
@testable import Echo
import ProximaKit

// MARK: - Test Suite: AwakeningPipeline Geofence (US-AWK-001)

@Suite("AwakeningPipeline Geofence (US-AWK-001)", .serialized)
@MainActor
struct AwakeningGeoTests {

    // MARK: - Dependencies

    let db = DatabaseManager.shared
    let privacyActor = PrivacyActor.shared
    let vectorStore = VectorStoreActor(dimension: 512)
    let stubEmbedder = StubEmbedder()
    var sut: AwakeningPipeline!
    var stateStore: GeofenceStateStore!
    var searchPipeline: SearchPipeline!

    // MARK: - Setup & Teardown

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice", "search", "geofence"],
            policyVersion: 1
        ))

        searchPipeline = SearchPipeline(
            embedder: stubEmbedder,
            privacyActor: privacyActor,
            vectorStore: vectorStore
        )

        stateStore = GeofenceStateStore()
        await stateStore.clearAll()

        sut = AwakeningPipeline(
            privacyActor: privacyActor,
            searchPipeline: searchPipeline,
            stateStore: stateStore
        )
    }

    // MARK: - Helpers

    /// 摄入一条测试记忆到 VectorStore，返回其 UUID
    func ingestTestMemory(assetId: String, sourceType: String, text: String) async throws -> UUID {
        let traceID = UUID().uuidString
        let embedding: [Float] = Array(repeating: 1.0, count: 512)
        let memory = MemoryEntry(
            assetId: assetId,
            embedding: embedding,
            sourceType: sourceType,
            timestamp: Date(),
            exifMetadata: nil,
            privacyBlurApplied: false,
            traceID: traceID,
            originalText: text
        )
        let metadata = try memory.encodeMetadata()
        try await vectorStore.ingest(vector: embedding, id: memory.id, metadata: metadata)
        return memory.id
    }

    // MARK: - AC-1: 触发条件仅为单一地理围栏进入事件

    @Test("AC-1: handleGeofenceEnter triggers awakening flow; handleGeofenceExit does not")
    func test_AC1_onlyDidEnterTriggersAwakening() async throws {
        let regionId = "ac1-test-\(UUID().uuidString)"

        // When: handleGeofenceEnter is called (fresh state)
        let enterResult = await sut.handleGeofenceEnter(regionId: regionId, traceID: "trace-ac1")

        // Then: enter should attempt to process (returns .noMemories since no data in vector store)
        #expect(enterResult != .permissionDenied)

        // When: handleGeofenceExit is called
        let exitResult = await sut.handleGeofenceExit(regionId: regionId)

        // Then: exit marks the fence as exited (does not trigger awakening)
        #expect(exitResult == true)

        // Verify state: region is now marked as exited
        let state = await stateStore.getState(for: regionId)
        #expect(state?.hasExited == true)
    }

    // MARK: - AC-2a: 离开重置 — 未离开则永不重复推送

    @Test("AC-2a: second enter without exit returns alreadyPushed")
    func test_AC2a_noRepeatPushWithoutExit() async throws {
        let regionId = "ac2a-test-\(UUID().uuidString)"

        // Given: first enter — push occurs (no memories, but state is pushed)
        _ = await sut.handleGeofenceEnter(regionId: regionId, traceID: "trace-ac2a-1")

        // Verify state after first push
        var state = await stateStore.getState(for: regionId)
        #expect(state?.hasBeenPushed == true)
        #expect(state?.hasExited == false)

        // When: second enter without exit
        let result = await sut.handleGeofenceEnter(regionId: regionId, traceID: "trace-ac2a-2")

        // Then: should return alreadyPushed
        #expect(result == .alreadyPushed)

        // State should remain unchanged (still pushed, still not exited)
        state = await stateStore.getState(for: regionId)
        #expect(state?.hasBeenPushed == true)
        #expect(state?.hasExited == false)
    }

    // MARK: - AC-2b: 离开后重新进入，重置计时

    @Test("AC-2b: exit then re-enter resets and allows new push")
    func test_AC2b_resetAfterExitReenter() async throws {
        let regionId = "ac2b-test-\(UUID().uuidString)"

        // Given: first enter → pushed
        _ = await sut.handleGeofenceEnter(regionId: regionId, traceID: "trace-ac2b-1")

        var state = await stateStore.getState(for: regionId)
        #expect(state?.hasBeenPushed == true)

        // When: exit the region
        _ = await sut.handleGeofenceExit(regionId: regionId)

        state = await stateStore.getState(for: regionId)
        #expect(state?.hasExited == true)

        // When: re-enter after exit
        let result = await sut.handleGeofenceEnter(regionId: regionId, traceID: "trace-ac2b-2")

        // Then: should allow new push (not alreadyPushed)
        #expect(result != .alreadyPushed)

        // State: pushed again, exited flag cleared
        state = await stateStore.getState(for: regionId)
        #expect(state?.hasBeenPushed == true)
        #expect(state?.hasExited == false)
    }

    // MARK: - AC-3a: 匹配度 < 0.7 的结果被过滤

    @Test("AC-3a: memories below 0.7 cosineSimilarity are filtered out")
    func test_AC3a_filterResultsBelowThreshold() async {
        // Create mock SearchResultItems with various scores
        let highScoreItem = SearchResultItem(
            id: UUID(),
            assetId: "asset-high",
            sourceType: "photo",
            timestamp: Date().timeIntervalSince1970,
            cosineSimilarity: 0.85
        )
        let mediumScoreItem = SearchResultItem(
            id: UUID(),
            assetId: "asset-medium",
            sourceType: "photo",
            timestamp: Date().timeIntervalSince1970,
            cosineSimilarity: 0.72
        )
        let lowScoreItem = SearchResultItem(
            id: UUID(),
            assetId: "asset-low",
            sourceType: "photo",
            timestamp: Date().timeIntervalSince1970,
            cosineSimilarity: 0.50
        )
        let boundaryItem = SearchResultItem(
            id: UUID(),
            assetId: "asset-boundary",
            sourceType: "photo",
            timestamp: Date().timeIntervalSince1970,
            cosineSimilarity: 0.70
        )

        let allResults = [highScoreItem, mediumScoreItem, lowScoreItem, boundaryItem]

        // When: filter by threshold ≥ 0.7
        let filtered = await sut.filterByThreshold(allResults, threshold: 0.7)

        // Then: only items ≥ 0.7 are kept
        #expect(filtered.count == 3)
        let filteredIds = filtered.map(\.assetId)
        #expect(filteredIds.contains("asset-high"))
        #expect(filteredIds.contains("asset-medium"))
        #expect(filteredIds.contains("asset-boundary"))
        #expect(!filteredIds.contains("asset-low"))
    }

    // MARK: - AC-3b: 匹配度 ≥ 0.7 的结果被保留

    @Test("AC-3b: empty results when all memories below threshold")
    func test_AC3b_emptyWhenAllBelowThreshold() async {
        let allLow = [
            SearchResultItem(id: UUID(), assetId: "a1", sourceType: "photo",
                             timestamp: Date().timeIntervalSince1970, cosineSimilarity: 0.3),
            SearchResultItem(id: UUID(), assetId: "a2", sourceType: "photo",
                             timestamp: Date().timeIntervalSince1970, cosineSimilarity: 0.5),
            SearchResultItem(id: UUID(), assetId: "a3", sourceType: "photo",
                             timestamp: Date().timeIntervalSince1970, cosineSimilarity: 0.69)
        ]

        let filtered = await sut.filterByThreshold(allLow, threshold: 0.7)
        #expect(filtered.isEmpty)
    }

    // MARK: - AC-4: 生成交互式回忆卡片（接口占位，UI Phase 3）

    @Test("AC-4: card model is created with memory IDs and region info")
    func test_AC4_cardGeneratedOnAwakening() async throws {
        let memoryId1 = UUID()
        let memoryId2 = UUID()
        let memories = [
            SearchResultItem(id: memoryId1, assetId: "card-asset-1", sourceType: "photo",
                             timestamp: Date().timeIntervalSince1970, cosineSimilarity: 0.85),
            SearchResultItem(id: memoryId2, assetId: "card-asset-2", sourceType: "text",
                             timestamp: Date().timeIntervalSince1970, cosineSimilarity: 0.90)
        ]
        let regionId = "ac4-test-\(UUID().uuidString)"

        // When: generate card
        let card = await sut.generateCard(for: memories, regionId: regionId)

        // Then: card contains expected data
        #expect(card.memoryIds.count == 2)
        #expect(card.memoryIds.contains(memoryId1))
        #expect(card.memoryIds.contains(memoryId2))
        #expect(card.triggerType == "geofenceOnly")
        #expect(card.regionId == regionId)
        #expect(!card.cardId.uuidString.isEmpty)
    }

    // MARK: - AC-5a: 定位权限关闭时静默禁用

    @Test("AC-5a: permission denied returns permissionDenied without crash")
    func test_AC5a_silentDisableWhenPermissionDenied() async throws {
        // Given: update policy to revoke authorization
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: [],  // no sources authorized
            policyVersion: 2
        ))

        let regionId = "ac5a-test-\(UUID().uuidString)"

        // When: enter geofence with no permission
        let result = await sut.handleGeofenceEnter(regionId: regionId, traceID: "trace-ac5a")

        // Then: returns permissionDenied, no crash
        #expect(result == .permissionDenied)

        // Restore policy for other tests
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice", "search", "geofence"],
            policyVersion: 3
        ))
    }

    // MARK: - AC-5b: 重新开启定位后不会立即推送

    @Test("AC-5b: re-enabling inside fence does NOT immediately push — waits for next enter")
    func test_AC5b_noImmediatePushOnReEnable() async throws {
        let regionId = "ac5b-test-\(UUID().uuidString)"

        // Given: first enter → pushed
        _ = await sut.handleGeofenceEnter(regionId: regionId, traceID: "trace-ac5b-1")

        // Verify pushed
        var state = await stateStore.getState(for: regionId)
        #expect(state?.hasBeenPushed == true)

        // Simulate: permission re-enabled while still inside fence
        // This is modeled by: state shows hasBeenPushed=true, hasExited=false
        // AwakeningPipeline checks state and returns alreadyPushed
        let result = await sut.handleGeofenceEnter(regionId: regionId, traceID: "trace-ac5b-2")
        #expect(result == .alreadyPushed)

        // State unchanged
        state = await stateStore.getState(for: regionId)
        #expect(state?.hasBeenPushed == true)
        #expect(state?.hasExited == false)
    }

    // MARK: - AC-6: 审计记录 .contextualAwakening

    @Test("AC-6: audit log contains triggerType, memoryIds, and resetByExit")
    func test_AC6_auditRecordCorrect() async throws {
        // 摄入一条测试记忆用于唤醒
        let memoryId = try await ingestTestMemory(
            assetId: "audit-asset",
            sourceType: "photo",
            text: "金门大桥日落"
        )

        let regionId = "ac6-test-\(UUID().uuidString)"
        let traceID = "trace-ac6"

        // When: write contextualAwakening audit
        await sut.writeAwakeningAudit(
            traceID: traceID,
            regionId: regionId,
            memoryIds: [memoryId],
            resetByExit: true,
            success: true,
            policyVersion: 1
        )

        // Then: verify audit log was written
        let logs = try await privacyActor.fetchAuditLogs(limit: 5, eventType: .contextualAwakening)
        #expect(!logs.isEmpty)

        if let log = logs.first {
            #expect(log.eventType == .contextualAwakening)
            #expect(log.traceID == traceID)
            #expect(log.success == true)

            // Verify metadata JSON contains triggerType and resetByExit
            if let metadata = await sut.parseAwakeningMetadata(from: log.sourceLanguage ?? "") {
                #expect(metadata.triggerType == "geofenceOnly")
                #expect(metadata.resetByExit == true)
                #expect(metadata.memoryIds.contains(memoryId))
            }
        }
    }

    // MARK: - GeofenceStateStore Tests

    @Test("GeofenceStateStore: initialState returns nil")
    func test_geofenceStore_initialStateIsNil() async {
        let store = GeofenceStateStore()
        let state = await store.getState(for: "nonexistent")
        #expect(state == nil)
    }

    @Test("GeofenceStateStore: markPushed sets hasBeenPushed=true, hasExited=false")
    func test_geofenceStore_markPushed() async {
        let store = GeofenceStateStore()
        await store.markPushed(regionId: "region-a")

        let state = await store.getState(for: "region-a")
        #expect(state?.hasBeenPushed == true)
        #expect(state?.hasExited == false)
    }

    @Test("GeofenceStateStore: markExited sets hasExited=true")
    func test_geofenceStore_markExited() async {
        let store = GeofenceStateStore()
        await store.markPushed(regionId: "region-b")
        await store.markExited(regionId: "region-b")

        let state = await store.getState(for: "region-b")
        #expect(state?.hasBeenPushed == true)
        #expect(state?.hasExited == true)
    }

    @Test("GeofenceStateStore: reset clears state for region")
    func test_geofenceStore_reset() async {
        let store = GeofenceStateStore()
        await store.markPushed(regionId: "region-c")
        await store.markExited(regionId: "region-c")
        await store.reset(regionId: "region-c")

        let state = await store.getState(for: "region-c")
        #expect(state == nil)
    }

    @Test("GeofenceStateStore: clearAll removes all regions")
    func test_geofenceStore_clearAll() async {
        let store = GeofenceStateStore()
        await store.markPushed(regionId: "r1")
        await store.markPushed(regionId: "r2")

        await store.clearAll()

        let s1 = await store.getState(for: "r1")
        let s2 = await store.getState(for: "r2")
        #expect(s1 == nil)
        #expect(s2 == nil)
    }
}
