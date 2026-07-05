// ==========================================
// 文件: PrivacyActor.swift
// 对应规格: docs/02-architecture/架构设计文档.md §7 (隐私校验与审计追踪)
//            docs/01-spec/用户故事与验收标准规格书.md → US-PRV-001
// 任务: 2.1 - PrivacyActor + UserPolicy 实现 (Full Implementation)
// AC 覆盖: US-PRV-001 AC-1 (策略更新即时生效), AC-2 (被拒数据不进入 Retriever),
//           AC-3 (Denial Response), AC-4 (缓存失效), AC-5 (重新授权不自动清除排除项),
//           AC-6 (审计记录)
// 架构约束: 遵循 AGENTS.md §4.2 (Actor 隔离契约), §7.1 (PrivacyCheckpoint 强制注入),
//            R-007 (禁止 @unchecked Sendable), R-008 (跨 Actor 调用必须 await)
// 重要: 所有 struct stored/computed properties 必须 nonisolated（项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor）
// 生成时间: 2026-07-05
// ==========================================

import Foundation

// MARK: - Privacy Operation

/// Pipeline 操作类型枚举 — 对应架构文档 §7.1 中的 operation 字段
public enum PrivacyOperation: String, Sendable, Codable, CaseIterable {
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

// MARK: - Audit Event Type

/// 审计事件类型 — 对应 AGENTS.md §7.3 审计事件完整清单
/// 仅包含 PrivacyActor 直接负责的事件类型
public enum AuditEventType: String, Sendable, Codable {
    case permissionChanged
    case reauthorized
    case excludedBatchRestored
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

// MARK: - Reauthorization Info

/// 重新授权检测结果 — 用于 AC-5 一键恢复排除项提示
public struct ReauthorizationInfo: Sendable, Codable {
    /// 从 denied 变为 authorized 的数据源类型
    public nonisolated let reactivatedSourceTypes: [String]
    /// 是否需要显示一键恢复提示
    public nonisolated let needsRecoveryPrompt: Bool

    public nonisolated init(reactivatedSourceTypes: [String]) {
        self.reactivatedSourceTypes = reactivatedSourceTypes
        self.needsRecoveryPrompt = !reactivatedSourceTypes.isEmpty
    }
}

// MARK: - User Policy

/// 用户隐私策略配置 — 控制授权数据源、偏好语言等。
///
/// 对应 US-PRV-001，由 PrivacyActor 管理。
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

// MARK: - Cache Invalidation Notification

extension Notification.Name {
    /// 当 UserPolicy 发生变更时发出此通知，监听者（如 SearchPipeline）应失效相关缓存
    public static let userPolicyDidChange = Notification.Name("echo.userPolicyDidChange")
}

// MARK: - Privacy Actor

/// 隐私校验与审计 Actor — 管理 UserPolicy，提供 Pipeline 入口的授权校验（PrivacyCheckpoint），
/// 写入审计日志到 AuditLog 表，检测重新授权事件。
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

    /// 当前用户策略
    private var policy: UserPolicy

    /// 上一次授权的数据源集合（用于检测重新授权事件）
    private var previousAuthorizedSet: Set<String>

    // MARK: - UserDefaults Keys

    private enum UDKey {
        static let userPolicy = "echo.userpolicy"
    }

    // MARK: - Initialization

    private init() {
        self.policy = UserPolicy()
        self.previousAuthorizedSet = self.policy.authorizedSourceTypes
        Task { await loadPersistedPolicy() }
    }

    // MARK: - Policy Persistence

    /// 从 UserDefaults 异步加载持久化策略，不存在则使用默认值
    private func loadPersistedPolicy() async {
        let data = UserDefaults.standard.data(forKey: UDKey.userPolicy)
        if let data = data {
            let decoded: UserPolicy? = await MainActor.run {
                try? JSONDecoder().decode(UserPolicy.self, from: data)
            }
            if let decoded = decoded {
                self.policy = decoded
                self.previousAuthorizedSet = decoded.authorizedSourceTypes
                return
            }
        }
        // 若无持久化数据，使用默认策略
    }

    /// 持久化当前策略到 UserDefaults
    private func persistPolicy() {
        let p = policy
        Task { @MainActor in
            if let data = try? JSONEncoder().encode(p) {
                UserDefaults.standard.set(data, forKey: UDKey.userPolicy)
            }
        }
    }

    // MARK: - Privacy Checkpoint Validation

    /// 对 Pipeline 操作执行隐私校验，返回 PrivacyCheckpoint。
    ///
    /// 对应架构文档 §7.2 强制校验流程：
    /// 1. 生成 traceID（由调用方传入）
    /// 2. 执行授权检查（基于 UserPolicy.authorizedSourceTypes）
    /// 3. 写入审计日志到 AuditLog SQLite 表
    /// 4. 返回 PrivacyCheckpoint（含 decision: .allowed / .denied）
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
        let startTime = CFAbsoluteTimeGetCurrent()

        // 检查所有涉及的数据源是否均已授权
        let allAuthorized = sourceTypes.isEmpty || sourceTypes.allSatisfy { policy.isAuthorized(sourceType: $0) }
        let decision: PrivacyDecision = allAuthorized ? .allowed : .denied
        let success = allAuthorized

        let checkpoint = PrivacyCheckpoint(
            traceID: traceID,
            timestamp: Date(),
            operation: operation,
            policyVersion: policy.policyVersion,
            sourceTypes: sourceTypes,
            decision: decision
        )

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        // 写入审计日志（仅 denied 时写入，allowed 操作不写审计日志）
        if !success {
            await writeAuditLog(
                eventType: nil,
                traceID: traceID,
                success: success,
                sourceType: sourceTypes.first,
                policyVersion: policy.policyVersion,
                elapsedMs: elapsedMs
            )
        }

        return checkpoint
    }

    // MARK: - Policy Management

    /// 获取当前 UserPolicy 的只读副本
    public func getPolicy() async -> UserPolicy {
        policy
    }

    /// 更新用户策略，持久化到 UserDefaults，递增版本号，发送缓存失效通知，
    /// 检测重新授权事件。
    ///
    /// 对应 US-PRV-001 AC-1（策略更新即时生效）、AC-4（缓存自动失效）、AC-5（重新授权检测）。
    ///
    /// - Parameter newPolicy: 新的 UserPolicy
    /// - Returns: ReauthorizationInfo 如果检测到重新授权，否则返回 nil
    @discardableResult
    public func updatePolicy(_ newPolicy: UserPolicy) async -> ReauthorizationInfo? {
        let oldAuthorizedSet = policy.authorizedSourceTypes
        let newAuthorizedSet = newPolicy.authorizedSourceTypes

        // 检测重新授权：从 denied 变为 authorized 的数据源类型
        let reactivatedTypes = newAuthorizedSet.subtracting(oldAuthorizedSet)
        let reauthInfo = ReauthorizationInfo(reactivatedSourceTypes: Array(reactivatedTypes))

        // 递增版本号，确保策略变更可追溯
        let versionedPolicy = UserPolicy(
            preferredLanguage: newPolicy.preferredLanguage,
            authorizedSourceTypes: newPolicy.authorizedSourceTypes,
            policyVersion: policy.policyVersion + 1
        )

        self.policy = versionedPolicy
        self.previousAuthorizedSet = newAuthorizedSet
        persistPolicy()

        // 记录审计事件
        if reauthInfo.needsRecoveryPrompt {
            for sourceType in reactivatedTypes {
                await writeAuditLog(
                    eventType: .reauthorized,
                    traceID: UUID().uuidString,
                    success: true,
                    sourceType: sourceType,
                    policyVersion: versionedPolicy.policyVersion
                )
            }
        } else {
            await writeAuditLog(
                eventType: .permissionChanged,
                traceID: UUID().uuidString,
                success: true,
                policyVersion: versionedPolicy.policyVersion
            )
        }

        // US-PRV-001 AC-4: 策略变更后失效所有相关缓存
        await invalidateCache()

        return reauthInfo.needsRecoveryPrompt ? reauthInfo : nil
    }

    /// 检查指定数据源是否已授权
    public func isSourceAuthorized(_ sourceType: String) async -> Bool {
        policy.isAuthorized(sourceType: sourceType)
    }

    // MARK: - Reauthorization & ExcludedAssets

    /// 检测一对策略之间的重新授权事件（不改变当前状态，仅用于查询）。
    ///
    /// 对应 US-PRV-001 AC-5：当用户将某个数据源从"拒绝"改为"授权"时，
    /// 返回该数据源类型列表，供 UI 层查询 ExcludedAssetsActor 后显示一键恢复提示。
    ///
    /// - Parameter newPolicy: 拟变更的新策略
    /// - Returns: ReauthorizationInfo 包含重新激活的数据源类型
    public func detectReauthorization(for newPolicy: UserPolicy) async -> ReauthorizationInfo {
        let reactivatedTypes = newPolicy.authorizedSourceTypes.subtracting(policy.authorizedSourceTypes)
        return ReauthorizationInfo(reactivatedSourceTypes: Array(reactivatedTypes))
    }

    /// 记录一键恢复排除项操作（批量清除 ExcludedAssets 记录）。
    ///
    /// 对应 US-PRV-001 AC-6：重新授权时记录 .excludedBatchRestored。
    public func recordBatchRestore(sourceType: String, restoredCount: Int, traceID: String = UUID().uuidString) async {
        await writeAuditLog(
            eventType: .excludedBatchRestored,
            traceID: traceID,
            success: true,
            sourceType: sourceType,
            excludedWritten: restoredCount,
            policyVersion: policy.policyVersion
        )
    }

    // MARK: - Cache Invalidation

    /// 失效所有与隐私策略相关的缓存（对应 AC-4）。
    /// 通过 NotificationCenter 通知所有监听者（如 SearchPipeline）清理缓存。
    private func invalidateCache() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .userPolicyDidChange, object: nil)
        }
    }

    // MARK: - Audit Log Writing

    /// 写入审计日志到 AuditLog SQLite 表。
    ///
    /// 对应 AGENTS.md §7.3 审计日志契约：
    /// - 强制字段: eventType, timestamp, traceID, policyVersion, success
    /// - 可选字段: sourceType, affectedCount, excludedWritten, sourceLanguage, elapsedMs
    /// - 保留期: 30 天，超期自动清理
    ///
    /// - Parameters:
    ///   - eventType: 审计事件类型（可选，为 nil 时不写入 eventType 字段）
    ///   - sourceType: 数据源类型
    ///   - excludedWritten: 排除项恢复/写入计数
    ///   - traceID: 追踪 ID
    ///   - policyVersion: 策略版本号
    ///   - success: 操作是否成功
    ///   - elapsedMs: 耗时（毫秒）
    private func writeAuditLog(
        eventType: AuditEventType?,
        traceID: String,
        success: Bool,
        sourceType: String? = nil,
        excludedWritten: Int? = nil,
        policyVersion: Int = 1,
        elapsedMs: Int? = nil
    ) async {
        do {
            try await DatabaseManager.shared.executeWrite(
                sql: """
                    INSERT INTO AuditLog (eventType, timestamp, traceID, policyVersion, success, sourceType, excludedWritten, elapsedMs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                bindings: [
                    .text(eventType?.rawValue ?? ""),
                    .double(Date().timeIntervalSince1970),
                    .text(traceID),
                    .int(Int64(policyVersion)),
                    .int(success ? 1 : 0),
                    sourceType.map { .text($0) } ?? .null,
                    excludedWritten.map { .int(Int64($0)) } ?? .null,
                    elapsedMs.map { .int(Int64($0)) } ?? .null
                ]
            )
            // 30 天清理：删除过期的审计日志
            let cutoff = Date().timeIntervalSince1970 - (30 * 24 * 60 * 60)
            try await DatabaseManager.shared.executeWrite(
                sql: "DELETE FROM AuditLog WHERE timestamp < ?",
                bindings: [.double(cutoff)]
            )
        } catch {
            // 审计日志写入失败不应阻断主流程（静默处理，避免影响用户体验）
            // 生产环境可通过系统日志记录
        }
    }

    // MARK: - Audit Log Query

    /// 查询审计日志（最近 30 天，按时间倒序）。
    ///
    /// - Parameter limit: 最大返回条数
    /// - Returns: 审计日志条目列表
    public func queryAuditLogs(limit: Int = 100) async -> [[String: DBValue]] {
        do {
            return try await DatabaseManager.shared.executeQuery(
                sql: "SELECT * FROM AuditLog ORDER BY timestamp DESC LIMIT ?",
                bindings: [.int(Int64(limit))]
            )
        } catch {
            return []
        }
    }
}
