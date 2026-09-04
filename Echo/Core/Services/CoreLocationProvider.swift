// ==========================================
// 文件: CoreLocationProvider.swift
// 对应规格: docs/decisions/ADR-012-awakening-system-boundary.md 决策-2 (权限感知),
//            决策-3 (系统适配器真实化 — CoreLocationProvider 接入生产)
//            docs/01-spec/用户故事与验收标准规格书.md → US-AWK-001 (地理围栏进入/离开),
//            US-AWK-002 (best-effort 日期窗口)
// Task: 3F.8 + 4.0f - Awakening system adapter and staged location authorization
// AC 覆盖: US-AWK-001 AC-1 (仅 didEnter 触发), AC-2 (离开重置/永不重复推送),
//          AC-5 (定位权限关闭静默禁用, 重开后不立即推送), AC-6 (.contextualAwakening 审计),
//          4.0f AC-5 (staged authorization, callback completion, overlapping waiter coalescing)
// 架构约束: AGENTS.md §4.2 (Actor 隔离 — 仅值类型跨边界传递),
//           R-007 (禁止 unchecked Sendable 于业务代码; 系统框架边界采用 PhotoKit 同款
//           @preconcurrency + MainActor 模式), 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// 重要: CLLocationManager 为 @MainActor SDK，类默认 MainActor 隔离（正确持有 manager）；
//       CLLocationManagerDelegate 为 nonisolated 同步回调，经 Task { @MainActor } 转发事件
// PR Review fix (2026-08-11): onGeofenceEvent 回调 → AsyncStream<GeofenceEvent> eventStream,
//          显式 @MainActor 协议+类隔离 — 修复 CI Xcode 16.4 'Sendable-conforming class is mutable'
// Generated: 2026-08-11; updated: 2026-09-04 (4.0f)
// ==========================================

import Foundation
@preconcurrency import CoreLocation

// MARK: - Location Auth State

/// 定位授权状态（覆盖 CoreLocation 全状态，ADR-012 决策-2）
public enum LocationAuthState: String, Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorizedWhenInUse
    case authorizedAlways
}

/// CLAuthorizationStatus → LocationAuthState 纯函数映射（测试可注入）
public enum LocationAuthMapper {
    public nonisolated static func map(_ status: CLAuthorizationStatus) -> LocationAuthState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted:    return .restricted
        case .denied:        return .denied
        case .authorizedWhenInUse: return .authorizedWhenInUse
        case .authorizedAlways:    return .authorizedAlways
        @unknown default:    return .denied
        }
    }
}

// MARK: - Geofence Region

/// 地理围栏注册参数（仅值类型，跨 Actor 传递合法）
public struct GeofenceRegion: Sendable, Equatable {
    public nonisolated let identifier: String
    public nonisolated let latitude: Double
    public nonisolated let longitude: Double
    public nonisolated let radiusMeters: Double

    public nonisolated init(
        identifier: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double
    ) {
        self.identifier = identifier
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
    }
}

// MARK: - Geofence Event

/// 地理围栏系统事件（US-AWK-001 AC-1/AC-2: 仅 enter 触发唤醒，exit 重置）
public enum GeofenceEvent: Sendable, Equatable {
    case enter(regionIdentifier: String)
    case exit(regionIdentifier: String)
}

// MARK: - Location Providing

/// 定位服务提供协议 — 抽象 CoreLocation 边界，支持测试注入 Fake。
///
/// 生产实现 `CoreLocationProvider` 包装 CLLocationManager；测试可注入
/// 确定性事件流（ADR-012 决策-3 "injected test system signals"）。
/// 仅传递值类型（LocationAuthState / GeofenceRegion / GeofenceEvent）。
@MainActor
public protocol LocationProviding: AnyObject, Sendable {
    /// 地理围栏事件流（enter/exit）— 替代回调，消除 Sendable 类可变存储属性（CI Xcode 16.4 阻断）
    var eventStream: AsyncStream<GeofenceEvent> { get }

    /// 当前授权状态
    func currentAuthorizationState() async -> LocationAuthState
    /// 请求使用时定位授权（US-AWK-001 AC-5）
    func requestWhenInUseAuthorization() async -> LocationAuthState
    /// Requests the separate Always upgrade after the user has enabled background awakening.
    func requestAlwaysAuthorization() async -> LocationAuthState
    /// 开始监控地理围栏（US-AWK-001）
    func startMonitoring(region: GeofenceRegion) async throws
    /// 停止监控地理围栏
    func stopMonitoring(regionIdentifier: String) async
    /// 当前已注册的地理围栏
    func monitoredRegions() async -> [GeofenceRegion]
}

public extension LocationProviding {
    func requestAlwaysAuthorization() async -> LocationAuthState {
        await currentAuthorizationState()
    }
}

@MainActor
final class LocationAuthorizationWaiter {
    private var continuations: [CheckedContinuation<LocationAuthState, Never>] = []

    func wait(request: () -> Void) async -> LocationAuthState {
        await withCheckedContinuation { continuation in
            let shouldRequest = continuations.isEmpty
            continuations.append(continuation)
            if shouldRequest { request() }
        }
    }

    func resolve(with state: LocationAuthState) {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: state) }
    }
}

// MARK: - Core Location Provider

/// 真实 CoreLocation 实现（@preconcurrency import CoreLocation，默认 MainActor 隔离）。
///
/// - 授权状态全处理（ADR-012 决策-2）：notDetermined/denied/restricted/authorized 均映射
/// - 地理围栏监控：`startMonitoring` 注册 CLCircularRegion，didEnter/didExit 转发事件
/// - 权限感知：授权被拒时 `startMonitoring` 抛 `.privacyDenied`（AC-5 静默禁用语义）；
///   `eventStream` 由调用方（AppDelegate）以 for-await 消费并转发 AwakeningPipeline
@MainActor
public final class CoreLocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {

    // MARK: - Properties

    private let manager: CLLocationManager
    /// 地理围栏事件流存储（AsyncStream.makeStream 全 let 模式，无可变存储 — 修复 CI Sendable 错误）
    private let eventStreamStorage: AsyncStream<GeofenceEvent>
    private let eventContinuation: AsyncStream<GeofenceEvent>.Continuation
    private let authorizationWaiter = LocationAuthorizationWaiter()

    // MARK: - Init

    public override init() {
        (self.eventStreamStorage, self.eventContinuation) = AsyncStream.makeStream(of: GeofenceEvent.self)
        self.manager = CLLocationManager()
        super.init()
        self.manager.delegate = self
        self.manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    // MARK: - LocationProviding

    public var eventStream: AsyncStream<GeofenceEvent> { eventStreamStorage }

    public func currentAuthorizationState() async -> LocationAuthState {
        LocationAuthMapper.map(manager.authorizationStatus)
    }

    public func requestWhenInUseAuthorization() async -> LocationAuthState {
        let current = LocationAuthMapper.map(manager.authorizationStatus)
        guard current == .notDetermined else { return current }
        return await waitForAuthorizationChange {
            manager.requestWhenInUseAuthorization()
        }
    }

    public func requestAlwaysAuthorization() async -> LocationAuthState {
        let current = LocationAuthMapper.map(manager.authorizationStatus)
        guard current == .authorizedWhenInUse else { return current }
        return await waitForAuthorizationChange {
            manager.requestAlwaysAuthorization()
        }
    }

    private func waitForAuthorizationChange(_ request: () -> Void) async -> LocationAuthState {
        await authorizationWaiter.wait(request: request)
    }

    public func startMonitoring(region: GeofenceRegion) async throws {
        let status = LocationAuthMapper.map(manager.authorizationStatus)
        guard status != .denied, status != .restricted else {
            throw AwakeningError.privacyDenied(sourceTypes: ["geofence"])
        }
        let circular = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude),
            radius: region.radiusMeters,
            identifier: region.identifier
        )
        circular.notifyOnEntry = true
        circular.notifyOnExit = true
        manager.startMonitoring(for: circular)
    }

    public func stopMonitoring(regionIdentifier: String) async {
        let regions = manager.monitoredRegions.filter { $0.identifier == regionIdentifier }
        for region in regions {
            manager.stopMonitoring(for: region)
        }
    }

    public func monitoredRegions() async -> [GeofenceRegion] {
        manager.monitoredRegions.compactMap { region in
            guard let circular = region as? CLCircularRegion else { return nil }
            return GeofenceRegion(
                identifier: circular.identifier,
                latitude: circular.center.latitude,
                longitude: circular.center.longitude,
                radiusMeters: circular.radius
            )
        }
    }

    // MARK: - CLLocationManagerDelegate

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let state = LocationAuthMapper.map(manager.authorizationStatus)
        guard state != .notDetermined else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationWaiter.resolve(with: state)
        }
    }

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didEnterRegion region: CLRegion
    ) {
        let event = GeofenceEvent.enter(regionIdentifier: region.identifier)
        Task { @MainActor [weak self] in
            self?.eventContinuation.yield(event)
        }
    }

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didExitRegion region: CLRegion
    ) {
        let event = GeofenceEvent.exit(regionIdentifier: region.identifier)
        Task { @MainActor [weak self] in
            self?.eventContinuation.yield(event)
        }
    }
}
