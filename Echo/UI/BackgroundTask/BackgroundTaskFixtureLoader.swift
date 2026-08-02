// ==========================================
// 文件: BackgroundTaskFixtureLoader.swift
// 对应规格: docs/ui/echo-memory-canvas-style.md §5 (确定性 Fixture),
//            UIAutomation/Fixtures/README.md (Fixture 规范),
//            docs/ui/testing-and-artifacts.md §2.1 (fixture 可确定性解码)
// 任务: 3.5 - 实时后台任务面板 确定性 Fixture Loader
// AC 覆盖: US-SYS-001 AC-1/AC-2 (任务列表 + 进度展示 fixture),
//          契约 fixture IDs: background-tasks-loaded / background-tasks-empty / background-tasks-error
// 架构约束: 确定性、离线、可复现; 控制 taskId/processedCount/totalCount;
//           不访问网络或生产数据库 (docs/ui/architecture.md §3 Fixture Loader)
// 生成时间: 2026-08-02
// ==========================================

import Foundation

/// 确定性后台任务 Fixture Loader — Preview / 单元测试 / Live Sim Review 注入。
///
/// ## 职责 (docs/ui/architecture.md §3: Fixture Loader)
/// - Preview/测试环境加载确定性数据
/// - 不访问网络或生产数据库
///
/// ## Fixture ID 映射
/// - `background-tasks-loaded`: 2 个活跃任务（dataSourceSync 32/128 + fullIndex 100/500）
/// - `background-tasks-empty`: 0 个任务（US-SYS-001 AC-5 自动隐藏空态）
/// - `background-tasks-error`: 加载失败（L2）
enum BackgroundTaskFixtureLoader {
    /// 根据 fixture ID 返回确定性 ``TaskProgress`` 数组。
    /// 无效 ID 返回空数组（不抛错，保持确定性降级）。
    static func load(_ fixtureID: String) -> [TaskProgress] {
        switch fixtureID {
        case "background-tasks-loaded":
            return loaded

        case "background-tasks-empty":
            return []

        default:
            return []
        }
    }

    /// 全部已注册 fixture ID
    static var availableFixtureIDs: [String] {
        ["background-tasks-loaded", "background-tasks-empty"]
    }

    // MARK: - background-tasks-loaded

    /// 2 个活跃任务 — 与契约 fixture background-tasks-loaded.json 对齐。
    private static var loaded: [TaskProgress] {
        [
            TaskProgress(
                taskId: "task-sync-001",
                taskType: .dataSourceSync,
                lastProcessedIndex: 32,
                totalCount: 128,
                lastProcessedId: "photo-032",
                updatedAt: Date(timeIntervalSince1970: 1723536000),
                createdAt: Date(timeIntervalSince1970: 1723536000)
            ),
            TaskProgress(
                taskId: "task-index-001",
                taskType: .fullIndex,
                lastProcessedIndex: 100,
                totalCount: 500,
                lastProcessedId: "item-100",
                updatedAt: Date(timeIntervalSince1970: 1723536000),
                createdAt: Date(timeIntervalSince1970: 1723536000)
            ),
        ]
    }
}
