// ==========================================
// 文件: ActiveRouteSet.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-A.4 (ActiveRouteSet)
//            调研报告 §15.1 (数据模型: ActiveRouteSet)
// 任务: R-A.4 - 原子服务路由
// AC 覆盖: textGeneration, ocrGeneration, visionGeneration, lexicalGeneration, version
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007 (禁止 unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-31
// ==========================================

import Foundation

// MARK: - ActiveRouteSet

/// 活跃服务路由 — 原子定义当前各通道使用的索引分代（R-A.4）。
///
/// ## 原子切换规则
/// - 启动时读取 route set 后逐项验证 generation 存在、manifest 匹配且 hash 有效
/// - 任何缺失或 hash 无效都拒绝该 route set，回退到最近一个完整可验证的 route set
/// - 不允许混代服务
public struct ActiveRouteSet: Sendable, Codable, Equatable {
    /// 文本稠密分代（如 "text_dense/e5-v1"）— 必填
    public nonisolated let textGeneration: String
    /// OCR 文本分代
    public nonisolated let ocrGeneration: String?
    /// 视觉稠密分代
    public nonisolated let visionGeneration: String?
    /// 词法分代
    public nonisolated let lexicalGeneration: String?
    /// 路由版本（每次切换递增）
    public nonisolated let version: Int
    /// 更新时间戳
    public nonisolated let updatedAt: Date

    public nonisolated init(
        textGeneration: String,
        ocrGeneration: String? = nil,
        visionGeneration: String? = nil,
        lexicalGeneration: String? = nil,
        version: Int = 1,
        updatedAt: Date = Date()
    ) {
        self.textGeneration = textGeneration
        self.ocrGeneration = ocrGeneration
        self.visionGeneration = visionGeneration
        self.lexicalGeneration = lexicalGeneration
        self.version = version
        self.updatedAt = updatedAt
    }
}
