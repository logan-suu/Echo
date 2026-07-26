// ==========================================
// 文件: SettingsView.swift
// 对应规格: docs/ui/echo-memory-canvas-style.md §3.3 (Task surfaces), §7.2 (Task surfaces)
// 任务: 3.0 - App Shell: TabView + NavigationStack + DI 注入 (占位视图)
// AC 覆盖: Settings 标签页 Stub — 后续 3.4 替换为完整实现
// 架构约束: 遵循 AGENTS.md §8.1; echo-memory-canvas apple-native 基础; Task surface family (禁止 masonry)
// 生成时间: 2026-07-26
// ==========================================

import SwiftUI

// MARK: - SettingsView

/// Settings 视图 — 设置与管理页面
///
/// ## Surface Family: Task
/// - 使用系统 Form/List 容器（后续 3.4 实现）
/// - 当前为 App Shell 占位视图
/// - 后续任务 3.4 实现完整 SettingsView + SettingsViewModel
/// - 明确禁止 masonry 布局
///
/// ## Style
/// - 遵循 echo-memory-canvas token: .headline, Color.primary, system GroupedBackground
struct SettingsView: View {

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.secondary)

            Text("Settings")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.primary)

            Text("管理你的 Echo")
                .font(.body)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Settings")
        .accessibilityLabel("Settings")
        .accessibilityHint("管理数据源与偏好设置")
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SettingsView()
    }
}
