// ==========================================
// 文件: DegradationFixtureLoader.swift
// 对应规格: docs/ui/echo-memory-canvas-style.md §5 (确定性 Fixture),
//            UIAutomation/Fixtures/degradation-banner/ (契约 Fixture 定义),
//            docs/ui/testing-and-artifacts.md §2.1 (fixture 可确定性解码)
// 任务: 3.6 - 统一错误处理 UI 确定性 Fixture Loader
// AC 覆盖: US-RES-002/003/004 banner 展示 fixture,
//          契约 fixture IDs: degradation-low-power / degradation-thermal / degradation-model-degraded / degradation-normal
// 架构约束: 确定性、离线、可复现; 控制 degradation type/message/icon; 不访问网络或生产数据库
// 生成时间: 2026-08-02
// ==========================================

import Foundation

struct DegradationFixture: Sendable {
    var degradation: DegradationState?
}

enum DegradationFixtureLoader {
    static func load(_ fixtureID: String) -> DegradationFixture {
        switch fixtureID {
        case "degradation-low-power":
            return DegradationFixture(degradation: .lowPower(paused: true))

        case "degradation-thermal":
            return DegradationFixture(degradation: .thermal())

        case "degradation-model-degraded":
            return DegradationFixture(degradation: .modelDegraded())

        case "degradation-normal":
            return DegradationFixture(degradation: nil)

        default:
            return DegradationFixture(degradation: nil)
        }
    }

    static var availableFixtureIDs: [String] {
        ["degradation-low-power", "degradation-thermal", "degradation-model-degraded", "degradation-normal"]
    }
}
