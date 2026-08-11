// ==========================================
// 文件: NotificationResponseRouter.swift
// 对应规格: docs/decisions/ADR-012-awakening-system-boundary.md 决策-3 (通知请求与响应路由分离)
//            docs/01-spec/用户故事与验收标准规格书.md → US-AWK-005 AC-3 (点击跳转原始数据)
// 任务: 3F.8 - Awakening 与 system adapters
// AC 覆盖: US-AWK-005 AC-3 ✅ (点击照片→详情, 文案→原文, 语音→播放页 — 由路由解析 memoryId),
//          ADR-012 决策-3 ✅ (响应路由与调度分离 — 纯函数路由，测试可注入)
// 架构约束: AGENTS.md §4.2 (仅值类型跨边界), R-007, 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// 重要: 路由为纯函数（无状态），notification identifier 由 LocalNotificationAdapter 以
//       "echo.awakening.<memoryId>" 前缀派生；解析失败返回 .home（安全降级）
// 生成时间: 2026-08-11
// ==========================================

import Foundation

// MARK: - Notification Route

/// 通知点击后的应用内路由目标（US-AWK-005 AC-3）
public enum NotificationRoute: Sendable, Equatable {
    /// 跳转记忆详情页（photo/text/voice 均由详情页承载跳转目标）
    case memoryDetail(memoryId: UUID)
    /// 回退首页（无有效目标时的安全降级）
    case home
}

// MARK: - Notification Response Routing

/// 通知响应路由协议 — 将通知标识符/载荷解析为应用内路由目标。
///
/// 与 `NotificationScheduling` 分离（ADR-012 决策-3）：调度只负责投递，
/// 本路由只负责「点击后去哪」。
public protocol NotificationResponseRouting: Sendable {
    /// 解析通知点击为路由目标。
    ///
    /// - Parameters:
    ///   - identifier: 通知标识符（LocalNotificationAdapter 生成："echo.awakening.<memoryId>"）
    ///   - userInfo: 通知载荷（最小化：memoryId / triggerType）
    /// - Returns: 路由目标；无法解析时返回 .home（安全降级）
    nonisolated func route(identifier: String, userInfo: [String: Any]) -> NotificationRoute
}

// MARK: - Notification Response Router

/// 生产通知响应路由器 — 纯函数实现。
///
/// 解析优先级：
/// 1. userInfo["memoryId"]（UUID 可解析）→ .memoryDetail(memoryId)
/// 2. identifier 前缀 "echo.awakening." + UUID → .memoryDetail(memoryId)
/// 3. 无法解析 → .home（安全降级，不崩溃）
public struct NotificationResponseRouter: NotificationResponseRouting {

    /// 与 LocalNotificationAdapter.identifierPrefix 保持一致的前缀
    public nonisolated static let identifierPrefix = "echo.awakening."

    public nonisolated init() {}

    public nonisolated func route(identifier: String, userInfo: [String: Any]) -> NotificationRoute {
        // 1. userInfo 中的 memoryId（最小化载荷，最高优先级）
        if let memoryIDString = userInfo["memoryId"] as? String,
           let memoryID = UUID(uuidString: memoryIDString) {
            return .memoryDetail(memoryId: memoryID)
        }
        // 2. identifier 前缀解析（"echo.awakening.<memoryId>"）
        if identifier.hasPrefix(Self.identifierPrefix) {
            let suffix = String(identifier.dropFirst(Self.identifierPrefix.count))
            if let memoryID = UUID(uuidString: suffix) {
                return .memoryDetail(memoryId: memoryID)
            }
        }
        // 3. 安全降级
        return .home
    }
}
