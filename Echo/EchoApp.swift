// ==========================================
// 文件: EchoApp.swift
// 对应规格: AGENTS.md §2.1 强制技术栈, §10.1 强制目录结构
// 任务: 1.1 - 创建 Xcode 项目，配置 Swift 6 并发严格模式
// 用途: 应用入口，SwiftUI App 生命周期
// 架构约束: Swift 6 + @Observable + Actor 隔离，禁止 Combine/GCD
// 生成时间: 2026-07-04
// ==========================================

import SwiftUI

@main
struct EchoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
