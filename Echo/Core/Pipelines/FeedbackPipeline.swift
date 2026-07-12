// ==========================================
// 文件: FeedbackPipeline.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-FBK-001 (本地反馈收集),
//            US-FBK-003 (本地 Bad Case 标记/撤销)
//            docs/02-architecture/数据流全链路技术说明文档.md §6 (反馈学习数据流)
// 任务: 2.13 - FeedbackPipeline：点赞/点踩/Bad Case 记录
// AC 覆盖: US-FBK-001 AC-2 ✅ (写入 FeedbackStore), AC-4 ✅ (关联 memoryId+queryEmbedding),
//           AC-5 ✅ (审计 .feedbackReceived, via FeedbackActor)
//           US-FBK-003 AC-2 ✅ (Bad Case 含查询词/返回结果/标记时间/可选原因),
//           AC-5 ✅ (不涉及服务端), AC-6 ✅ (审计 .badCaseMarked/.badCaseRevoked)
//           US-FBK-001 AC-1 🔮 (👍/👎 UI, Phase 3 SearchView)
//           US-FBK-003 AC-1 🔮 ("标记问题" UI, Phase 3 SearchView)
//           US-FBK-003 AC-3 🔮 ("我的反馈记录"页面, Phase 3 SettingsView)
//           US-FBK-003 AC-4 🔮 ("撤销"按钮, Phase 3 SettingsView)
// 架构约束: AGENTS.md §4.1 (Pipeline 契约 — actor 持有不可变引用),
//           AGENTS.md §4.2 (Actor 隔离契约), R-006 (PrivacyCheckpoint 强制注入),
//           AGENTS.md §5.3 (反馈仅本地存储), AGENTS.md §7.3 (审计事件完整清单)
// 重要: Pipeline 使用 actor 声明 + 不可变 actor 引用，符合 AGENTS.md v5.12 澄清的合法模式
// 生成时间: 2026-07-12
// ==========================================

import Foundation

// MARK: - Feedback Pipeline Error

/// FeedbackPipeline 统一错误类型（L1~L4 分级，AGENTS.md §4.4）
public enum FeedbackPipelineError: Error, LocalizedError, Sendable, Equatable {
    /// 隐私校验拒绝 — 用户未授权反馈功能
    case privacyDenied(sourceTypes: [String])
    /// 反馈记录写入失败（L1 瞬态 → L2 升级）
    case recordFailed(underlying: Error)
    /// 撤销失败（L2 可恢复，如记录不存在）
    case revokeFailed(feedbackId: UUID)
    /// 审计日志写入失败（L1 瞬态，非阻断）
    case auditLogFailed(underlying: Error)

    /// L1~L4 错误分级
    public nonisolated var errorLevel: Int {
        switch self {
        case .privacyDenied:              return 2  // L2 可恢复
        case .recordFailed:               return 2  // L2 可恢复
        case .revokeFailed:               return 2  // L2 可恢复
        case .auditLogFailed:             return 1  // L1 瞬态
        }
    }

    public nonisolated var errorDescription: String? {
        switch self {
        case .privacyDenied(let types):
            return "Feedback operation denied: unauthorized source types [\(types.joined(separator: ", "))]"
        case .recordFailed(let error):
            return "Failed to record feedback: \(error.localizedDescription)"
        case .revokeFailed(let feedbackId):
            return "Failed to revoke feedback: record not found (\(feedbackId))"
        case .auditLogFailed(let error):
            return "Failed to write audit log: \(error.localizedDescription)"
        }
    }

    public nonisolated static func == (lhs: FeedbackPipelineError, rhs: FeedbackPipelineError) -> Bool {
        switch (lhs, rhs) {
        case (.privacyDenied(let a), .privacyDenied(let b)): return a == b
        case (.recordFailed, .recordFailed): return true
        case (.revokeFailed(let a), .revokeFailed(let b)): return a == b
        case (.auditLogFailed, .auditLogFailed): return true
        default: return false
        }
    }
}

// MARK: - Feedback Pipeline

/// 反馈管线 — 处理点赞/点踩、Bad Case 标记与撤销。
///
/// ## Pipeline 契约 (AGENTS.md §4.1)
/// - 使用 `actor` 声明，持有不可变的 actor 引用（AGENTS.md v5.12 合法模式）
/// - 每个公共方法入口强制 PrivacyCheckpoint（R-006）
/// - 副作用通过 Actor 调用隔离
///
/// ## 数据流 (数据流全链路文档 §6)
/// ```
/// ViewModel → FeedbackPipeline.recordFeedback/markBadCase/revokeFeedback
///           → FeedbackActor (write SQLite)
///           → PrivacyActor (write AuditLog)
/// ```
///
/// ## 与 FeedbackActor 的关系
/// FeedbackActor 负责原始 CRUD + 重排公式（Task 2.7）。
/// FeedbackPipeline 负责业务编排：PrivacyCheckpoint 校验 + Bad Case 审计富化。
/// ViewModel 应通过 FeedbackPipeline 操作反馈，而非直接调用 FeedbackActor。
public actor FeedbackPipeline {

    // MARK: - Dependencies

    private let feedbackActor: FeedbackActor
    private let privacyActor: PrivacyActor

    // MARK: - Initialization

    public init(
        feedbackActor: FeedbackActor = .shared,
        privacyActor: PrivacyActor = .shared
    ) {
        self.feedbackActor = feedbackActor
        self.privacyActor = privacyActor
    }

    // MARK: - Privacy Checkpoint Helper

    /// 生成 PrivacyCheckpoint 并校验授权（R-006 强制注入）
    /// - Returns: PrivacyCheckpoint，若被拒绝则抛出 `.privacyDenied`
    private func validatePrivacy(
        operation: PrivacyOperation,
        traceID: String,
        sourceTypes: [String] = []
    ) async throws -> PrivacyCheckpoint {
        let checkpoint = await privacyActor.validate(
            operation: operation,
            traceID: traceID,
            sourceTypes: sourceTypes
        )
        guard checkpoint.isAllowed else {
            throw FeedbackPipelineError.privacyDenied(sourceTypes: sourceTypes)
        }
        return checkpoint
    }

    // MARK: - Bad Case Audit Helper

    /// 写入 Bad Case 特定审计事件（US-FBK-003 AC-6）
    /// - Parameters:
    ///   - event: .badCaseMarked 或 .badCaseRevoked
    ///   - traceID: 审计追踪 ID
    ///   - checkpoint: 已获得的隐私检查点（提供 policyVersion）
    private func writeBadCaseAudit(
        event: AuditEvent,
        traceID: String,
        policyVersion: Int
    ) async {
        try? await privacyActor.writeAuditLog(
            eventType: event,
            traceID: traceID,
            policyVersion: policyVersion,
            success: true,
            sourceType: "feedback",
            excludedWritten: true  // AC-6: 含 localStore=true
        )
    }

    // MARK: - Feedback Recording (US-FBK-001)

    /// 记录一条反馈（点赞 👍 或点踩 👎）。
    ///
    /// US-FBK-001 AC-2: 反馈数据存入本地 SQLite（FeedbackStore）
    /// US-FBK-001 AC-4: 关联 memoryId + queryEmbedding (via FeedbackEntry)
    /// US-FBK-001 AC-5: 审计 .feedbackReceived（由 FeedbackActor 内部写入）
    ///
    /// - Parameters:
    ///   - memoryId: 关联的记忆 ID
    ///   - queryText: 查询文本
    ///   - sentiment: 反馈情感（.like 或 .dislike）
    ///   - cosineSimilarity: 查询与记忆的余弦相似度
    ///   - traceID: 审计追踪 ID（若未提供则自动生成）
    /// - Returns: 创建的 FeedbackEntry
    @discardableResult
    public func recordFeedback(
        memoryId: UUID,
        queryText: String,
        sentiment: FeedbackSentiment,
        cosineSimilarity: Double,
        traceID: String = UUID().uuidString
    ) async throws -> FeedbackEntry {
        // R-006: PrivacyCheckpoint 强制注入
        _ = try await validatePrivacy(
            operation: .feedback,
            traceID: traceID
        )

        let entry = FeedbackEntry(
            id: UUID(),
            memoryId: memoryId,
            queryText: queryText,
            sentiment: sentiment,
            cosineSimilarity: cosineSimilarity,
            createdAt: Date(),
            isBadCase: false,
            badCaseReason: nil
        )

        do {
            try await feedbackActor.recordFeedback(entry, traceID: traceID)
        } catch {
            throw FeedbackPipelineError.recordFailed(underlying: error)
        }

        return entry
    }

    /// 记录点赞（便捷方法）
    /// - Parameters:
    ///   - memoryId: 关联的记忆 ID
    ///   - queryText: 查询文本
    ///   - cosineSimilarity: 余弦相似度
    ///   - traceID: 审计追踪 ID
    @discardableResult
    public func recordLike(
        memoryId: UUID,
        queryText: String,
        cosineSimilarity: Double,
        traceID: String = UUID().uuidString
    ) async throws -> FeedbackEntry {
        try await recordFeedback(
            memoryId: memoryId,
            queryText: queryText,
            sentiment: .like,
            cosineSimilarity: cosineSimilarity,
            traceID: traceID
        )
    }

    /// 记录点踩（便捷方法）
    /// - Parameters:
    ///   - memoryId: 关联的记忆 ID
    ///   - queryText: 查询文本
    ///   - cosineSimilarity: 余弦相似度
    ///   - traceID: 审计追踪 ID
    @discardableResult
    public func recordDislike(
        memoryId: UUID,
        queryText: String,
        cosineSimilarity: Double,
        traceID: String = UUID().uuidString
    ) async throws -> FeedbackEntry {
        try await recordFeedback(
            memoryId: memoryId,
            queryText: queryText,
            sentiment: .dislike,
            cosineSimilarity: cosineSimilarity,
            traceID: traceID
        )
    }

    // MARK: - Bad Case Management (US-FBK-003)

    /// 标记一条搜索结果/记忆为 Bad Case。
    ///
    /// US-FBK-003 AC-2: Bad Case 记录包含查询词、返回结果、标记时间、可选原因
    /// US-FBK-003 AC-6: 审计 .badCaseMarked
    ///
    /// - Parameters:
    ///   - memoryId: 关联的记忆 ID
    ///   - queryText: 查询文本
    ///   - reason: 可选标记原因（如"结果不相关"、"语言不匹配"等）
    ///   - cosineSimilarity: 余弦相似度（默认 0.0，Bad Case 通常相似度低）
    ///   - traceID: 审计追踪 ID
    /// - Returns: 创建的 Bad Case FeedbackEntry
    @discardableResult
    public func markBadCase(
        memoryId: UUID,
        queryText: String,
        reason: String? = nil,
        cosineSimilarity: Double = 0.0,
        traceID: String = UUID().uuidString
    ) async throws -> FeedbackEntry {
        // R-006: PrivacyCheckpoint 强制注入
        let checkpoint = try await validatePrivacy(
            operation: .feedback,
            traceID: traceID
        )

        let entry = FeedbackEntry(
            id: UUID(),
            memoryId: memoryId,
            queryText: queryText,
            sentiment: .dislike,  // Bad Case 本质是强负面反馈
            cosineSimilarity: cosineSimilarity,
            createdAt: Date(),
            isBadCase: true,
            badCaseReason: reason
        )

        do {
            try await feedbackActor.recordFeedback(entry, traceID: traceID)
        } catch {
            throw FeedbackPipelineError.recordFailed(underlying: error)
        }

        // US-FBK-003 AC-6: 审计 .badCaseMarked
        await writeBadCaseAudit(
            event: .badCaseMarked,
            traceID: traceID,
            policyVersion: checkpoint.policyVersion
        )

        return entry
    }

    /// 撤销一条反馈记录（包括 Bad Case 撤销）。
    ///
    /// US-FBK-003 AC-6: 审计 .badCaseRevoked（若撤销的是 Bad Case）
    ///
    /// - Parameters:
    ///   - feedbackId: 要撤销的反馈 ID
    ///   - traceID: 审计追踪 ID
    /// - Returns: 是否成功删除
    @discardableResult
    public func revokeFeedback(
        feedbackId: UUID,
        traceID: String = UUID().uuidString
    ) async throws -> Bool {
        // R-006: PrivacyCheckpoint 强制注入
        let checkpoint = try await validatePrivacy(
            operation: .feedback,
            traceID: traceID
        )

        // W4 fix (PR review): 原子查询是否为 Bad Case — 先于删除执行，
        // 避免两次 await 之间的非原子读（FeedbackActor 串行保证同一 actor 内原子性）
        let badCaseBeforeRevoke: Bool = (try? await feedbackActor.isBadCase(feedbackId: feedbackId)) ?? false

        let success = try await feedbackActor.revoke(feedbackId: feedbackId, traceID: traceID)

        if !success {
            throw FeedbackPipelineError.revokeFailed(feedbackId: feedbackId)
        }

        // US-FBK-003 AC-6: 若撤销的是 Bad Case，额外记录 .badCaseRevoked
        if badCaseBeforeRevoke {
            await writeBadCaseAudit(
                event: .badCaseRevoked,
                traceID: traceID,
                policyVersion: checkpoint.policyVersion
            )
        }

        return success
    }

    // MARK: - Query (US-FBK-003)

    /// 获取所有 Bad Case 记录（US-FBK-003 AC-3: "我的反馈记录"查看入口）
    /// - Returns: Bad Case 反馈列表
    public func fetchBadCases() async throws -> [FeedbackEntry] {
        // W1 fix (PR review): 读方法也注入 PrivacyCheckpoint 保持一致性
        _ = try await validatePrivacy(operation: .feedback, traceID: UUID().uuidString)
        return try await feedbackActor.fetchBadCases()
    }

    /// 获取指定记忆的所有反馈记录（含 Bad Case）
    /// - Parameter memoryId: 记忆 ID
    /// - Returns: 该记忆的反馈列表
    public func fetchFeedback(for memoryId: UUID) async throws -> [FeedbackEntry] {
        _ = try await validatePrivacy(operation: .feedback, traceID: UUID().uuidString)
        return try await feedbackActor.fetchEntries(for: memoryId)
    }

    /// 清空所有反馈（US-FBK-002 AC-5 路径：设置页"清除所有反馈学习数据"）
    /// - Parameter traceID: 审计追踪 ID
    public func resetAllFeedback(traceID: String = UUID().uuidString) async throws {
        let _ = try await validatePrivacy(
            operation: .feedback,
            traceID: traceID
        )
        try await feedbackActor.reset(traceID: traceID)
    }
}
