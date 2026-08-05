// ==========================================
// 文件: AppDelegate.swift
// 对应规格: AGENTS.md §10.1 强制目录结构
// 任务: 1.1 - 创建 Xcode 项目，配置 Swift 6 并发严格模式
//       3F.1 - Production composition root (ADR-007 §决策-1)
// 用途: BGTask 注册 (US-SYS-001 后台任务面板)
// 架构约束: 遵循 AGENTS.md §9 (后台任务与断点续传)
// 生成时间: 2026-07-04
// ==========================================

import UIKit

/// Echo 应用代理 — 负责后台任务注册与生命周期管理
/// 后台任务包括：定时扫描、数据同步、索引构建（US-SYS-001）
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 生产装配：确保 composition root 已初始化（幂等，主装配在 EchoApp.task）
        _ = AppComposition.shared
        return true
    }
}
