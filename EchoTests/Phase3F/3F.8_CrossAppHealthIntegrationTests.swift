// ==========================================
// 文件: 3F.8_CrossAppHealthIntegrationTests.swift
// 对应规格: docs/decisions/ADR-012-awakening-system-boundary.md 决策-2/4
//            docs/01-spec/用户故事与验收标准规格书.md → US-SRC-010 (跨 App 数据关联搜索),
//            US-AWK-003 AC-1 (HealthKit 情绪推断)
// 任务: 3F.8 - Awakening 与 system adapters（live HealthKit provider conformance → 3F.6 fusion）
// AC coverage: US-SRC-010 AC-2 (empty HealthKit samples return no source result),
//          US-SRC-010 AC-3 ✅ (时间窗内最小化样本映射, 来源身份保留),
//          US-SRC-010 AC-4 ✅ (结果标注 sourceType="health"),
//          US-SRC-010 AC-5 ✅ (.crossAppSearch 审计实际授权源列表),
//          ADR-012 决策-4 ✅ (HealthKitSystemProvider 符合 3F.6 注入 provider 协议,
//          仅最小化时序样本, 不存原始健康值)
// 架构约束: AGENTS.md §9.1 (单元测试), R-007, 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// 生成时间: 2026-08-11
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Suite: Cross App Health Integration (3F.8)

@Suite("CrossAppHealthIntegrationTests", .serialized)
@MainActor
struct CrossAppHealthIntegrationTests {

    let db = DatabaseManager.shared
    let privacyActor = PrivacyActor.shared

    // MARK: - Setup & Teardown

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
    }

    // MARK: - HealthKitSystemProvider → CrossAppSourceProvider (ADR-012 决策-4)

    @Test("AC-3/AC-4: live provider conforms with sourceType health and returns window samples")
    func providerConformanceAndWindowMapping() async throws {
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["health", "memory", "photo"],
            policyVersion: 1
        ))
        let store = CrossAppStubHealthStore()
        let now = Date().timeIntervalSince1970
        store.samples = [
            MinimizedHealthSample(timestamp: now - 3600, hrvValue: 40),
            MinimizedHealthSample(timestamp: now, hrvValue: 80),
        ]
        let provider = HealthKitSystemProvider(store: store)

        let windowStart = Date(timeIntervalSince1970: now - 7200)
        let windowEnd = Date(timeIntervalSince1970: now - 60)
        let results = try await provider.search(
            query: "失眠日记",
            window: windowStart...windowEnd
        )

        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.sourceType == "health" })
        #expect(results.allSatisfy { $0.timestamp >= windowStart.timeIntervalSince1970 })
        #expect(results.allSatisfy { $0.timestamp <= windowEnd.timeIntervalSince1970 })
        // 来源身份保留（US-SRC-010 AC-4）— 每条结果 memoryId 非零且确定
        #expect(results.allSatisfy { $0.memoryId.uuidString != "00000000-0000-0000-0000-000000000000" })
    }

    @Test("AC-2: no readable HealthKit samples returns an empty result")
    func noReadableHealthKitSamplesReturnsEmpty() async throws {
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["health", "memory"],
            policyVersion: 2
        ))
        let store = CrossAppStubHealthStore()
        store.samples = []
        let provider = HealthKitSystemProvider(store: store)

        let results = try await provider.search(
            query: "心率超120",
            window: Date(timeIntervalSince1970: 0)...Date()
        )
        #expect(results.isEmpty)
    }

    @Test("AC-2: no window → provider returns all authorized minimized samples")
    func providerNoWindowReturnsAllSamples() async throws {
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["health"],
            policyVersion: 3
        ))
        let store = CrossAppStubHealthStore()
        store.samples = [
            MinimizedHealthSample(timestamp: Date().timeIntervalSince1970 - 300, hrvValue: 35),
            MinimizedHealthSample(timestamp: Date().timeIntervalSince1970 - 200, hrvValue: 65),
        ]
        let provider = HealthKitSystemProvider(store: store)
        let results = try await provider.search(query: "运动照片", window: nil)
        #expect(results.count == 2)
    }

    // MARK: - Live provider → 3F.6 fusion integration (US-SRC-010)

    @Test("Authorized health samples reach 3F.6 fusion with source identity")
    func fusionIntegratesHealthProvider() async throws {
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["health", "memory"],
            policyVersion: 4
        ))
        let store = CrossAppStubHealthStore()
        let now = Date().timeIntervalSince1970
        store.samples = [
            MinimizedHealthSample(timestamp: now, hrvValue: 75)
        ]
        let healthProvider = HealthKitSystemProvider(store: store)
        let memoryProvider = StubMemoryProvider()
        let engine = ProductionCrossAppFusionEngine(
            privacy: privacyActor,
            providers: [healthProvider, memoryProvider]
        )

        let intent = CrossAppIntent(
            domain: .healthMemory,
            sources: ["health", "memory"],
            query: "失眠日记"
        )
        let fused = try await engine.search(intent: intent, traceID: "trace-fusion-health")

        // AC-4: 来源标签保留 — 至少包含一条 health 结果
        #expect(fused.contains { $0.sourceType == "health" })
        // AC-3: 时间戳升序
        let timestamps = fused.map(\.timestamp)
        #expect(timestamps == timestamps.sorted())
    }

    @Test("Denied health source excluded from fusion; memory source still fused")
    func fusionSkipsDeniedHealthSource() async throws {
        // 授权仅 memory，不含 health → 未授权 health 源不被调用
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["memory"],
            policyVersion: 5
        ))
        let store = CrossAppStubHealthStore()
        store.samples = [MinimizedHealthSample(timestamp: Date().timeIntervalSince1970, hrvValue: 70)]
        let healthProvider = HealthKitSystemProvider(store: store)
        let memoryProvider = StubMemoryProvider()
        let engine = ProductionCrossAppFusionEngine(
            privacy: privacyActor,
            providers: [healthProvider, memoryProvider]
        )

        let intent = CrossAppIntent(
            domain: .healthMemory,
            sources: ["health", "memory"],
            query: "失眠日记"
        )
        let fused = try await engine.search(intent: intent, traceID: "trace-fusion-denied")

        // AC-2: 未授权 health 源不参与融合（fail-closed）
        #expect(!fused.contains { $0.sourceType == "health" })
        #expect(fused.contains { $0.sourceType == "memory" })
    }

    @Test("Fusion writes .crossAppSearch audit with authorized source list")
    func fusionWritesCrossAppAudit() async throws {
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["health", "memory"],
            policyVersion: 6
        ))
        let store = CrossAppStubHealthStore()
        store.samples = [MinimizedHealthSample(timestamp: Date().timeIntervalSince1970, hrvValue: 60)]
        let engine = ProductionCrossAppFusionEngine(
            privacy: privacyActor,
            providers: [HealthKitSystemProvider(store: store)]
        )
        let intent = CrossAppIntent(domain: .healthMemory, sources: ["health", "memory"], query: "失眠日记")
        _ = try await engine.search(intent: intent, traceID: "trace-cross-app-audit")

        let logs = try await privacyActor.fetchAuditLogs(limit: 5, eventType: .crossAppSearch)
        let log = try #require(logs.first, "Expected .crossAppSearch audit")
        #expect(log.sourceType?.contains("health") == true)
    }

    // MARK: - ADR-012 决策-4: Data Minimization

    @Test("Provider does not expose raw health values — only timestamp via results")
    func dataMinimizationNoRawValues() async throws {
        let store = CrossAppStubHealthStore()
        store.samples = [
            MinimizedHealthSample(timestamp: Date().timeIntervalSince1970, hrvValue: 45)
        ]
        let provider = HealthKitSystemProvider(store: store)
        let results = try await provider.search(query: "睡眠", window: nil)
        #expect(results.count == 1)
        // CrossAppSourceResult 仅含 timestamp/sourceType/snippet/matchScore — 无原始 HRV 值透传
        #expect(results.first?.snippet == nil)
        #expect((results.first?.matchScore ?? 0) >= 0)
    }
}

// MARK: - Test Doubles

/// 确定性 HealthKit 存储（同 3F.8_AwakeningSystemAdaptersTests 内 StubHealthStore）
final class CrossAppStubHealthStore: HealthStoreServing, @unchecked Sendable {
    var available = true
    var authState: HealthAuthState = .authorized
    var samples: [MinimizedHealthSample] = []
    var fetchWindow: ClosedRange<Date>?

    func isHealthDataAvailable() -> Bool { available }
    func currentAuthorizationState() async -> HealthAuthState { authState }
    func requestAuthorization() async -> HealthAuthState { authState }
    func fetchHRVSamples(in window: ClosedRange<Date>?) async throws -> [MinimizedHealthSample] {
        fetchWindow = window
        if let window {
            return samples.filter {
                window.contains(Date(timeIntervalSince1970: $0.timestamp))
            }
        }
        return samples
    }
}

/// 固定 memory 源结果提供者（供 fusion 联调）
final class StubMemoryProvider: CrossAppSourceProvider, @unchecked Sendable {
    var sourceType: String { "memory" }

    func search(query: String, window: ClosedRange<Date>?) async throws -> [CrossAppSourceResult] {
        [
            CrossAppSourceResult(
                memoryId: UUID(),
                sourceType: "memory",
                timestamp: Date().timeIntervalSince1970 - 60,
                snippet: "失眠日记",
                matchScore: 0.85
            ),
        ]
    }
}
