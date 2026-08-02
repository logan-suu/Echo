// ==========================================
// 文件: ResumeProgressFixtureLoader.swift
// 对应规格: docs/ui/echo-memory-canvas-style.md §5 (确定性 Fixture),
//            UIAutomation/Fixtures/README.md (Fixture 规范),
//            docs/ui/testing-and-artifacts.md §2.1 (fixture 可确定性解码)
// 任务: 3.7 - 断点续传集成到长任务 确定性 Fixture Loader
// AC 覆盖: US-SYS-001 AC-3/AC-4 (断点续传恢复提示 fixture),
//          契约 fixture IDs: resume-progress-pending / resume-progress-none / resume-progress-error
// 架构约束: 确定性、离线、可复现; 控制 taskId/lastProcessedIndex/totalCount;
//           不访问网络或生产数据库 (docs/ui/architecture.md §3 Fixture Loader)
// 生成时间: 2026-08-02
// ==========================================

import Foundation

/// 确定性断点续传恢复提示 Fixture — Preview / 单元测试 / Live Sim Review 注入。
///
/// ## 职责 (docs/ui/architecture.md §3: Fixture Loader)
/// - Preview/测试环境加载确定性数据
/// - 不访问网络或生产数据库
///
/// ## Fixture ID 映射
/// - `resume-progress-pending`: 存在未完成进度（fullIndex 50/128）→ prompt 态
/// - `resume-progress-none`: 无未完成进度 → none 态（直接从头开始）
/// - `resume-progress-error`: 进度加载失败（L2）→ error 态
enum ResumeProgressFixtureLoader {
    /// 根据 fixture ID 返回确定性 ``ResumeProgressFixture``。
    /// 无效 ID 返回 none fixture（不抛错，保持确定性降级）。
    static func load(_ fixtureID: String) -> ResumeProgressFixture {
        switch fixtureID {
        case "resume-progress-pending":
            return ResumeProgressFixture(
                taskType: .fullIndex,
                pendingProgress: pending
            )

        case "resume-progress-none":
            return ResumeProgressFixture(
                taskType: .dataSourceSync,
                pendingProgress: nil
            )

        case "resume-progress-error":
            return ResumeProgressFixture(
                taskType: .modelLoad,
                pendingProgress: nil,
                loadError: true
            )

        default:
            return ResumeProgressFixture(taskType: .dataSourceSync, pendingProgress: nil)
        }
    }

    /// 全部已注册 fixture ID
    static var availableFixtureIDs: [String] {
        ["resume-progress-pending", "resume-progress-none", "resume-progress-error"]
    }

    // MARK: - resume-progress-pending

    /// 50/128 fullIndex 任务 — 与契约 fixture resume-progress-pending.json 对齐。
    private static var pending: TaskProgress {
        TaskProgress(
            taskId: "task-index-001",
            taskType: .fullIndex,
            lastProcessedIndex: 50,
            totalCount: 128,
            lastProcessedId: "item-050",
            updatedAt: Date(timeIntervalSince1970: 1723536000),
            createdAt: Date(timeIntervalSince1970: 1723536000)
        )
    }
}

/// 确定性断点续传 fixture 载荷 — 由 fixture loader 返回，驱动恢复提示状态。
struct ResumeProgressFixture: Sendable {
    /// 即将启动的任务类型
    let taskType: TaskType
    /// 是否存在未完成进度（nil = 无）
    let pendingProgress: TaskProgress?
    /// 进度加载是否失败（L2）
    var loadError: Bool = false
}
