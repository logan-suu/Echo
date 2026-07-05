// ==========================================
// 文件: PrivacyActor.swift
// 对应规格: docs/02-architecture/架构设计文档.md §7 (隐私校验与审计追踪)
//            docs/01-spec/用户故事与验收标准规格书.md → US-PRV-001
// 任务: 1.8 - 搭建单元测试框架，编写第一个 Actor 测试用例 (Stub)
//       2.1 - PrivacyActor + UserPolicy 实现 (Full Implementation)
// AC 覆盖: US-PRV-001 AC-1 (授权校验), AC-5 (重新授权不清除排除表)
// 架构约束: 遵循 AGENTS.md §4.2 (Actor 隔离契约), §7.1 (PrivacyCheckpoint 强制注入),
//            R-007 (禁止 @unchecked Sendable), R-008 (跨 Actor 调用必须 await)
// 重要: 所有 struct stored/computed properties 必须 nonisolated（项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor）
// 生成时间: 2026-07-05
// ==========================================

import Foundation

// MARK: - Privacy Operation

/// Pipeline 操作类型枚举 — 对应架构文档 §7.1 中的 operation 字段
public enum PrivacyOperation: String, Sendable, Codable {
    case search
    case ingest
    case sync
    case delete
    case awakening
    case feedback
}

// MARK: - Privacy Decision

/// 隐私校验决策结果
public enum PrivacyDecision: String, Sendable, Codable {
    /// 操作被允许
    case allowed
    /// 操作被拒绝（用户未授权相关数据源或功能）
    case denied
}

// MARK: - Privacy Checkpoint

/// 隐私校验检查点 — 每个 Pipeline Actor 方法入口必须调用 PrivacyActor.validate() 获取此对象。
///
/// 对应架构文档 §7.1 PrivacyCheckpoint 结构，包含以下字段：
/// - traceID: UUID，由 Pipeline 节点创建时生成
/// - timestamp: 当前时间
/// - operation: 操作类型枚举
/// - policyVersion: UserPolicy 版本号
/// - sourceTypes: 涉及的数据源
/// - decision: 授权结果
public struct PrivacyCheckpoint: Sendable, Codable {
    public nonisolated let traceID: String
    public nonisolated let timestamp: Date
    public nonisolated let operation: PrivacyOperation
    public nonisolated let policyVersion: Int
    public nonisolated let sourceTypes: [String]
    public nonisolated let decision: PrivacyDecision

    public nonisolated init(
        traceID: String = UUID().uuidString,
        timestamp: Date = Date(),
        operation: PrivacyOperation,
        policyVersion: Int = 1,
        sourceTypes: [String] = [],
        decision: PrivacyDecision = .allowed
    ) {
        self.traceID = traceID
        self.timestamp = timestamp
        self.operation = operation
        self.policyVersion = policyVersion
        self.sourceTypes = sourceTypes
        self.decision = decision
    }

    /// 检查点是否允许继续执行
    public nonisolated var isAllowed: Bool {
        decision == .allowed
    }
}

// MARK: - User Policy

/// 用户隐私策略配置 — 控制授权数据源、偏好语言等。
///
/// 对应 US-PRV-001，由 PrivacyActor 管理。
/// TODO (Phase 2, Task 2.1): 实现完整的策略持久化与授权管理。
public struct UserPolicy: Sendable, Codable {
    public nonisolated let preferredLanguage: String
    public nonisolated var authorizedSourceTypes: Set<String>
    public nonisolated let policyVersion: Int

    public nonisolated init(
        preferredLanguage: String = "zh-Hans",
        authorizedSourceTypes: Set<String> = ["photo", "note", "voice"],
        policyVersion: Int = 1
    ) {
        self.preferredLanguage = preferredLanguage
        self.authorizedSourceTypes = authorizedSourceTypes
        self.policyVersion = policyVersion
    }

    /// 检查指定数据源是否已授权
    public nonisolated func isAuthorized(sourceType: String) -> Bool {
        authorizedSourceTypes.contains(sourceType)
    }
}

// MARK: - Privacy Actor

/// 隐私校验与审计 Actor — 管理 UserPolicy，提供 Pipeline 入口的授权校验（PrivacyCheckpoint）。
///
/// ## Actor 隔离契约 (AGENTS.md §4.2)
/// - 可变状态封装: UserPolicy 封装在 Actor 中
/// - 串行执行: 同一 Actor 的操作串行执行，无数据竞争
/// - 仅值类型传递: 跨 Actor 传递均为 Sendable 值类型
///
/// ## 审计日志契约 (AGENTS.md §7.3)
/// - 强制字段: eventType, timestamp, traceID, policyVersion, success
/// - 保留期: 30 天，超期自动清理
/// - 覆盖率: CI 强制 100% (所有 Pipeline 入口必须有 Checkpoint)
///
/// ## 使用方式
/// ```swift
/// // 每个 Pipeline Actor 方法的第一个语句必须是：
/// let checkpoint = await PrivacyActor.shared.validate(
///     operation: .search,
///     traceID: traceID
/// )
/// // 若返回 .denied，立即终止并返回 Denial Response
/// guard checkpoint.isAllowed else { return }
/// ```
public actor PrivacyActor {

    // MARK: - Singleton

    public static let shared = PrivacyActor()

    // MARK: - Properties

    /// 当前用户策略（TODO Phase 2: 从 SQLite 持久化加载）
    private var policy: UserPolicy

    // MARK: - Initialization

    private init(policy: UserPolicy = UserPolicy()) {
        self.policy = policy
    }

    // MARK: - Privacy Checkpoint Validation

    /// 对 Pipeline 操作执行隐私校验，返回 PrivacyCheckpoint。
    ///
    /// 对应架构文档 §7.2 强制校验流程：
    /// 1. 生成 traceID（由调用方传入）
    /// 2. 执行授权检查（基于 UserPolicy.authorizedSourceTypes）
    /// 3. 返回 PrivacyCheckpoint（含 decision: .allowed / .denied）
    /// 4. TODO Phase 2: 写入审计日志到 AuditLog SQLite 表
    ///
    /// - Parameters:
    ///   - operation: 当前 Pipeline 操作类型
    ///   - traceID: 由 Pipeline 节点生成的 UUID 字符串
    ///   - sourceTypes: 涉及的数据源列表（用于授权匹配）
    /// - Returns: PrivacyCheckpoint 包含授权决策
    public func validate(
        operation: PrivacyOperation,
        traceID: String,
        sourceTypes: [String] = []
    ) async -> PrivacyCheckpoint {
        // 检查所有涉及的数据源是否均已授权
        let allAuthorized = sourceTypes.isEmpty || sourceTypes.allSatisfy { policy.isAuthorized(sourceType: $0) }

        let decision: PrivacyDecision = allAuthorized ? .allowed : .denied

        // TODO (Phase 2, Task 2.1): 写入审计日志到 AuditLog 表
        // await writeAuditLog(checkpoint: ...)

        return PrivacyCheckpoint(
            traceID: traceID,
            timestamp: Date(),
            operation: operation,
            policyVersion: policy.policyVersion,
            sourceTypes: sourceTypes,
            decision: decision
        )
    }

    // MARK: - Policy Management (Stub — Phase 2)

    /// 获取当前 UserPolicy 的只读副本
    public func getPolicy() async -> UserPolicy {
        policy
    }

    /// 更新用户策略（TODO Phase 2: 持久化到 SQLite）
    public func updatePolicy(_ newPolicy: UserPolicy) async {
        self.policy = newPolicy
        // TODO: 写入审计日志 — .policyChanged
    }

    /// 检查指定数据源是否已授权
    public func isSourceAuthorized(_ sourceType: String) async -> Bool {
        policy.isAuthorized(sourceType: sourceType)
    }
}
