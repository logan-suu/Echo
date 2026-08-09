// ==========================================
// 文件: AuditEvent.swift
// 对应规格: AGENTS.md §5.4 (审计日志契约: 强制字段 / hash-only / 30天 / NSFileProtectionComplete),
//            §7.3 (审计事件完整清单)
//            docs/decisions/ADR-007-production-composition-consent.md §决策-4 (AuditLog schema/存储迁移)
// 任务: 3F.1 - Production composition、首次启动、同意与隐私
// AC 覆盖: AGENTS.md §5.4 (必填字段 eventType/timestamp/traceID/policyVersion/success, hash-only, 30天, 加密),
//          US-PRV-006 AC-6 (retentionPolicyEvaluated), ADR-007 §决策-3 (purgeFailed 审计)
// 架构约束: AGENTS.md R-007 (禁止 unchecked Sendable), 仅记录哈希摘要禁止原文
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-04
// ==========================================

import Foundation
import CryptoKit

// MARK: - Audit Event

/// 审计事件类型 — 对应 AGENTS.md §7.3 审计事件完整清单
public enum AuditEvent: String, Sendable, Codable {
    case dataSourceConnected
    case autoImportCompleted
    case scheduledScanCompleted
    case personSynced
    case deviceMigrationCompleted
    case permissionChanged
    case excluded
    case excludedRestored
    case excludedBatchRestored
    case excludedAutoCleaned
    case excludedChangeDetected
    case excludedRestoreFailedFileMissing
    case dataSourceChangeSynced
    case manualChangeDetectionCompleted
    /// 记忆摄入事务审计 (US-ING-006 AC-5: 含 rolledBack=true/false)
    case memoryIngested
    case ingestTransaction
    case imageIngested
    case videoIngested
    case voiceIngested
    case memoryDeleted
    case cascadeDeleteFromOriginal
    case memoryEdited
    case feedbackReceived
    case feedbackReset
    case feedbackRevoked
    case badCaseMarked
    case badCaseRevoked
    case modelLoadFailed
    case modelLoadRetrySuccess
    case backgroundTaskInterrupted
    case retryPending
    case syncConflict
    case reauthorized
    case retrieval
    case contextualAwakening
    case emotionalAwakening
    // 3F.1 新增 (ADR-007):
    /// 用户同意 PIPL 隐私政策 (US-PRV-008)
    case consentAccepted
    /// 用户撤回同意 / 注销 (US-PRV-005 / US-PRV-008 AC-5)
    case consentRevoked
    /// 事务性清除完成 (US-PRV-005 AC-7)
    case purgeCompleted
    /// 事务性清除失败 → blocked 状态 (ADR-007 §决策-3)
    case purgeFailed
    /// 记忆永久保留策略评估 (US-PRV-006 AC-6)
    case retentionPolicyEvaluated
    /// Share Extension 显式分享摄入 (US-SRC-003 AC-4: 含 appBundleId + contentType)
    case shareExtensionImported
}

// MARK: - Audit Log Entry

/// 审计日志条目 — 对应 AGENTS.md §5.4 审计日志契约
///
/// 强制字段: eventType, timestamp, traceID, policyVersion, success
/// 可选字段: sourceType, affectedCount, excludedWritten, sourceLanguage, elapsedMs
/// 隐私保护: 仅记录哈希摘要，禁止原文（content 字段在写入时被哈希为 contentHash）
public struct AuditLogEntry: Sendable, Codable {
    public nonisolated let id: Int64
    public nonisolated let eventType: AuditEvent
    public nonisolated let timestamp: Date
    public nonisolated let traceID: String
    public nonisolated let policyVersion: Int
    public nonisolated let success: Bool
    public nonisolated let sourceType: String?
    public nonisolated let affectedCount: Int?
    public nonisolated let excludedWritten: Bool?
    public nonisolated let sourceLanguage: String?
    public nonisolated let elapsedMs: Int?
    /// 视频摄入关键帧数（US-ING-005 AC-5）
    public nonisolated let frameCount: Int?
    /// 视频音频转写字符长度（US-ING-005 AC-5）
    public nonisolated let audioTranscriptLength: Int?
    /// 视频是否含音频轨道（US-ING-005 AC-5）
    public nonisolated let hasAudio: Bool?
    /// 内容字段的 SHA-256 哈希摘要（hash-only，禁止原文）— AGENTS.md §5.4
    public nonisolated let contentHash: String?

    public nonisolated init(
        id: Int64 = 0,
        eventType: AuditEvent,
        timestamp: Date = Date(),
        traceID: String,
        policyVersion: Int,
        success: Bool = true,
        sourceType: String? = nil,
        affectedCount: Int? = nil,
        excludedWritten: Bool? = nil,
        sourceLanguage: String? = nil,
        elapsedMs: Int? = nil,
        frameCount: Int? = nil,
        audioTranscriptLength: Int? = nil,
        hasAudio: Bool? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.eventType = eventType
        self.timestamp = timestamp
        self.traceID = traceID
        self.policyVersion = policyVersion
        self.success = success
        self.sourceType = sourceType
        self.affectedCount = affectedCount
        self.excludedWritten = excludedWritten
        self.sourceLanguage = sourceLanguage
        self.elapsedMs = elapsedMs
        self.frameCount = frameCount
        self.audioTranscriptLength = audioTranscriptLength
        self.hasAudio = hasAudio
        self.contentHash = contentHash
    }

    /// 从数据库查询结果行构造 AuditLogEntry（用于 fetchAuditLogs）
    public nonisolated static func fromRow(_ row: [String: DBValue]) -> AuditLogEntry? {
        guard let etStr = row["eventType"]?.stringValue,
              let eventType = AuditEvent(rawValue: etStr),
              let ts = row["timestamp"]?.doubleValue,
              let traceID = row["traceID"]?.stringValue,
              let pv = row["policyVersion"]?.intValue,
              let successInt = row["success"]?.intValue else { return nil }
        return AuditLogEntry(
            id: row["id"]?.intValue ?? 0,
            eventType: eventType,
            timestamp: Date(timeIntervalSince1970: ts),
            traceID: traceID,
            policyVersion: Int(pv),
            success: successInt != 0,
            sourceType: row["sourceType"]?.stringValue,
            affectedCount: row["affectedCount"]?.intValue.map(Int.init),
            excludedWritten: row["excludedWritten"]?.intValue.map { $0 != 0 },
            sourceLanguage: row["sourceLanguage"]?.stringValue,
            elapsedMs: row["elapsedMs"]?.intValue.map(Int.init),
            frameCount: row["frameCount"]?.intValue.map(Int.init),
            audioTranscriptLength: row["audioTranscriptLength"]?.intValue.map(Int.init),
            hasAudio: row["hasAudio"]?.intValue.map { $0 != 0 },
            contentHash: row["contentHash"]?.stringValue
        )
    }
}

// MARK: - Audit Content Hasher

/// 审计内容哈希工具 — 仅记录哈希摘要，禁止原文 (AGENTS.md §5.4)
public enum AuditContentHasher {
    /// 计算内容的 SHA-256 十六进制摘要
    public nonisolated static func sha256Hex(_ content: String) -> String {
        let data = Data(content.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
