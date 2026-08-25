// ==========================================
// 文件: EchoApp.swift
// 对应规格: AGENTS.md §2.1 强制技术栈, §10.1 强制目录结构; docs/ui/architecture.md §3 (App Shell)
// 任务: 1.1 - 创建 Xcode 项目，配置 Swift 6 并发严格模式
//       3.0 - App Shell: TabView + NavigationStack + DI 注入
//       3F.1 - Production composition root (ADR-007 §决策-1)
// 用途: 应用入口，SwiftUI App 生命周期，注入 AppComposition (唯一依赖图)
// 架构约束: Swift 6 + @Observable + Actor 隔离，禁止 Combine/GCD
// 生成时间: 2026-07-04 (原始), 2026-07-26 (Task 3.0 更新), 2026-08-04 (Task 3F.1)
// ==========================================

import SwiftUI

@main
struct EchoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// 应用自有 composition root — 唯一依赖图 (3F.1, ADR-007 §决策-1)
    @State private var composition = AppComposition.shared

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(composition)
                .task {
                    // 单元测试宿主也会启动 App——跳过生产装配，避免 consent gate 泄漏到共享单例
                    guard !isRunningUnderXCTest else { return }
                    WP2DeviceBenchmark.runIfNeeded()
                    await composition.bootstrap()
                }
        }
    }

    /// 是否运行在 XCTest 测试宿主下（单元测试进程隔离，避免生产装配副作用）
    private var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
