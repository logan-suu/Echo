// ==========================================
// 文件: EchoApp.swift
// 对应规格: AGENTS.md §2.1 强制技术栈, §10.1 强制目录结构; docs/ui/architecture.md §3 (App Shell)
// 任务: 1.1 - 创建 Xcode 项目，配置 Swift 6 并发严格模式
// 任务: 3.0 - App Shell: TabView + NavigationStack + DI 注入
// 用途: 应用入口，SwiftUI App 生命周期，注入 AppViewModel (DI 容器)
// 架构约束: Swift 6 + @Observable + Actor 隔离，禁止 Combine/GCD
// 生成时间: 2026-07-04 (原始), 2026-07-26 (Task 3.0 更新)
// ==========================================

import SwiftUI

@main
struct EchoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// App 级 ViewModel — 依赖注入容器
    /// Task surface family: 系统 TabView + NavigationStack
    @State private var appViewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(appViewModel)
        }
    }
}
