// ==========================================
// 文件: AudioPlayerControllerTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RET-001 (voice 记忆展示)
//            Echo/UI/Views/MemoryDetailView.swift → AudioPlayerController
// 任务: 3.3 - 音频播放器播放完毕自动翻转按钮 (2026-08-02 用户反馈修复)
// AC 覆盖: US-RET-001 AC-3 (voice 记忆音频播放), 播放完毕 isPlaying 翻转回 false
// 架构约束: @Observable 状态驱动; AVAudioPlayerDelegate 回调; 本地 Bundle 音频 (R-001)
// 生成时间: 2026-08-02
// ==========================================

import Testing
import Foundation
import AVFoundation
@testable import Echo

/// AudioPlayerController 播放状态测试 — 覆盖播放/暂停切换与播放完毕自动翻转。
@MainActor
struct AudioPlayerControllerTests {

    private func makeController() -> AudioPlayerController {
        let controller = AudioPlayerController()
        return controller
    }

    @Test("controller starts idle with stopped state")
    func test_initialState() {
        let controller = makeController()
        #expect(controller.isPlaying == false)
        #expect(controller.durationText == "0:00")
    }

    @Test("toggle play starts playback and flips isPlaying")
    func test_togglePlay() {
        let controller = makeController()
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "voice-note-reminder", withExtension: "wav") else {
            Issue.record("voice-note-reminder.wav missing from bundle")
            return
        }

        controller.toggle(url: url)
        #expect(controller.isPlaying == true)
    }

    @Test("toggle pause stops playback and flips isPlaying back")
    func test_togglePause() {
        let controller = makeController()
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "voice-note-reminder", withExtension: "wav") else {
            Issue.record("voice-note-reminder.wav missing from bundle")
            return
        }

        controller.toggle(url: url)
        #expect(controller.isPlaying == true)
        controller.toggle(url: url)
        #expect(controller.isPlaying == false)
    }

    @Test("durationText reflects loaded audio duration")
    func test_durationTextAfterLoad() {
        let controller = makeController()
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "voice-note-reminder", withExtension: "wav") else {
            Issue.record("voice-note-reminder.wav missing from bundle")
            return
        }

        controller.toggle(url: url)
        #expect(controller.durationText == "0:03", "3-second WAV should show 0:03")
    }

    @Test("stop resets playback state")
    func test_stopResets() {
        let controller = makeController()
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "voice-note-reminder", withExtension: "wav") else {
            Issue.record("voice-note-reminder.wav missing from bundle")
            return
        }

        controller.toggle(url: url)
        #expect(controller.isPlaying == true)
        controller.stop()
        #expect(controller.isPlaying == false)
    }

    @Test("audioPlayerDidFinishPlaying flips isPlaying back to false (button reverts to play)")
    func test_finishCallbackFlipsState() async throws {
        let controller = makeController()
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "voice-note-reminder", withExtension: "wav") else {
            Issue.record("voice-note-reminder.wav missing from bundle")
            return
        }

        // 模拟播放完毕回调 (delegate 在真实播放结束时触发)
        controller.toggle(url: url)
        #expect(controller.isPlaying == true)

        // 直接调用 delegate 回调验证状态翻转 (无需等待真实 3 秒播放)
        let player = try AVAudioPlayer(contentsOf: url)
        await controller.audioPlayerDidFinishPlaying(player, successfully: true)

        // nonisolated 回调内部经 Task { @MainActor } 翻转 — 等待调度完成
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.isPlaying == false, "Play button must revert after playback finishes")
    }
}
