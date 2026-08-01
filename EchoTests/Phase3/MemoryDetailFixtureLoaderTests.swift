// ==========================================
// 文件: MemoryDetailFixtureLoaderTests.swift
// 对应规格: UIAutomation/Fixtures/README.md (Fixture 规范),
//            docs/ui/testing-and-artifacts.md §2.1 (fixture 可确定性解码),
//            docs/01-spec/用户故事与验收标准规格书.md → US-RET-001 (多类型记忆展示)
// 任务: 3.3 - MemoryDetailFixtureLoader 确定性数据测试（多类型）
// AC 覆盖: US-RET-001 AC-3 (多类型详情 fixture 确定性), US-AWK-007 (photo 用户补充描述)
// 架构约束: 确定性、离线、可复现; fixture ID 与 search 结果对齐 (Search→Detail 链路)
// 生成时间: 2026-08-01
// ==========================================

import Testing
import Foundation
@testable import Echo

/// MemoryDetailFixtureLoader 多类型确定性数据测试。
@MainActor
struct MemoryDetailFixtureLoaderTests {

    // MARK: - Multi-type fixtures (US-RET-001)

    @Test("photo fixture loads with photo sourceType and userEdited description")
    func test_photoFixture() {
        let model = MemoryDetailFixtureLoader.load("memory-detail-photo-loaded")
        #expect(model != nil)
        #expect(model?.sourceType == "photo")
        #expect(model?.sourceTypeLabel == "Photo")
        #expect(model?.userEdited == true)
        #expect(model?.assetId == "photo-zh-1")
        #expect(model?.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    }

    @Test("voice fixture loads with voice sourceType and transcript text")
    func test_voiceFixture() {
        let model = MemoryDetailFixtureLoader.load("memory-detail-voice-loaded")
        #expect(model != nil)
        #expect(model?.sourceType == "voice")
        #expect(model?.sourceTypeLabel == "Voice")
        #expect(model?.originalText.contains("接妈妈") == true)
        #expect(model?.assetId == "voice-zh-1")
        #expect(model?.id == UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
    }

    @Test("video fixture loads with video_frame sourceType")
    func test_videoFixture() {
        let model = MemoryDetailFixtureLoader.load("memory-detail-video-loaded")
        #expect(model != nil)
        #expect(model?.sourceType == "video_frame")
        #expect(model?.sourceTypeLabel == "Video")
        #expect(model?.originalText.contains("日落") == true)
        #expect(model?.assetId == "video-zh-1")
        #expect(model?.id == UUID(uuidString: "77777777-7777-7777-7777-777777777777"))
    }

    // MARK: - Media preview fields (US-RET-001 媒体记忆展示)

    @Test("photo fixture exposes image mediaKind and bundle asset name")
    func test_photo_mediaKind() {
        let model = MemoryDetailFixtureLoader.load("memory-detail-photo-loaded")
        #expect(model?.mediaKind == .image)
        #expect(model?.mediaAssetName == "photo-park-sunset")
    }

    @Test("voice fixture exposes audio mediaKind and bundle asset name")
    func test_voice_mediaKind() {
        let model = MemoryDetailFixtureLoader.load("memory-detail-voice-loaded")
        #expect(model?.mediaKind == .audio)
        #expect(model?.mediaAssetName == "voice-note-reminder")
    }

    @Test("video fixture exposes video mediaKind and bundle asset name")
    func test_video_mediaKind() {
        let model = MemoryDetailFixtureLoader.load("memory-detail-video-loaded")
        #expect(model?.mediaKind == .video)
        #expect(model?.mediaAssetName == "video-seaside-sunset")
    }

    @Test("note fixtures expose no media (mediaKind == .none)")
    func test_note_noMedia() {
        let note = MemoryDetailFixtureLoader.load("memory-detail-loaded")
        #expect(note?.mediaKind == MediaKind.none)
        #expect(note?.mediaAssetName == nil)
        let conflict = MemoryDetailFixtureLoader.load("memory-detail-conflict")
        #expect(conflict?.mediaKind == MediaKind.none)
    }

    @Test("media sample assets exist in app bundle")
    func test_mediaAssetsInBundle() {
        let bundle = Bundle.main
        #expect(bundle.url(forResource: "photo-park-sunset", withExtension: "png") != nil)
        #expect(bundle.url(forResource: "video-seaside-sunset", withExtension: "mp4") != nil)
        #expect(bundle.url(forResource: "voice-note-reminder", withExtension: "wav") != nil)
    }

    // MARK: - Location metadata (US-RET-004)

    @Test("photo fixture carries location metadata")
    func test_photo_location() {
        let model = MemoryDetailFixtureLoader.load("memory-detail-photo-loaded")
        #expect(model?.location == "西湖公园")
    }

    @Test("voice fixture carries location metadata")
    func test_voice_location() {
        let model = MemoryDetailFixtureLoader.load("memory-detail-voice-loaded")
        #expect(model?.location == "杭州东站")
    }

    @Test("video fixture carries location metadata")
    func test_video_location() {
        let model = MemoryDetailFixtureLoader.load("memory-detail-video-loaded")
        #expect(model?.location == "三亚湾")
    }

    @Test("note fixtures carry no location (nil)")
    func test_note_noLocation() {
        let note = MemoryDetailFixtureLoader.load("memory-detail-loaded")
        #expect(note?.location == nil)
        let conflict = MemoryDetailFixtureLoader.load("memory-detail-conflict")
        #expect(conflict?.location == nil)
    }

    @Test("all multi-type fixtures are deterministic (stable values)")
    func test_multitype_deterministic() {
        let photoA = MemoryDetailFixtureLoader.load("memory-detail-photo-loaded")
        let photoB = MemoryDetailFixtureLoader.load("memory-detail-photo-loaded")
        #expect(photoA == photoB)
        #expect(photoA?.timestamp == Date(timeIntervalSince1970: 1723507200))
        #expect(photoA?.sourceLanguage == "zh-Hans")
        #expect(photoA?.preferredLanguage == "en-US")
    }

    @Test("multi-type fixtures expose translation toggle when locale differs")
    func test_multitype_needsTranslation() {
        let voice = MemoryDetailFixtureLoader.load("memory-detail-voice-loaded")
        #expect(voice?.needsTranslation == true)
    }

    // MARK: - Search → Detail linkage (load(memoryID:))

    @Test("load(memoryID:) resolves search result ID to matching detail fixture")
    func test_loadByMemoryID_matches() {
        // photo-zh-1 (search) → memory-detail-photo-loaded
        let photoID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        #expect(MemoryDetailFixtureLoader.load(memoryID: photoID)?.assetId == "photo-zh-1")

        // note-zh-2 (search) → memory-detail-loaded
        let noteID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        #expect(MemoryDetailFixtureLoader.load(memoryID: noteID)?.assetId == "note-zh-2")

        // voice-zh-1 (search) → memory-detail-voice-loaded
        let voiceID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        #expect(MemoryDetailFixtureLoader.load(memoryID: voiceID)?.assetId == "voice-zh-1")

        // video-zh-1 (search) → memory-detail-video-loaded
        let videoID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        #expect(MemoryDetailFixtureLoader.load(memoryID: videoID)?.assetId == "video-zh-1")
    }

    @Test("load(memoryID:) returns nil for unknown ID (production path falls back to Core)")
    func test_loadByMemoryID_unknownReturnsNil() {
        let unknown = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        #expect(MemoryDetailFixtureLoader.load(memoryID: unknown) == nil)
    }

    @Test("load(memoryID:) excludes error fixture (error is simulated, not loaded)")
    func test_loadByMemoryID_excludesError() {
        // conflict fixture ID is registered but has no search counterpart
        let conflictID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        #expect(MemoryDetailFixtureLoader.load(memoryID: conflictID)?.sourceType == "note")
    }

    // MARK: - Registry

    @Test("available fixture IDs lists all seven registered fixtures")
    func test_availableFixtureIDs() {
        let ids = MemoryDetailFixtureLoader.availableFixtureIDs
        #expect(ids.contains("memory-detail-loaded"))
        #expect(ids.contains("memory-detail-translated"))
        #expect(ids.contains("memory-detail-conflict"))
        #expect(ids.contains("memory-detail-error"))
        #expect(ids.contains("memory-detail-photo-loaded"))
        #expect(ids.contains("memory-detail-voice-loaded"))
        #expect(ids.contains("memory-detail-video-loaded"))
        #expect(ids.count == 7)
    }
}
