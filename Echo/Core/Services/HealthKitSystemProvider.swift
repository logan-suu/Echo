// ==========================================
// 文件: HealthKitSystemProvider.swift
// 对应规格: docs/decisions/ADR-012-awakening-system-boundary.md 决策-2 (权限感知),
//            决策-4 (HealthKit 数据最小化 — 不存原始健康值),
//            docs/01-spec/用户故事与验收标准规格书.md → US-AWK-003 AC-1 (HealthKit 情绪推断),
//            US-SRC-010 (live HealthKit provider conformance → 3F.6 fusion)
// 任务: 3F.8 - Awakening 与 system adapters
// AC 覆盖: US-AWK-003 AC-1 ✅ (心率变异性推断情绪, 经 HealthKitProvider 协议),
//          US-SRC-010 AC-2 ✅ (denied 来源不查询 — 授权检查失败即返空/不调用底层),
//          US-SRC-010 AC-3 ✅ (时间窗内最小化样本映射, 保留来源身份 sourceType="health"),
//          ADR-012 决策-2 (denied/accepted 全状态), 决策-4 (仅最小化时序样本, 不存原始健康值)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007 (禁止 unchecked Sendable 于业务代码;
//           @preconcurrency import HealthKit + MainActor.run 系统框架边界同 PhotoKit 模式),
//           R-001 (纯本地, 无网络)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，struct stored/computed 需 nonisolated
//       生产 provider 仅返回「最小化时序样本」(timestamp + 来源身份)，不存储/不透传原始健康值
// PR Review fix (2026-08-11): semaphore → withCheckedContinuation; UUID 强解包 → compactMap guard
// 生成时间: 2026-08-11
// ==========================================

import Foundation
@preconcurrency import HealthKit

// MARK: - Minimized Health Sample

/// 最小化健康时序样本（ADR-012 决策-4: 不存原始健康值，仅保留时间与最小派生值）。
public struct MinimizedHealthSample: Sendable, Equatable {
    /// 样本时间戳（epoch 秒）
    public nonisolated let timestamp: TimeInterval
    /// 心率变异性派生值（最小化：仅 HRV 数值用于情绪推断，不保留完整健康记录）
    public nonisolated let hrvValue: Double

    public nonisolated init(timestamp: TimeInterval, hrvValue: Double) {
        self.timestamp = timestamp
        self.hrvValue = hrvValue
    }
}

// MARK: - Health Auth State

/// HealthKit 授权状态（ADR-012 决策-2 全状态处理）
public enum HealthAuthState: String, Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
}

// MARK: - Health Store Serving

/// HealthKit 存储服务协议 — 抽象 HKHealthStore 边界，支持测试注入 Fake。
///
/// 生产实现 `RealHealthStore` 经 MainActor.run 访问 @MainActor HKHealthStore；
/// 仅返回值类型（HealthAuthState / MinimizedHealthSample），HKQuantitySample 不跨边界。
public protocol HealthStoreServing: Sendable {
    /// 设备是否支持 HealthKit
    nonisolated func isHealthDataAvailable() -> Bool
    /// 当前授权状态
    nonisolated func currentAuthorizationState() async -> HealthAuthState
    /// 请求 HRV 读取授权
    nonisolated func requestAuthorization() async -> HealthAuthState
    /// 读取指定时间窗内的心率变异性样本（授权被拒时返回空数组，不触发底层查询）
    nonisolated func fetchHRVSamples(in window: ClosedRange<Date>?) async throws -> [MinimizedHealthSample]
}

// MARK: - Real Health Store

/// 真实 HealthKit 实现（@preconcurrency import HealthKit，经 MainActor.run 访问 SDK）。
public struct RealHealthStore: HealthStoreServing {

    private let store: HKHealthStore

    public nonisolated init() {
        self.store = HKHealthStore()
    }

    public nonisolated func isHealthDataAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    public nonisolated func currentAuthorizationState() async -> HealthAuthState {
        await MainActor.run {
            let hrvType = HKQuantityType(.heartRateVariabilitySDNN)
            switch self.store.authorizationStatus(for: hrvType) {
            case .notDetermined: return .notDetermined
            case .sharingDenied: return .denied
            case .sharingAuthorized: return .authorized
            @unknown default: return .denied
            }
        }
    }

    public nonisolated func requestAuthorization() async -> HealthAuthState {
        let hrvType = HKQuantityType(.heartRateVariabilitySDNN)
        let types: Set<HKSampleType> = [hrvType]
        let granted = await withCheckedContinuation { continuation in
            self.store.requestAuthorization(toShare: nil, read: types) { success, _ in
                continuation.resume(returning: success)
            }
        }
        return granted ? .authorized : .denied
    }

    public nonisolated func fetchHRVSamples(in window: ClosedRange<Date>?) async throws -> [MinimizedHealthSample] {
        // ADR-012 决策-2: 授权被拒时不查询底层
        let auth = await currentAuthorizationState()
        guard auth == .authorized else { return [] }

        let hrvType = HKQuantityType(.heartRateVariabilitySDNN)
        let predicate: NSPredicate?
        if let window {
            predicate = HKQuery.predicateForSamples(
                withStart: window.lowerBound,
                end: window.upperBound,
                options: .strictStartDate
            )
        } else {
            predicate = nil
        }

        let samples: [HKQuantitySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrvType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
            }
            self.store.execute(query)
        }

        return samples.map { sample in
            MinimizedHealthSample(
                timestamp: sample.startDate.timeIntervalSince1970,
                hrvValue: sample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
            )
        }
    }
}

// MARK: - Health Kit System Provider

/// 生产 HealthKit 系统适配器 — 同时符合：
/// 1. `CrossAppSourceProvider`（3F.6 注入协议, US-SRC-010）：sourceType="health"，
///    向 health+memory 融合提供授权范围内时间窗内的最小化样本，保留来源身份（.crossAppSearch）
/// 2. `HealthKitProvider`（US-AWK-003 AC-1）：基于 HRV 推断情绪状态
///
/// 数据最小化（ADR-012 决策-4）：不存储原始健康值；`search` 仅返回时间窗内的
/// 最小化样本映射结果，来源身份始终为 "health"。
public final class HealthKitSystemProvider: HealthKitProvider, CrossAppSourceProvider {

    // MARK: - Properties

    /// 数据源类型（US-SRC-010: health）
    public nonisolated let sourceType = "health"

    /// 底层健康存储 — Awakening 设置页权限状态读取（ADR-012 决策-2）
    public nonisolated let store: any HealthStoreServing

    // MARK: - Init

    public nonisolated init(store: any HealthStoreServing = RealHealthStore()) {
        self.store = store
    }

    // MARK: - CrossAppSourceProvider (US-SRC-010)

    /// 在指定时间窗内检索该数据源（US-SRC-010 AC-3）。
    ///
    /// - 授权检查前置（ADR-012 决策-2）：未授权 → 返回空数组（不查询底层，fail-closed）
    /// - 最小化：仅返回 `MinimizedHealthSample.timestamp` 映射结果，保留 sourceType="health"
    /// - 返回结果按时间戳升序
    public nonisolated func search(
        query: String,
        window: ClosedRange<Date>?
    ) async throws -> [CrossAppSourceResult] {
        let auth = await store.currentAuthorizationState()
        guard auth == .authorized else { return [] }

        let samples = try await store.fetchHRVSamples(in: window)
        return samples.compactMap { sample -> CrossAppSourceResult? in
            let suffix = Self.healthID(from: sample.timestamp)
            guard let memoryId = UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") else { return nil }
            return CrossAppSourceResult(
                memoryId: memoryId,
                sourceType: sourceType,
                timestamp: sample.timestamp,
                snippet: nil,
                matchScore: Self.normalizedMatch(for: sample.hrvValue)
            )
        }
    }

    // MARK: - HealthKitProvider (US-AWK-003 AC-1)

    /// 设备是否支持 HealthKit
    public nonisolated func isHealthDataAvailable() -> Bool {
        store.isHealthDataAvailable()
    }

    /// 请求 HealthKit 授权
    public nonisolated func requestAuthorization() async -> Bool {
        let state = await store.requestAuthorization()
        return state == .authorized
    }

    /// 从 HRV 数据推断情绪状态（US-AWK-003 AC-1）。
    ///
    /// 数据最小化：仅使用最小化 HRV 数值；返回 nil 表示数据不足/不确定。
    public nonisolated func inferMoodFromHRV() async -> MoodState? {
        let auth = await store.currentAuthorizationState()
        guard auth == .authorized else { return nil }

        let samples = (try? await store.fetchHRVSamples(in: nil)) ?? []
        guard !samples.isEmpty else { return nil }

        // 低 HRV（高交感/压力）→ negative；中 HRV → neutral；高 HRV → positive
        // （最小化启发式：不依赖完整健康记录，仅聚合 HRV 均值）
        let mean = samples.reduce(0.0) { $0 + $1.hrvValue } / Double(samples.count)
        if mean < 30 { return .negative }
        if mean < 60 { return .neutral }
        return .positive
    }

    // MARK: - Private Helpers

    /// 从时间戳派生稳定 12-char 十六进制 health memoryId 后缀（确定性，来源身份保留）。
    ///
    /// 使用 FNV-1a 风格确定性哈希（非 Swift `hashValue`，其跨进程不稳定），
    /// 同一时间戳恒映射同一后缀 → 融合去重与测试断言均确定。
    private nonisolated static func healthID(from timestamp: TimeInterval) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let bytes = withUnsafeBytes(of: Int64(timestamp * 1000)) { Array($0) }
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%012x", hash & 0xFFFF_FFFF_FFFF)
    }

    /// HRV 数值 → 0~1 匹配分数（源内相关性启发式，时间窗过滤后样本恒为命中）。
    private nonisolated static func normalizedMatch(for hrv: Double) -> Float {
        let clamped = min(max(hrv / 100.0, 0.0), 1.0)
        return Float(clamped == 0 ? 0.5 : clamped)
    }
}
