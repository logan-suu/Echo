// ==========================================
// 文件: 2.4_IngestPipelineVideoTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-005 (视频记忆摄入)
//            docs/02-architecture/数据流全链路技术说明文档.md §3.2 (视频摄入)
// 任务: 2.4 - IngestPipeline：视频摄入
// AC 覆盖: US-ING-005 AC-1 (帧采样 ≤2fps, ≤20 帧, CLIP 向量化),
//          AC-2 (SenseVoice 离线转写, 文本向量化),
//          AC-3 (memoryGroupId 关联画面与音频),
//          AC-4 (PHAsset 引用, 不复制存储),
//          AC-5 (审计 .videoIngested, frameCount, audioTranscriptLength, hasAudio)
// 架构约束: AGENTS.md §4.1 (Pipeline 契约), R-006 (PrivacyCheckpoint)
// 重要: @MainActor 标注因 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，Actor 初始化器需此隔离
// 生成时间: 2026-07-11
// ==========================================

import Testing
import Foundation
import ProximaKit
@testable import Echo

// MARK: - Test Suite: IngestPipeline Video Ingestion (US-ING-005)

@Suite("IngestPipeline Video Ingestion (US-ING-005)", .serialized)
@MainActor
struct IngestPipelineVideoTests {

    // MARK: - Dependencies

    let db = DatabaseManager.shared
    let privacyActor = PrivacyActor.shared
    let excludedAssets = ExcludedAssetsActor.shared
    let vectorStore = VectorStoreActor(dimension: 512)

    /// Stub embedder — returns controllable vectors for deterministic testing
    let stubEmbedder = StubEmbedder()

    /// Stub ASR engine — returns controllable transcript for deterministic testing
    let stubASR = StubASREngine()

    /// System under test
    var sut: IngestPipeline {
        IngestPipeline(
            embedder: stubEmbedder,
            asrEngine: stubASR,
            privacyActor: privacyActor,
            vectorStore: vectorStore,
            excludedAssets: excludedAssets
        )
    }

    // MARK: - Setup & Teardown

    init() async throws {
        try await db.open()
        // Clean state from previous test runs
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
        // 3F.1+ suites may write ConsentStore (deny-by-default gate) first;
        // this suite must clear it or residual consent makes privacyActor.validate deny
        // (CI test-order pollution)
        try await db.execute(sql: "DELETE FROM ConsentStore")
        // Also clear the shared singleton's in-memory enforcement state (Xcode 16.4 CI
        // suite ordering differs; deleting the DB alone is not enough — another suite may
        // enable enforcement after this init)
        await privacyActor.disableConsentEnforcement()
        // Ensure photo and video data sources are authorized
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice", "video"],
            policyVersion: 1
        ))
    }

    // MARK: - AC-1: 帧采样 ≤2fps, 总帧数 ≤20, CLIP 向量化

    @Test("AC-1: successful video ingestion with ≤20 frames, each CLIP-vectorized")
    func test_AC1_frameSampling_CLIP() async throws {
        let videoAssetId = "VID-AC1"
        let frameCount = 10
        let frameAssetIds = (0..<frameCount).map { "frame-\($0)-\(UUID().uuidString.prefix(4))" }
        let audioTrackId = "audio-AC1"

        // Set known non-zero embedding for each frame
        let knownVector: [Float] = Array(0..<512).map { Float($0) * 0.001 }
        await stubEmbedder.setNextEmbedding(knownVector)
        await stubEmbedder.setNextError(nil)

        await stubASR.setNextTranscript("这是测试视频的音频转写文本")
        await stubASR.setNextError(nil)

        let traceID = UUID().uuidString
        let memories = try await sut.ingestVideo(
            assetId: videoAssetId,
            frameAssetIds: frameAssetIds,
            audioTrackAssetId: audioTrackId,
            traceID: traceID
        )

        // AC-1: Frame count matches input (≤20, which is enforced at call site)
        // Each frame produces one MemoryEntry, plus one for audio transcript
        #expect(memories.count == frameCount + 1)

        // All frame memories have sourceType "video_frame"
        let frameMemories = memories.filter { $0.sourceType == "video_frame" }
        #expect(frameMemories.count == frameCount)

        // All frame memories have 512-dim embeddings
        for fm in frameMemories {
            #expect(fm.embedding.count == 512)
            #expect(fm.assetId.contains("frame-"))
        }

        // AC-1: privacyBlurApplied must be false (no blurring)
        for fm in frameMemories {
            #expect(fm.privacyBlurApplied == false)
        }
    }

    // MARK: - AC-2: SenseVoice 离线转写, 文本向量化

    @Test("AC-2: audio track is transcribed by ASR engine, transcript is vectorized")
    func test_AC2_audioTranscription_textVectorized() async throws {
        let videoAssetId = "VID-AC2"
        let frameAssetIds = ["frame-AC2"]
        let audioTrackId = "audio-AC2"
        let transcriptText = "这段视频记录了上海外滩的日落景象"

        await stubEmbedder.setNextEmbedding(Array(repeating: Float(0.5), count: 512))
        await stubEmbedder.setNextError(nil)

        await stubASR.setNextTranscript(transcriptText)
        await stubASR.setNextError(nil)

        let traceID = UUID().uuidString
        let memories = try await sut.ingestVideo(
            assetId: videoAssetId,
            frameAssetIds: frameAssetIds,
            audioTrackAssetId: audioTrackId,
            traceID: traceID
        )

        // AC-2: One audio transcript memory exists
        let audioMemories = memories.filter { $0.sourceType == "video_audio" }
        #expect(audioMemories.count == 1)

        let audioMemory = audioMemories[0]
        #expect(audioMemory.embedding.count == 512)
        // audio transcript's assetId should reference the video (AC-4)
        #expect(audioMemory.assetId == videoAssetId)
    }

    @Test("AC-2: video with no audio track (hasAudio=false)")
    func test_AC2_noAudioTrack() async throws {
        let videoAssetId = "VID-AC2-noaudio"
        let frameAssetIds = ["frame1-AC2", "frame2-AC2"]

        await stubEmbedder.setNextEmbedding(Array(repeating: Float(0.5), count: 512))
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        // nil audioTrackAssetId → hasAudio should be false
        let memories = try await sut.ingestVideo(
            assetId: videoAssetId,
            frameAssetIds: frameAssetIds,
            audioTrackAssetId: nil,
            traceID: traceID
        )

        // Only frame memories, no audio transcription
        #expect(memories.count == frameAssetIds.count)
        #expect(memories.allSatisfy { $0.sourceType == "video_frame" })
    }

    // MARK: - AC-3: memoryGroupId 关联画面与音频

    @Test("AC-3: all frame + audio memories share the same memoryGroupId")
    func test_AC3_memoryGroupId_linking() async throws {
        let videoAssetId = "VID-AC3"
        let frameAssetIds = ["frame1-AC3", "frame2-AC3", "frame3-AC3"]
        let audioTrackId = "audio-AC3"

        await stubEmbedder.setNextEmbedding(Array(repeating: Float(0.3), count: 512))
        await stubEmbedder.setNextError(nil)
        await stubASR.setNextTranscript("音频内容")
        await stubASR.setNextError(nil)

        let traceID = UUID().uuidString
        let memories = try await sut.ingestVideo(
            assetId: videoAssetId,
            frameAssetIds: frameAssetIds,
            audioTrackAssetId: audioTrackId,
            traceID: traceID
        )

        // AC-3: All memories share a non-nil memoryGroupId
        #expect(memories.count == 4)  // 3 frames + 1 audio
        let groupId = try #require(memories.first).memoryGroupId
        #expect(groupId != nil)

        for memory in memories {
            #expect(memory.memoryGroupId == groupId)
        }

        // Verify memoryGroupId is in metadata
        for memory in memories {
            let metadata = try memory.encodeMetadata()
            let decoded = try MemoryEntry.decodeMetadata(from: metadata)
            #expect(decoded.memoryGroupId == groupId?.uuidString)
        }
    }

    // MARK: - AC-4: PHAsset 引用, 不复制存储

    @Test("AC-4: frame and audio memories reference PHAsset by assetId, no copy")
    func test_AC4_PHAsset_reference() async throws {
        let videoAssetId = "PH-ASSET-12345-67890"
        let frameAssetIds = ["frame-AC4"]
        let audioTrackId = "audio-AC4"

        await stubEmbedder.setNextEmbedding(Array(repeating: Float(0.1), count: 512))
        await stubEmbedder.setNextError(nil)
        await stubASR.setNextTranscript("test audio")
        await stubASR.setNextError(nil)

        let traceID = UUID().uuidString
        let memories = try await sut.ingestVideo(
            assetId: videoAssetId,
            frameAssetIds: frameAssetIds,
            audioTrackAssetId: audioTrackId,
            traceID: traceID
        )

        // AC-4: Frame memories have their own frame assetId
        let frameMemory = try #require(memories.first { $0.sourceType == "video_frame" })
        #expect(frameMemory.assetId == "frame-AC4")

        // AC-4: Audio memory references the video assetId (not copying audio separately)
        let audioMemory = try #require(memories.first { $0.sourceType == "video_audio" })
        #expect(audioMemory.assetId == videoAssetId)
    }

    // MARK: - AC-5: 审计 .videoIngested

    @Test("AC-5: audit log .videoIngested with frameCount, audioTranscriptLength, hasAudio=true")
    func test_AC5_audit_videoIngested() async throws {
        let videoAssetId = "VID-AC5"
        let frameAssetIds = ["f1", "f2", "f3", "f4", "f5"]
        let audioTrackId = "audio-AC5"
        let transcriptText = "一段五秒的视频，记录了两个人在公园散步聊天"

        await stubEmbedder.setNextEmbedding(Array(repeating: Float(0.2), count: 512))
        await stubEmbedder.setNextError(nil)
        await stubASR.setNextTranscript(transcriptText)
        await stubASR.setNextError(nil)

        let traceID = UUID().uuidString
        let _ = try await sut.ingestVideo(
            assetId: videoAssetId,
            frameAssetIds: frameAssetIds,
            audioTrackAssetId: audioTrackId,
            traceID: traceID
        )

        // AC-5: Verify audit log contains .videoIngested with frameCount/audioTranscriptLength/hasAudio
        let logs = try await db.executeQuery(sql: "SELECT * FROM AuditLog WHERE eventType='videoIngested' AND traceID=?", bindings: [.text(traceID)])
        #expect(logs.count >= 1, "Expected at least one .videoIngested audit log")

        if let row = logs.first {
            #expect(row["frameCount"]?.intValue.map(Int.init) == 5, "Expected frameCount=5")
            #expect(row["audioTranscriptLength"]?.intValue.map(Int.init) == transcriptText.count, "Expected audioTranscriptLength=\(transcriptText.count)")
            #expect(row["hasAudio"]?.intValue == 1, "Expected hasAudio=1 (true)")
        }
    }

    @Test("AC-5: audit .videoIngested with hasAudio=false when no audio track")
    func test_AC5_audit_noAudio() async throws {
        let videoAssetId = "VID-AC5-noaudio"
        let frameAssetIds = ["f1", "f2"]

        await stubEmbedder.setNextEmbedding(Array(repeating: Float(0.2), count: 512))
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let _ = try await sut.ingestVideo(
            assetId: videoAssetId,
            frameAssetIds: frameAssetIds,
            audioTrackAssetId: nil,
            traceID: traceID
        )

        // AC-5: Audit log should still exist, with hasAudio=false, frameCount=2
        let logs = try await db.executeQuery(sql: "SELECT * FROM AuditLog WHERE eventType='videoIngested' AND traceID=?", bindings: [.text(traceID)])
        #expect(logs.count >= 1, "Expected .videoIngested audit log even without audio")

        if let row = logs.first {
            #expect(row["frameCount"]?.intValue.map(Int.init) == 2, "Expected frameCount=2")
            #expect(row["hasAudio"]?.intValue == 0, "Expected hasAudio=0 (false)")
        }
    }

    // MARK: - PrivacyCheckpoint (R-006)

    @Test("PrivacyCheckpoint: video ingestion denied when video source not authorized")
    func test_privacyCheckpoint_videoDenied() async throws {
        // De-authorize video source
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice"],  // no "video"
            policyVersion: 1
        ))

        let videoAssetId = "VID-DENIED"
        let frameAssetIds = ["f1"]
        let audioTrackId = "audio-DENIED"

        let traceID = UUID().uuidString

        await #expect(throws: IngestError.self) {
            let _ = try await sut.ingestVideo(
                assetId: videoAssetId,
                frameAssetIds: frameAssetIds,
                audioTrackAssetId: audioTrackId,
                traceID: traceID
            )
        }
    }

    // MARK: - ExcludedAssets Check

    @Test("ExcludedAssets: excluded video asset is rejected")
    func test_excludedAssets_videoRejected() async throws {
        let videoAssetId = "VID-EXCLUDED"
        let frameAssetIds = ["f1"]
        let audioTrackId = "audio-EXCL"

        // Exclude the video asset
        try await excludedAssets.add(assetId: videoAssetId, sourceType: "video")

        // Re-authorize video
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice", "video"],
            policyVersion: 1
        ))

        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        await #expect(throws: IngestError.assetExcluded(assetId: videoAssetId)) {
            let _ = try await sut.ingestVideo(
                assetId: videoAssetId,
                frameAssetIds: frameAssetIds,
                audioTrackAssetId: audioTrackId,
                traceID: traceID
            )
        }
    }

    // MARK: - Error: Frame Embedding Failure

    @Test("Error: frame embedding failure throws embeddingFailed (L3)")
    func test_error_frameEmbeddingFailed() async throws {
        let videoAssetId = "VID-EMB-ERR"
        let frameAssetIds = ["f1", "f2"]
        let audioTrackId = "audio-ERR"

        await stubEmbedder.setNextError(EmbedderError.assetUnavailable(assetId: "f1"))

        let traceID = UUID().uuidString
        await #expect(throws: IngestError.embeddingFailed(underlying: EmbedderError.assetUnavailable(assetId: "f1"))) {
            let _ = try await sut.ingestVideo(
                assetId: videoAssetId,
                frameAssetIds: frameAssetIds,
                audioTrackAssetId: audioTrackId,
                traceID: traceID
            )
        }
    }

    // MARK: - Error: ASR Transcription Failure

    @Test("Error: ASR transcription failure throws audioTranscriptionFailed (L2)")
    func test_error_audioTranscriptionFailed() async throws {
        let videoAssetId = "VID-ASR-ERR"
        let frameAssetIds = ["f1"]
        let audioTrackId = "audio-ASR-ERR"

        await stubEmbedder.setNextEmbedding(Array(repeating: Float(0.1), count: 512))
        await stubEmbedder.setNextError(nil)
        await stubASR.setNextError(ASREngineError.transcriptionFailed(reason: "model not loaded"))

        let traceID = UUID().uuidString
        await #expect(throws: IngestError.self) {
            let _ = try await sut.ingestVideo(
                assetId: videoAssetId,
                frameAssetIds: frameAssetIds,
                audioTrackAssetId: audioTrackId,
                traceID: traceID
            )
        }
    }

    // MARK: - Edge: Empty Frames

    @Test("Edge: empty frameAssetIds array is rejected")
    func test_edge_emptyFrames() async throws {
        let videoAssetId = "VID-EMPTY"
        let frameAssetIds: [String] = []
        let audioTrackId = "audio-EMPTY"

        let traceID = UUID().uuidString
        await #expect(throws: IngestError.self) {
            let _ = try await sut.ingestVideo(
                assetId: videoAssetId,
                frameAssetIds: frameAssetIds,
                audioTrackAssetId: audioTrackId,
                traceID: traceID
            )
        }
    }

    // MARK: - Edge: Maximum 20 Frames

    @Test("Edge: exactly 20 frames are accepted (AC-1 max)")
    func test_edge_max20Frames() async throws {
        let videoAssetId = "VID-MAX20"
        let frameAssetIds = (0..<20).map { "f-\($0)" }
        let audioTrackId = "audio-MAX"

        await stubEmbedder.setNextEmbedding(Array(repeating: Float(0.1), count: 512))
        await stubEmbedder.setNextError(nil)
        await stubASR.setNextTranscript("max frames test")
        await stubASR.setNextError(nil)

        let traceID = UUID().uuidString
        let memories = try await sut.ingestVideo(
            assetId: videoAssetId,
            frameAssetIds: frameAssetIds,
            audioTrackAssetId: audioTrackId,
            traceID: traceID
        )

        // AC-1: max 20 frames + 1 audio = 21 memories
        #expect(memories.count == 21)
        let frameMemories = memories.filter { $0.sourceType == "video_frame" }
        #expect(frameMemories.count == 20)
    }

    @Test("Edge: more than 20 frames are rejected (AC-1 max)")
    func test_edge_tooManyFrames() async throws {
        let videoAssetId = "VID-OVER20"
        let frameAssetIds = (0..<21).map { "f-\($0)" }
        let audioTrackId = "audio-OVER20"

        let traceID = UUID().uuidString
        await #expect(throws: IngestError.tooManyFrames(max: 20)) {
            let _ = try await sut.ingestVideo(
                assetId: videoAssetId,
                frameAssetIds: frameAssetIds,
                audioTrackAssetId: audioTrackId,
                traceID: traceID
            )
        }
    }

    // MARK: - Batch Verify: All Memories in VectorStore

    @Test("All video memories are searchable in VectorStore after ingestion")
    func test_allMemories_searchable() async throws {
        let videoAssetId = "VID-SEARCH"
        let frameAssetIds = (0..<3).map { "sf-\($0)" }
        let audioTrackId = "audio-SEARCH"
        let queryVector = Array(repeating: Float(0.01), count: 512)

        // Use exact same vector for all so they're all retrievable
        await stubEmbedder.setNextEmbedding(queryVector)
        await stubEmbedder.setNextError(nil)
        await stubASR.setNextTranscript("search test transcript")
        await stubASR.setNextError(nil)

        let traceID = UUID().uuidString
        let beforeCount = await vectorStore.liveCount
        let memories = try await sut.ingestVideo(
            assetId: videoAssetId,
            frameAssetIds: frameAssetIds,
            audioTrackAssetId: audioTrackId,
            traceID: traceID
        )

        // Verify exactly 4 new memories ingested (3 frames + 1 audio)
        let afterCount = await vectorStore.liveCount
        #expect(Int(afterCount) - Int(beforeCount) == 4, "Expected 4 new memories ingested")

        // Search should find all ingested vectors
        let results = await vectorStore.search(query: queryVector, k: 10)
        #expect(results.count >= 4, "Expected at least 4 search results")
    }
}

// MARK: - R-1.3: Video Ingestion Rollback

extension IngestPipelineVideoTests {

    @Test("R-1.3: ASR failure rolls back already-written frame memories")
    func test_R13_asrFailure_rollsBackFrames() async throws {
        let videoAssetId = "VID-R13"
        let frameCount = 3
        let frameAssetIds = (0..<frameCount).map { "frame-R13-\($0)" }
        let audioTrackId = "audio-R13"

        // 帧 embedding 成功，但 ASR 抛错（模拟音频转写失败）
        await stubEmbedder.setNextEmbedding(Array(repeating: 1.0, count: 512))
        await stubEmbedder.setNextError(nil)
        await stubASR.setNextError(.transcriptionFailed(reason: "injected"))

        let beforeCount = await vectorStore.liveCount

        do {
            _ = try await sut.ingestVideo(
                assetId: videoAssetId,
                frameAssetIds: frameAssetIds,
                audioTrackAssetId: audioTrackId,
                traceID: UUID().uuidString
            )
            #expect(Bool(false), "Expected audioTranscriptionFailed")
        } catch let error as Echo.IngestError {
            if case .audioTranscriptionFailed = error {
                // expected
            } else {
                #expect(Bool(false), "Wrong error: \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected IngestError, got: \(error)")
        }

        // R-1.3 核心断言：3 个已写入的帧记忆应被回滚删除
        let afterCount = await vectorStore.liveCount
        #expect(afterCount == beforeCount, "R-1.3: ASR 失败后帧记忆必须回滚（before=\(beforeCount), after=\(afterCount)）")
    }
}
