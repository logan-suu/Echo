// ==========================================
// 文件: HomeView.swift
// 对应规格: docs/ui/echo-memory-canvas-style.md §3.1 (Discovery surfaces), §10.1 (空态)
// 任务: 3.0 - App Shell: TabView + NavigationStack + DI 注入 (占位视图)
// AC 覆盖: Home 标签页 Stub — 后续 3.1 替换为完整实现
// 架构约束: 遵循 AGENTS.md §8.1; echo-memory-canvas apple-native 基础; Discovery surface family
// 生成时间: 2026-07-26
// ==========================================

import SwiftUI

// MARK: - HomeView

/// Home 视图 — 记忆发现主页
///
/// ## Surface Family: Discovery
/// - 当前为 App Shell 占位视图
/// - 后续任务 3.1 实现完整 HomeView + HomeViewModel
///
/// ## Style
/// - 遵循 echo-memory-canvas token: .largeTitle, Color.primary, Color(.systemBackground)
struct HomeView: View {

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "house.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.secondary)

            Text("Home")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.primary)

            Text("你的记忆，触手可及")
                .font(.body)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .navigationTitle("Echo · 回响")
        .accessibilityLabel("Home")
        .accessibilityHint("浏览你的唤醒记忆")
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        HomeView()
    }
}
