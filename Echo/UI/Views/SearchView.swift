// ==========================================
// 文件: SearchView.swift
// 对应规格: docs/ui/echo-memory-canvas-style.md §3.1 (Discovery surfaces), §14 (筛选与搜索 UI 模式)
// 任务: 3.0 - App Shell: TabView + NavigationStack + DI 注入 (占位视图)
// AC 覆盖: Search 标签页 Stub — 后续 3.2 替换为完整实现
// 架构约束: 遵循 AGENTS.md §8.1; echo-memory-canvas apple-native 基础; Discovery surface family
// 生成时间: 2026-07-26
// ==========================================

import SwiftUI

// MARK: - SearchView

/// Search 视图 — 记忆检索页面
///
/// ## Surface Family: Discovery
/// - 当前为 App Shell 占位视图
/// - 后续任务 3.2 实现完整 SearchView + SearchViewModel
///
/// ## Style
/// - 遵循 echo-memory-canvas token: .headline, Color.primary, SF Symbols
struct SearchView: View {

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(Color.secondary)

            Text("Search")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.primary)

            Text("搜索你的所有记忆")
                .font(.body)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .navigationTitle("Search")
        .accessibilityLabel("Search")
        .accessibilityHint("输入关键词搜索记忆")
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SearchView()
    }
}
