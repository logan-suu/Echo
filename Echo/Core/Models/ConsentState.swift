// ==========================================
// 文件: ConsentState.swift
// 对应规格: docs/decisions/ADR-007-production-composition-consent.md §决策-2 (deny-by-default 同意),
//            §决策-3 (事务性撤回/清除, PurgeBoundary 显式定义)
//            docs/01-spec/用户故事与验收标准规格书.md → US-PRV-008 (PIPL 同意), US-PRV-005 (撤回/清除)
// 任务: 3F.1 - Production composition、首次启动、同意与隐私
// AC 覆盖: ADR-007 §决策-2 (同意版本与时间戳持久化), §决策-3 (PurgeBoundary 边界),
//           US-PRV-008 AC-4/AC-5 (撤回同意入口 + 注销流程)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §8.1, R-007 (禁止 unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-04
// ==========================================

import Foundation

// MARK: - Consent State

/// 用户同意状态 — deny-by-default (ADR-007 §决策-2)。
///
/// 新装用户未同意前（默认 `.notConsented`）拒绝任何业务数据访问；
/// 同意版本与时间戳持久化到 SQLite ConsentStore 表。
public struct ConsentState: Sendable, Codable, Equatable {
    /// 是否已同意
    public nonisolated let hasConsented: Bool
    /// 同意策略版本
    public nonisolated let consentVersion: Int
    /// 同意时间（未同意为 nil）
    public nonisolated let consentedAt: Date?
    /// 同意时关联的 UserPolicy 版本
    public nonisolated let policyVersion: Int

    public nonisolated init(
        hasConsented: Bool,
        consentVersion: Int,
        consentedAt: Date?,
        policyVersion: Int
    ) {
        self.hasConsented = hasConsented
        self.consentVersion = consentVersion
        self.consentedAt = consentedAt
        self.policyVersion = policyVersion
    }

    /// deny-by-default 初始状态：未同意
    public nonisolated static let notConsented = ConsentState(
        hasConsented: false,
        consentVersion: 1,
        consentedAt: nil,
        policyVersion: 1
    )
}

// MARK: - Purge Boundary

/// 撤回同意 / 注销时的数据清除边界 — 显式定义被清除的存储域 (ADR-007 §决策-3)。
///
/// 默认 `.full` 清除全部业务数据域；测试与未来任务可通过指定子集缩小边界。
/// 注意：原始文件（系统相册/备忘录等）永不被清除（US-PRV-005 AC-6）。
public struct PurgeBoundary: Sendable, Codable, Equatable {
    /// 向量存储（ProximaKit HNSW 文件）
    public nonisolated let purgeVectors: Bool
    /// 索引（分代索引文件与元数据）
    public nonisolated let purgeIndexes: Bool
    /// 缓存（内存/磁盘缓存）
    public nonisolated let purgeCaches: Bool
    /// 元数据（SQLite Memory/Representation 等业务表）
    public nonisolated let purgeMetadata: Bool
    /// 审计日志（US-PRV-005 AC-7: 擦除完成后审计数据库自身擦除）
    public nonisolated let purgeAuditLog: Bool
    /// 翻译缓存（translationCache, TTL 缓存）
    public nonisolated let purgeTranslationCache: Bool

    public nonisolated init(
        purgeVectors: Bool,
        purgeIndexes: Bool,
        purgeCaches: Bool,
        purgeMetadata: Bool,
        purgeAuditLog: Bool,
        purgeTranslationCache: Bool
    ) {
        self.purgeVectors = purgeVectors
        self.purgeIndexes = purgeIndexes
        self.purgeCaches = purgeCaches
        self.purgeMetadata = purgeMetadata
        self.purgeAuditLog = purgeAuditLog
        self.purgeTranslationCache = purgeTranslationCache
    }

    /// 全量清除边界（ADR-007 §决策-3 默认）
    public nonisolated static let full = PurgeBoundary(
        purgeVectors: true,
        purgeIndexes: true,
        purgeCaches: true,
        purgeMetadata: true,
        purgeAuditLog: true,
        purgeTranslationCache: true
    )
}

// MARK: - Purge Result

/// 撤回/清除操作结果
public struct PurgeResult: Sendable, Codable, Equatable {
    /// 是否成功
    public nonisolated let success: Bool
    /// 是否进入 blocked 状态（失败）
    public nonisolated let blocked: Bool
    /// 受影响记录数
    public nonisolated let affectedCount: Int

    public nonisolated init(success: Bool, blocked: Bool, affectedCount: Int) {
        self.success = success
        self.blocked = blocked
        self.affectedCount = affectedCount
    }

    public nonisolated static let failed = PurgeResult(success: false, blocked: true, affectedCount: 0)
}

// MARK: - Purge Error

/// 撤回/清除失败错误 (L2 可恢复 / blocked)
public enum PurgeError: Error, LocalizedError, Sendable {
    /// 事务性清除失败，已回滚
    case purgeFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .purgeFailed(let reason):
            return "Purge failed and rolled back: \(reason)"
        }
    }
}
