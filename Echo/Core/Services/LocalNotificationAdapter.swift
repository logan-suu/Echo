// ==========================================
// 文件: LocalNotificationAdapter.swift
// 对应规格: docs/decisions/ADR-012-awakening-system-boundary.md 决策-3 (通知请求与响应路由分离),
//            决策-7 (通知内容最小化), 决策-2 (权限感知)
//            docs/01-spec/用户故事与验收标准规格书.md → US-AWK-001 AC-4 (推送回忆卡片),
//            US-AWK-003 AC-4 (温和文案), US-AWK-005 AC-1 (卡片展示)
// 任务: 3F.8 - Awakening 与 system adapters
// AC 覆盖: US-AWK-005 AC-1 ✅ (推送文案+照片, 音乐建议降级), ADR-012 决策-3 ✅ (调度/路由分离),
//          ADR-012 决策-7 ✅ (通知内容最小化), 决策-2 ✅ (通知权限 denied → 静默不投递)
// 架构约束: AGENTS.md §4.2 (Actor 隔离 — 仅值类型), R-007,
//           R-001 (纯本地, 无网络)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor；UNUserNotificationCenter 为
//       @MainActor SDK，类默认 MainActor 隔离（正确持有 center）
// 生成时间: 2026-08-11
// ==========================================

import Foundation
@preconcurrency import UserNotifications

// MARK: - Notification Authorization State

/// 通知授权状态（ADR-012 决策-2 全状态处理）
public enum NotificationAuthState: String, Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
}

// MARK: - Notification Content

/// 最小化通知内容（ADR-012 决策-7: 仅标题+正文+触发记忆 ID，不含原文/健康值）
public struct EchoNotificationContent: Sendable, Equatable {
    public nonisolated let title: String
    public nonisolated let body: String
    /// 关联的记忆 ID（响应路由用，US-AWK-005 AC-3 点击跳转）
    public nonisolated let memoryId: UUID?
    /// 触发类型（geofenceOnly / emotionNegative / emotionNeutral / anniversary）
    public nonisolated let triggerType: String

    public nonisolated init(
        title: String,
        body: String,
        memoryId: UUID? = nil,
        triggerType: String = "awakening"
    ) {
        self.title = title
        self.body = body
        self.memoryId = memoryId
        self.triggerType = triggerType
    }
}

// MARK: - Notification Scheduling

/// 本地通知调度协议 — 抽象 UNUserNotificationCenter 边界，支持测试注入 Fake。
///
/// 仅调度通知（request + schedule + cancel）；响应路由由 `NotificationResponseRouter`
/// 单独负责（ADR-012 决策-3: 通知请求与响应路由分离）。
public protocol NotificationScheduling: AnyObject, Sendable {
    /// 当前通知授权状态
    func currentAuthorizationState() async -> NotificationAuthState
    /// 请求通知授权（US-AWK-001 AC-4 前置）
    func requestAuthorization() async -> NotificationAuthState
    /// 调度一条本地通知（最小化内容）
    /// - Returns: 通知标识符（供响应路由与取消使用）
    func schedule(_ content: EchoNotificationContent, at date: Date) async -> String?
    /// 取消挂起通知
    func cancel(identifier: String) async
}

// MARK: - Local Notification Adapter

/// 真实 UserNotifications 实现（默认 MainActor 隔离，直接访问 @MainActor UNUserNotificationCenter）。
///
/// - 授权全状态（ADR-012 决策-2）：denied → schedule 返回 nil（静默不投递，不报错）
/// - 内容最小化（决策-7）：仅 title/body + memoryId/triggerType（供路由），不含原文
/// - 请求与路由分离（决策-3）：本类仅负责调度；点击处理见 NotificationResponseRouter
public final class LocalNotificationAdapter: NotificationScheduling {

    // MARK: - Properties

    private let center: UNUserNotificationCenter
    /// 通知标识符前缀（卡片 memoryId 派生，供响应路由识别唤醒通知）
    private static let identifierPrefix = "echo.awakening."

    // MARK: - Init

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    // MARK: - NotificationScheduling

    public func currentAuthorizationState() async -> NotificationAuthState {
        let settings = await center.notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    public func requestAuthorization() async -> NotificationAuthState {
        let granted = await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { success, _ in
                continuation.resume(returning: success)
            }
        }
        return granted ? .authorized : .denied
    }

    public func schedule(_ content: EchoNotificationContent, at date: Date) async -> String? {
        // ADR-012 决策-2: 通知权限 denied → 静默不投递（AC-5 语义，不报错）
        let auth = await currentAuthorizationState()
        guard auth == .authorized else { return nil }

        let identifier = Self.identifierPrefix + (content.memoryId?.uuidString ?? UUID().uuidString)

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(date.timeIntervalSinceNow, 1),
            repeats: false
        )
        let unContent = UNMutableNotificationContent()
        unContent.title = content.title
        unContent.body = content.body
        unContent.sound = .default
        // userInfo 最小化：仅 memoryId + triggerType（响应路由用，不含原文）
        unContent.userInfo = [
            "memoryId": content.memoryId?.uuidString ?? "",
            "triggerType": content.triggerType
        ]
        let request = UNNotificationRequest(identifier: identifier, content: unContent, trigger: trigger)

        let success = await withCheckedContinuation { continuation in
            center.add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
        return success ? identifier : nil
    }

    public func cancel(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // MARK: - Private

    private static func map(_ status: UNAuthorizationStatus) -> NotificationAuthState {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .notDetermined
        }
    }
}
