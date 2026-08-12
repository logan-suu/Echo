// ==========================================
// 文件: MemoryDetailMediaUITests.swift
// 对应规格: docs/ui/testing-and-artifacts.md §2.4 (journey 测试),
//            docs/01-spec/用户故事与验收标准规格书.md → US-RET-001 (媒体记忆展示)
// 任务: 3.3 - MemoryDetailView 媒体预览 (photo/video/voice) 运行时验证
// AC 覆盖: US-RET-001 AC-3 (媒体记忆展示: 图片/视频/音频预览)
// 架构约束: 使用稳定 accessibility identifier，不依赖坐标 (AGENTS.md §9.1 UI 测试)
// 生成时间: 2026-08-02
// ==========================================

import XCTest

/// 记忆详情媒体预览 journey 测试 — 验证三种媒体类型 (photo/video/voice) 渲染。
final class MemoryDetailMediaUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// photo fixture: 图片预览渲染在标题上方
    @MainActor
    func test_photoMediaPreview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-language", "en-US", "-ui-skip-consent", "-ui-fixture", "memory-detail-photo-loaded"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        // 图片预览区域 (accessibilityLabel "公园里的红裙子 photo")
        let photoPreview = app.images["公园里的红裙子 photo"]
        XCTAssertTrue(photoPreview.waitForExistence(timeout: 5), "Photo preview should render")
        // 标题与 Edit 入口
        XCTAssertTrue(app.staticTexts["公园里的红裙子"].exists)
        XCTAssertTrue(app.buttons["memory-detail-edit-button"].exists)
    }

    /// video fixture: VideoPlayer 渲染 (accessibilityLabel "海边日落 video")
    @MainActor
    func test_videoMediaPreview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-language", "en-US", "-ui-skip-consent", "-ui-fixture", "memory-detail-video-loaded"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        let videoPreview = app.otherElements["海边日落 video"]
        XCTAssertTrue(videoPreview.waitForExistence(timeout: 5), "Video player should render")
        XCTAssertTrue(app.staticTexts["海边日落"].exists)
    }

    /// voice fixture: 音频播放器渲染 + 播放/暂停切换
    @MainActor
    func test_voiceMediaPreview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-language", "en-US", "-ui-skip-consent", "-ui-fixture", "memory-detail-voice-loaded"]
        app.launch()

        app.tabBars.buttons["Search"].tap()

        let playButton = app.buttons["memory-detail-audio-play"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 5), "Audio play button should render")
        XCTAssertTrue(app.staticTexts["Voice memo"].exists)
        XCTAssertTrue(app.staticTexts["明天下午接妈妈"].exists)

        // 点击播放 → 按钮进入 Pause/Playing 态（真实播放或无声卡模拟播放）
        playButton.tap()
        let pausePredicate = NSPredicate(format: "label CONTAINS 'Pause'")
        let pauseExpectation = XCTNSPredicateExpectation(predicate: pausePredicate, object: playButton)
        XCTAssertEqual(XCTWaiter().wait(for: [pauseExpectation], timeout: 5), .completed, "Play button should switch to Pause after tap")

        // 播放完毕（真实 3s 或模拟时长）→ 自动翻转回 Play
        let playPredicate = NSPredicate(format: "label CONTAINS 'Play' AND label CONTAINS 'voice'")
        let playExpectation = XCTNSPredicateExpectation(predicate: playPredicate, object: playButton)
        XCTAssertEqual(XCTWaiter().wait(for: [playExpectation], timeout: 6), .completed, "Play button must revert after playback finishes")
    }
}
