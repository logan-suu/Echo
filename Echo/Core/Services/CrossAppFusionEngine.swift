// ==========================================
// 文件: CrossAppFusionEngine.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-010 AC-2 (逐源授权),
//            AC-3 (时间窗对齐), AC-4 (来源标签), AC-5 (.crossAppSearch 审计含实际授权列表),
//            docs/05-planning/phase3f-execution-plan.md → §3F.6 Interfaces
//            (temporal-aligned multi-source fusion with source labels;
//             .crossAppSearch audit carrying the authorized source list)
// 任务: 3F.6 - Production search 与 feedback（跨 App 检索生产融合引擎）
// AC 覆盖: US-SRC-010 AC-2 (Privacy Gate 逐源授权 — 未授权源 provider 不被调用),
//          AC-3 (多源联合检索按时间窗对齐 + 时间戳升序), AC-4 (结果标注 sourceType 标签),
//          AC-5 (审计 .crossAppSearch 记录【实际授权】source 列表，非请求列表)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-006 (PrivacyCheckpoint 入口),
//           R-007 (禁止 unchecked Sendable / Combine), R-008 (跨 Actor 调用必须 await),
//           AGENTS.md §5.4 (审计仅记录哈希摘要，禁止原文)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated。
//       协议/类型命名规避测试模块同名声明的 CrossAppFusionEngine 冲突：
//       测试内联契约（EchoTests）声明 `public protocol CrossAppFusionEngine`，
//       @testable import 使两处同名声明在 EchoTests 模块内重复定义，
//       故生产协议命名为 CrossAppSearchFusionEngine、实现为 ProductionCrossAppFusionEngine，
//       行为契约与测试内联实现完全一致。
// 状态: GREEN — 3F.6 实现完成（生产融合引擎）
// 生成时间: 2026-08-11
// ==========================================

import Foundation

// MARK: - Cross App Search Fusion Engine Protocol

/// 跨 App 多源融合检索引擎协议（US-SRC-010 AC-2~AC-5）。
///
/// 生产实现（`ProductionCrossAppFusionEngine`）按此契约落地：
/// 逐源 Privacy Gate（未授权源不调用 provider，fail-closed）→ 多源检索 →
/// 时间窗对齐 → 保留 sourceType 标签 → 审计 `.crossAppSearch`（实际授权源列表）。
///
/// > 命名说明：测试模块（EchoTests）内联声明了同名 `CrossAppFusionEngine` 契约，
/// > 为避免 `@testable import` 下的重复定义冲突，生产协议使用 `CrossAppSearchFusionEngine`。
public protocol CrossAppSearchFusionEngine: Sendable {
    /// 执行跨 App 多源检索融合。
    ///
    /// - Parameters:
    ///   - intent: 已解析的跨 App 检索意图（含域、请求源列表、时间窗、主观标记）
    ///   - traceID: 由 Pipeline 入口生成的追踪 ID（审计强制字段）
    /// - Returns: 融合后的结果列表（时间窗过滤 + 时间戳升序，保留 sourceType 标签）
    /// - Throws: `CrossAppIntentError.unauthorizedSource`（R-006 校验拒绝）
    nonisolated func search(intent: CrossAppIntent, traceID: String) async throws -> [CrossAppSourceResult]
}

// MARK: - Production Cross App Fusion Engine

/// 生产跨 App 融合检索引擎（US-SRC-010 AC-2~AC-5）。
///
/// ## 执行流水线
/// 1. **PrivacyCheckpoint（R-006）**：入口 `privacy.validate(operation: .search, sourceTypes:)`，
///    `.denied` 时立即终止并抛 `.unauthorizedSource`（fail-closed）
/// 2. **逐源授权门（AC-2）**：仅对 `intent.sources ∩ policy.authorizedSourceTypes` 调用 provider，
///    未授权源 provider 一律不 invoke
/// 3. **多源检索**：并行安全地顺序 await 各授权 provider（Actor 串行，R-008）
/// 4. **时间窗对齐（AC-3）**：`intent.temporalWindow` 过滤窗口外结果 + 时间戳升序
/// 5. **来源标签（AC-4）**：每条 `CrossAppSourceResult` 保留 sourceType（展示层映射图标）
/// 6. **审计（AC-5）**：`.crossAppSearch` 写入 AuditLog，sourceType 字段记录
///    【实际授权】源列表（逗号分隔），非请求列表
///
/// ## Actor 隔离（AGENTS.md §4.2）
/// - 持有 PrivacyActor + provider 列表（均为不可变引用，跨 Actor 调用必须 await）
/// - 无本地可变状态
public actor ProductionCrossAppFusionEngine: CrossAppSearchFusionEngine {

    // MARK: - Properties

    /// 隐私校验与审计 Actor（R-006 + AC-5 审计写入）
    private let privacy: PrivacyActor
    /// 已注册的跨 App 数据源 provider（按 sourceType 匹配授权分发）
    private let providers: [any CrossAppSourceProvider]

    // MARK: - Initialization

    public init(privacy: PrivacyActor, providers: [any CrossAppSourceProvider]) {
        self.privacy = privacy
        self.providers = providers
    }

    // MARK: - CrossAppSearchFusionEngine

    public nonisolated func search(
        intent: CrossAppIntent,
        traceID: String
    ) async throws -> [CrossAppSourceResult] {
        // AC-2: 逐源授权（US-SRC-010）— 先求 authorized 交集（PR#58 CR-7）：
        // 部分授权不应整查询 fail-closed，未授权源跳过、授权源继续；空子集才抛 unauthorizedSource。
        let policy = await privacy.getPolicy()
        let authorized = intent.sources.filter { policy.isAuthorized(sourceType: $0) }
        guard !authorized.isEmpty else {
            throw CrossAppIntentError.unauthorizedSource(sourceType: intent.sources.joined(separator: ","))
        }

        // R-006: 入口 Checkpoint（仅校验已授权子集；同意闸门 deny-by-default 仍在此生效）
        let checkpoint = await privacy.validate(
            operation: .search,
            traceID: traceID,
            sourceTypes: authorized
        )
        guard checkpoint.isAllowed else {
            throw CrossAppIntentError.unauthorizedSource(sourceType: intent.sources.joined(separator: ","))
        }

        // AC-2: 拒绝分发 — 未授权源不得调用 provider（fail-closed）
        var fused: [CrossAppSourceResult] = []
        for provider in providers where authorized.contains(provider.sourceType) {
            // PR#58 CR-8: 单 provider 失败/超时被隔离，不丢弃已融合结果（AC-3/AC-5 继续）
            do {
                let results = try await Self.withProviderTimeout(seconds: Self.providerTimeoutSeconds) {
                    try await provider.search(query: intent.query, window: intent.temporalWindow)
                }
                fused.append(contentsOf: results)
            } catch {
                // 该源失败/超时 → 跳过该源，继续其他源
            }
        }

        // AC-3: 时间窗对齐 — 过滤窗口外结果 + 时间戳升序
        if let window = intent.temporalWindow {
            fused = fused.filter { window.contains(Date(timeIntervalSince1970: $0.timestamp)) }
        }
        fused.sort { $0.timestamp < $1.timestamp }

        // AC-5: 审计 `.crossAppSearch` — 记录【实际授权】源列表（非请求列表），hash-only
        let auditSources = authorized.sorted().joined(separator: ",")
        // PR#58 CR-31: 审计写入 best-effort（与 SearchPipeline 一致），失败不丢弃已融合结果
        try? await privacy.writeAuditLog(
            eventType: .crossAppSearch,
            traceID: traceID,
            policyVersion: policy.policyVersion,
            success: true,
            sourceType: auditSources.isEmpty ? nil : auditSources,
            affectedCount: fused.count
        )

        return fused
    }

    /// 单 provider 检索超时阈值（秒，PR#58 CR-8）
    private nonisolated static let providerTimeoutSeconds: Double = 2.0

    /// 带超时的 provider 检索封装（竞速模式；超时抛 CancellationError 由调用方隔离）。
    private nonisolated static func withProviderTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            guard let result = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            do { _ = try await group.next() } catch { /* cancelled, expected */ }
            return result
        }
    }
}
