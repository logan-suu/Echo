// ==========================================
// File: SystemMonitor.swift
// Spec: docs/01-spec/用户故事与验收标准规格书.md → US-RES-002 AC-1 (low power detection),
//       US-RES-003 AC-1 (ProcessInfo.ThermalState monitoring)
// Task: 3F.10 - i18n, accessibility and production errors
// AC coverage: US-RES-002 AC-1 (isLowPowerModeEnabled source), US-RES-003 AC-1 (.serious+ threshold)
// Architecture: AGENTS.md R-007 (no Combine — NotificationCenter async sequences only),
//               §4.2 (actor/MainActor isolation), docs/ui/architecture.md §6 (observable state)
// Pattern: AsyncStream event forwarding per Echo/Core/Services/CoreLocationProvider.swift (3F.8)
// Generated: 2026-08-12
// ==========================================

import Foundation
import Observation

@MainActor
public protocol SystemConditionSource: AnyObject {
    var isLowPowerMode: Bool { get }
    var thermalState: ProcessInfo.ThermalState { get }
    var conditionChanges: AsyncStream<Void> { get }
}

@MainActor
public final class ProcessInfoConditionSource: SystemConditionSource {

    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    public init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let cont = continuation
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                        cont.yield()
                    }
                }
                group.addTask {
                    for await _ in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                        cont.yield()
                    }
                }
            }
        }
    }

    public var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    public var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    public var conditionChanges: AsyncStream<Void> {
        stream
    }
}

@MainActor
@Observable
public final class SystemMonitor {

    public private(set) var isLowPowerMode: Bool = false
    public private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    public var isThermalDegraded: Bool {
        thermalState == .serious || thermalState == .critical
    }

    private let source: any SystemConditionSource
    private var observationTask: Task<Void, Never>?
    private let outputStream: AsyncStream<Void>
    private let outputContinuation: AsyncStream<Void>.Continuation

    public var conditionChanges: AsyncStream<Void> {
        outputStream
    }

    public init(source: any SystemConditionSource = ProcessInfoConditionSource()) {
        self.source = source
        (outputStream, outputContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    public func start() async {
        guard observationTask == nil else { return }
        refresh()
        observationTask = Task { [weak self] in
            guard let source = self?.source else { return }
            for await _ in source.conditionChanges {
                self?.refresh()
            }
        }
    }

    public func stop() async {
        observationTask?.cancel()
        observationTask = nil
    }

    private func refresh() {
        isLowPowerMode = source.isLowPowerMode
        thermalState = source.thermalState
        outputContinuation.yield()
    }
}
