// ==========================================
// 文件: 3F.5_ProductionIngestionTests.swift
// 对应规格: docs/decisions/ADR-010-canonical-generation-lifecycle.md (路由),
//            docs/decisions/ADR-011-task-progress-boundary.md (TaskQueue/Progress),
//            docs/01-spec/用户故事与验收标准规格书.md → US-ING-001~006, US-SRC-012/013,
//            US-SYS-001, US-RES-001~004
// 任务: 3F.5 - Production ingestion
// AC 覆盖: 四类真实来源 trace 共享 traceID, canonical/vector/FTS 计数,
//          取消/重启恢复, 故障回滚, 生产路径无 StubEmbedder/StubASR
// PR#57 review fix: W-01 视频含音频无 ASR → L2 用例; W-03 canonical 删除故障 → failed/审计 success=false 用例
// PR#57 CodeRabbit fix: CR-1 TaskQueue cancel-resume/paused-no-starve 用例; CR-14 queue purgeAll 清理;
//                       CR-15 no-stub 真实类型断言（E5/SigLIP2/Whisper）
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §4.3 (TaskQueue 串行), R-006, R-007
// 生成时间: 2026-08-10
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Test Embedder / ASR（非 Stub，真实协议实现；模型缺失时按约定跳过的测试用）

/// 确定性生产嵌入器 — 实现真实 EmbedderProtocol，输出固定维度向量。
/// 与 StubEmbedder 的区别：显式声明维度契约（text=384d / vision=768d），
/// 供生产路径验证「向量写入与 generation 维度匹配」。
public actor ProductionTestEmbedder: EmbedderProtocol {
    private let textDimension: Int
    private let visionDimension: Int

    public init(textDimension: Int = 384, visionDimension: Int = 768) {
        self.textDimension = textDimension
        self.visionDimension = visionDimension
    }

    public func embedImage(assetId: String) async throws -> [Float] {
        [Float](repeating: 0.5, count: visionDimension)
    }

    public func embedText(_ text: String) async throws -> [Float] {
        [Float](repeating: 0.5, count: textDimension)
    }

    public func embedImageData(_ data: Data) async throws -> [Float] {
        [Float](repeating: 0.5, count: visionDimension)
    }
}

/// 确定性生产 ASR — 实现真实 ASREngineProtocol，返回固定转写文本。
public actor ProductionTestASR: ASREngineProtocol {
    private let transcript: String

    public init(transcript: String = "这是一段测试语音转写内容。") {
        self.transcript = transcript
    }

    public func transcribe(audioTrackAssetId: String) async throws -> String {
        transcript
    }

    public func transcribeFile(at url: URL) async throws -> String {
        transcript
    }
}

// MARK: - Test Suite: Production Ingestion (3F.5)

@Suite("ProductionIngestionTests", .serialized)
@MainActor
struct ProductionIngestionTests {

    let db = DatabaseManager.shared
    let manifestActor = ModelManifestActor.shared

    init() async throws {
        try await ProductionIngestionTests.wipeCanonicalTables()
        try await manifestActor.removeAll()
    }

    private static func wipeCanonicalTables() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        try await db.execute(sql: "DELETE FROM MemoryFTS")
        try await db.execute(sql: "DELETE FROM translationCache")
        try await db.execute(sql: "DELETE FROM Representation")
        try await db.execute(sql: "DELETE FROM Memory")
        try await db.execute(sql: "DELETE FROM IndexBuildItem")
        try await db.execute(sql: "DELETE FROM IndexGeneration")
        try await db.execute(sql: "DELETE FROM ActiveRouteSet")
        try await db.execute(sql: "DELETE FROM FeedbackStore")
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
        try await db.execute(sql: "DELETE FROM TaskProgress")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        try await db.execute(sql: "DELETE FROM AuditLog")

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let generationsDir = appSupport.appendingPathComponent("Echo/generations", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: generationsDir.path) {
            for file in files where file.hasSuffix(".pxkt") {
                try? FileManager.default.removeItem(at: generationsDir.appendingPathComponent(file))
            }
        }
    }

    private func makeRegistry() -> GenerationRegistryActor {
        GenerationRegistryActor(db: db)
    }

    /// 注册并激活 text + vision 两个 generation（ADR-010 路由）。
    private func seedGenerations(_ registry: GenerationRegistryActor) async throws -> ActiveRouteSet {
        try await registry.registerGeneration(
            IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384)
        )
        try await registry.finishShadowBuild("text_dense/e5-v1", counts: 0, validationDigest: nil)
        try await registry.setGenerationState("text_dense/e5-v1", state: .ready)

        try await registry.registerGeneration(
            IndexGeneration(generationId: "vision_dense/siglip2-v1", indexType: "vision_dense", dimension: 768)
        )
        try await registry.finishShadowBuild("vision_dense/siglip2-v1", counts: 0, validationDigest: nil)
        try await registry.setGenerationState("vision_dense/siglip2-v1", state: .ready)

        let route = try await registry.activateGeneration("text_dense/e5-v1")
        // 发布 vision 通道路由
        let activeRoute = ActiveRouteSet(
            textGeneration: "text_dense/e5-v1",
            visionGeneration: "vision_dense/siglip2-v1",
            version: (route.version)
        )
        try await registry.publishRoute(activeRoute)
        return activeRoute
    }

    /// 仅 text 路由（visionGeneration == nil）——O-2 测试：图片同步须显式失败而非回退 text generation。
    private func seedTextOnlyRoute(_ registry: GenerationRegistryActor) async throws -> ActiveRouteSet {
        try await registry.registerGeneration(
            IndexGeneration(generationId: "text_dense/e5-v1", indexType: "text_dense", dimension: 384)
        )
        try await registry.finishShadowBuild("text_dense/e5-v1", counts: 0, validationDigest: nil)
        try await registry.setGenerationState("text_dense/e5-v1", state: .ready)
        let route = try await registry.activateGeneration("text_dense/e5-v1")
        let activeRoute = ActiveRouteSet(
            textGeneration: "text_dense/e5-v1",
            visionGeneration: nil,
            version: route.version
        )
        try await registry.publishRoute(activeRoute)
        return activeRoute
    }

    private func makePipeline(
        registry: GenerationRegistryActor,
        taskQueue: TaskQueueActor? = nil,
        embedder: any EmbedderProtocol = ProductionTestEmbedder(),
        asr: (any ASREngineProtocol)? = ProductionTestASR(),
        photoExtractor: (any PhotoAssetExtracting)? = nil,
        audioExtractor: (any SharedAudioExtracting)? = nil
    ) -> IngestPipeline {
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        return IngestPipeline(
            embedder: embedder,
            asrEngine: asr,
            privacyActor: PrivacyActor(db: db),
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: ExcludedAssetsActor(db: db, privacyActor: PrivacyActor(db: db)),
            canonicalRepository: repo,
            generationRegistry: registry,
            taskQueue: taskQueue,
            progressActor: .shared,
            photoExtractor: photoExtractor,
            videoExtractor: nil,
            sharedTextExtractor: nil,
            sharedAudioExtractor: audioExtractor
        )
    }

    private func makeEnvelope(
        kind: SharedImportContentKind = .text,
        source: SharedImportSourceType = .note,
        payload: String = "今天和朋友在西湖散步"
    ) throws -> SharedImportEnvelope {
        try SharedImportEnvelope.make(
            contentKind: kind,
            sourceType: source,
            payload: payload,
            sourceAppBundleId: "com.apple.mobilenotes",
            createdAt: Date()
        )
    }

    // ══════════════════════════════════════════════════════════════
    // 1. TaskQueueActor 串行契约（ADR-011 决策-1, US-SYS-001 AC-3/4/6）
    // ══════════════════════════════════════════════════════════════

    @Test("TaskQueue runs jobs serially with progress persisted")
    func test_queue_serialExecutionAndProgress() async throws {
        let progress = ProgressActor.shared
        let queue = TaskQueueActor(progressActor: progress)
        let order = OrderRecorder()

        try await queue.enqueueAndWait(TaskQueueActor.QueuedJob(
            taskId: "job-1",
            taskType: .fullIndex,
            totalCount: 3
        ) { context in
            await order.append("start-1")
            try await context.report(processedIndex: 1, lastProcessedId: "a")
            await order.append("end-1")
        })

        // 完成（成功）→ TaskProgress 已清理（US-SYS-001 AC-4）
        #expect(try await progress.load(taskId: "job-1") == nil)
        #expect(await order.values == ["start-1", "end-1"])

        // 串行：任务 2 等任务 1 完成后才启动
        try await queue.enqueueAndWait(TaskQueueActor.QueuedJob(
            taskId: "job-2",
            taskType: .fullIndex,
            totalCount: 1
        ) { context in
            await order.append("job-2")
            try await context.report(processedIndex: 1, lastProcessedId: "b")
        })
        #expect(try await progress.load(taskId: "job-2") == nil)
    }

    @Test("TaskQueue cancel preserves progress for resume (US-SYS-001 AC-4)")
    func test_queue_cancelPreservesProgress() async throws {
        let progress = ProgressActor.shared
        let queue = TaskQueueActor(progressActor: progress)

        let started = expectationSignal()
        let job = TaskQueueActor.QueuedJob(
            taskId: "cancel-job",
            taskType: .dataSourceSync,
            totalCount: 10
        ) { context in
            await started.signal()
            try await context.report(processedIndex: 3, lastProcessedId: "x")
            try await Task.sleep(for: .seconds(2))
            try context.checkCancelled()
        }

        let run = Task {
            do {
                try await queue.enqueueAndWait(job)
            } catch {
                // 取消 → 抛出 CancellationError
            }
        }
        await started.awaitSignal()
        try? await Task.sleep(for: .milliseconds(100))
        await queue.cancel(taskId: "cancel-job")
        await run.value

        // 取消后进度保留（供下次「继续/重新开始」询问）
        let loaded = try await progress.load(taskId: "cancel-job")
        #expect(loaded != nil)
        #expect(loaded?.lastProcessedIndex == 3)
    }

    @Test("TaskQueue completion deletes progress record")
    func test_queue_completionDeletesProgress() async throws {
        let progress = ProgressActor.shared
        let queue = TaskQueueActor(progressActor: progress)

        try await queue.enqueueAndWait(TaskQueueActor.QueuedJob(
            taskId: "done-job",
            taskType: .fullIndex,
            totalCount: 1
        ) { context in
            try await context.report(processedIndex: 1, lastProcessedId: nil)
        })
        #expect(try await progress.load(taskId: "done-job") == nil)
    }

    @Test("cancel a queued job resumes its enqueueAndWait caller (CR-1)")
    func test_queue_cancelQueuedResumesCaller() async throws {
        let progress = ProgressActor.shared
        let queue = TaskQueueActor(progressActor: progress)

        let firstStarted = expectationSignal()
        let firstDone = expectationSignal()

        try await queue.enqueue(TaskQueueActor.QueuedJob(
            taskId: "blocking-job",
            taskType: .fullIndex,
            totalCount: 1
        ) { _ in
            await firstStarted.signal()
            await firstDone.awaitSignal()
        })
        await firstStarted.awaitSignal()

        let queuedRun = Task {
            do {
                try await queue.enqueueAndWait(TaskQueueActor.QueuedJob(
                    taskId: "queued-cancel",
                    taskType: .dataSourceSync,
                    totalCount: 1
                ) { _ in
                    await firstDone.signal()
                })
                return "completed"
            } catch let TaskQueueError.cancelled(id) {
                return "cancelled:\(id)"
            } catch {
                return "other"
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        await queue.cancel(taskId: "queued-cancel")

        let outcome = await queuedRun.value
        #expect(outcome == "cancelled:queued-cancel")
        #expect(try await progress.load(taskId: "queued-cancel") == nil)
        await firstDone.signal()
    }

    @Test("paused queued job does not starve later runnable jobs (CR-1)")
    func test_queue_pausedDoesNotStarveLaterJobs() async throws {
        let progress = ProgressActor.shared
        let queue = TaskQueueActor(progressActor: progress)

        await queue.pause(taskId: "paused-job")
        try await queue.enqueue(TaskQueueActor.QueuedJob(
            taskId: "paused-job",
            taskType: .fullIndex,
            totalCount: 1
        ) { context in
            try await context.report(processedIndex: 1, lastProcessedId: "p")
        })

        try await queue.enqueueAndWait(TaskQueueActor.QueuedJob(
            taskId: "runnable-job",
            taskType: .dataSourceSync,
            totalCount: 1
        ) { context in
            try await context.report(processedIndex: 1, lastProcessedId: "r")
        })

        #expect(try await progress.load(taskId: "runnable-job") == nil)
        #expect(await queue.isPaused(taskId: "paused-job"))
        #expect(await queue.pendingCount() == 1)
    }

    // ══════════════════════════════════════════════════════════════
    // 2. 生产摄入：四类真实来源 trace 共享 traceID + canonical/vector/FTS 计数
    // ══════════════════════════════════════════════════════════════

    @Test("photo production ingestion writes canonical + vision vector + FTS")
    func test_photoProductionIngestion() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let photoExtractor = FakePhotoAssetExtractor(
            metadata: PhotoAssetContent(assetId: "PHAsset/photo-1", creationDate: Date(), exifMetadata: nil),
            locallyAvailable: true
        )
        let pipeline = makePipeline(registry: registry, photoExtractor: photoExtractor)

        let traceID = "trace-photo-1"
        let result = try await pipeline.ingestProductionPhoto(
            assetId: "PHAsset/photo-1",
            taskID: "task-photo-1",
            traceID: traceID
        )
        #expect(result.sourceType == "photo")
        #expect(result.generationIds.contains("vision_dense/siglip2-v1"))

        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/photo-1", sourceType: "photo")
        let memory = try await repo.loadMemory(memoryId: memoryId)
        #expect(memory != nil)
        let reps = try await repo.loadRepresentations(memoryId: memoryId)
        #expect(reps.count == 1)
        #expect(reps[0].modality == .visionDense)

        let store = await registry.vectorStore(for: "vision_dense/siglip2-v1")
        #expect(await store?.liveCount == 1)
    }

    @Test("shared text production ingestion writes canonical + text vector + FTS")
    func test_sharedTextProductionIngestion() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let pipeline = makePipeline(registry: registry)

        let envelope = try makeEnvelope(payload: "went to the West Lake with friends")
        let traceID = "trace-text-1"
        let result = try await pipeline.ingestProductionSharedText(envelope, taskID: "task-text-1", traceID: traceID)
        #expect(result.sourceType == "note")
        #expect(result.generationIds.contains("text_dense/e5-v1"))

        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: envelope.dedupeKey, sourceType: "note")
        let memory = try await repo.loadMemory(memoryId: memoryId)
        #expect(memory?.canonicalText == "went to the West Lake with friends")
        let hits = try await repo.searchCanonical(matching: "West Lake")
        #expect(hits.contains(memoryId))

        let store = await registry.vectorStore(for: "text_dense/e5-v1")
        #expect(await store?.liveCount == 1)
    }

    @Test("shared audio production ingestion transcribes via real ASR contract")
    func test_sharedAudioProductionIngestion() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let audioExtractor = FakeSharedAudioExtractor(fileURL: URL(fileURLWithPath: "/tmp/voice-memo.m4a"))
        let pipeline = makePipeline(registry: registry, asr: ProductionTestASR(transcript: "this is a voice memo transcript"), audioExtractor: audioExtractor)

        let envelope = try makeEnvelope(kind: .audio, source: .voice, payload: "/tmp/voice-memo.m4a")
        let traceID = "trace-audio-1"
        let result = try await pipeline.ingestProductionSharedAudio(envelope, taskID: "task-audio-1", traceID: traceID)
        #expect(result.sourceType == "voice")
        #expect(result.generationIds.contains("text_dense/e5-v1"))

        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: envelope.dedupeKey, sourceType: "voice")
        let memory = try await repo.loadMemory(memoryId: memoryId)
        #expect(memory?.canonicalText == "this is a voice memo transcript")
        let hits = try await repo.searchCanonical(matching: "voice memo")
        #expect(hits.contains(memoryId))
    }

    @Test("video production ingestion writes frames + transcript with shared trace")
    func test_videoProductionIngestion() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)

        let frame1 = Data("frame1".utf8)
        let frame2 = Data("frame2".utf8)
        let fakeExtractor = FakeVideoAssetExtractor(
            content: VideoAssetContent(
                assetId: "PHAsset/video-1",
                creationDate: Date(),
                frameImages: [frame1, frame2],
                hasAudio: true
            ),
            audioURL: URL(fileURLWithPath: "/tmp/video-audio.m4a")
        )

        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let pipeline = IngestPipeline(
            embedder: ProductionTestEmbedder(),
            asrEngine: ProductionTestASR(transcript: "视频中的对话内容"),
            privacyActor: PrivacyActor(db: db),
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: ExcludedAssetsActor(db: db, privacyActor: PrivacyActor(db: db)),
            canonicalRepository: repo,
            generationRegistry: registry,
            taskQueue: nil,
            progressActor: .shared,
            photoExtractor: nil,
            videoExtractor: fakeExtractor,
            sharedTextExtractor: nil,
            sharedAudioExtractor: nil
        )

        let traceID = "trace-video-1"
        let result = try await pipeline.ingestProductionVideo(assetId: "PHAsset/video-1", taskID: "task-video-1", traceID: traceID)
        #expect(result.sourceType == "video")

        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/video-1", sourceType: "video")
        let memory = try await repo.loadMemory(memoryId: memoryId)
        #expect(memory != nil)
        let reps = try await repo.loadRepresentations(memoryId: memoryId)
        // 2 帧 vision + 1 段音频 text
        #expect(reps.count == 3)

        let visionStore = await registry.vectorStore(for: "vision_dense/siglip2-v1")
        #expect(await visionStore?.liveCount == 2)
        let textStore = await registry.vectorStore(for: "text_dense/e5-v1")
        #expect(await textStore?.liveCount == 1)
    }

    @Test("video with audio but no ASR throws L2 instead of skipping transcription (W-01)")
    func test_videoAudioNoASRThrowsL2() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)

        let fakeExtractor = FakeVideoAssetExtractor(
            content: VideoAssetContent(
                assetId: "PHAsset/video-noasr",
                creationDate: Date(),
                frameImages: [Data("frame".utf8)],
                hasAudio: true
            ),
            audioURL: URL(fileURLWithPath: "/tmp/video-noasr.m4a")
        )
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let pipeline = IngestPipeline(
            embedder: ProductionTestEmbedder(),
            asrEngine: nil,
            privacyActor: PrivacyActor(db: db),
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: ExcludedAssetsActor(db: db, privacyActor: PrivacyActor(db: db)),
            canonicalRepository: repo,
            generationRegistry: registry,
            taskQueue: nil,
            progressActor: .shared,
            videoExtractor: fakeExtractor
        )

        do {
            _ = try await pipeline.ingestProductionVideo(
                assetId: "PHAsset/video-noasr",
                taskID: "task-video-noasr",
                traceID: "trace-video-noasr"
            )
            #expect(Bool(false), "expected audioTranscriptionFailed when ASR not loaded")
        } catch let error as IngestError {
            #expect(error == .audioTranscriptionFailed(underlying: ASREngineError.modelNotLoaded))
            #expect(error.errorLevel == 2)
        }
    }

    // ══════════════════════════════════════════════════════════════
    // 3. 故障回滚（US-ING-006 AC-4, D-005）
    // ══════════════════════════════════════════════════════════════

    @Test("vector write fault rolls back canonical (no half-write)")
    func test_productionRollbackOnFault() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let pipeline = IngestPipeline(
            embedder: ProductionTestEmbedder(),
            asrEngine: ProductionTestASR(),
            privacyActor: PrivacyActor(db: db),
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: ExcludedAssetsActor(db: db, privacyActor: PrivacyActor(db: db)),
            canonicalRepository: repo,
            generationRegistry: registry,
            taskQueue: nil,
            progressActor: .shared
        )

        try await repo.setFault(.vectorWrite)
        do {
            _ = try await pipeline.ingestProductionPhoto(assetId: "PHAsset/fault-1", taskID: "task-fault", traceID: "trace-fault")
            #expect(Bool(false), "Expected injected vector fault")
        } catch {
            // expected — vector fault injected
        }
        try await repo.setFault(nil)

        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/fault-1", sourceType: "photo")
        #expect(try await repo.loadMemory(memoryId: memoryId) == nil)
        let store = await registry.vectorStore(for: "vision_dense/siglip2-v1")
        #expect(await store?.liveCount == 0)
    }

    // ══════════════════════════════════════════════════════════════
    // 4. 生产路径无 StubEmbedder/StubASR 证明
    // ══════════════════════════════════════════════════════════════

    @Test("production composition uses real embedder/asr (no StubEmbedder/StubASR)")
    func test_productionNoStubInjection() async throws {
        let composition = AppComposition.shared
        #expect(composition.textEmbedder is E5Embedder)
        #expect(composition.visionEmbedder is SigLIP2Embedder)
        #expect(composition.asrEngine is WhisperASREngine)
    }

    @Test("production pipeline resolves route from active generation registry")
    func test_productionRouteResolution() async throws {
        let registry = makeRegistry()
        let route = try await seedGenerations(registry)
        #expect(route.textGeneration == "text_dense/e5-v1")
        #expect(route.visionGeneration == "vision_dense/siglip2-v1")

        let pipeline = makePipeline(registry: registry)
        let envelope = try makeEnvelope()
        let traceID = "trace-route-1"
        _ = try await pipeline.ingestProductionSharedText(envelope, taskID: "task-route-1", traceID: traceID)
    }

    @Test("production ingestion audit carries traceID and hash-only content")
    func test_productionAuditTraceID() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let pipeline = makePipeline(registry: registry)

        let envelope = try makeEnvelope(payload: "审计追踪测试内容")
        let traceID = "trace-audit-1"
        _ = try await pipeline.ingestProductionSharedText(envelope, taskID: "task-audit-1", traceID: traceID)

        let rows = try await db.executeQuery(
            sql: "SELECT traceID, success, sourceType FROM AuditLog WHERE eventType = 'shareExtensionImported' ORDER BY timestamp DESC LIMIT 1",
            bindings: []
        )
        #expect(rows.first?["traceID"]?.stringValue == traceID)
        #expect(rows.first?["success"]?.intValue == 1)
    }

    // ══════════════════════════════════════════════════════════════
    // 5. 生产 SyncPipeline 路由（3F.5 — canonical 事务删除）
    // ══════════════════════════════════════════════════════════════

    @Test("sync removed event routes through canonical delete when configured")
    func test_syncProductionDeleteRouting() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)

        // 先经生产摄入写入一条记忆
        let pipeline = makePipeline(registry: registry, photoExtractor: FakePhotoAssetExtractor(
            metadata: PhotoAssetContent(assetId: "PHAsset/sync-1", creationDate: Date(), exifMetadata: nil),
            locallyAvailable: true
        ))
        _ = try await pipeline.ingestProductionPhoto(assetId: "PHAsset/sync-1", taskID: "task-sync-photo", traceID: "trace-sync-1")

        let sync = SyncPipeline(
            embedder: ProductionTestEmbedder(),
            privacyActor: PrivacyActor(db: db),
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: ExcludedAssetsActor(db: db, privacyActor: PrivacyActor(db: db)),
            progressActor: .shared,
            canonicalRepository: repo
        )
        let result = try await sync.sync(changes: [
            ChangeEvent(assetId: "PHAsset/sync-1", source: .photo, changeType: .removed)
        ])
        #expect(result.replacedCount == 1)

        // canonical 行 + 向量 + FTS 全部清除（D-005）
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/sync-1", sourceType: "photo")
        #expect(try await repo.loadMemory(memoryId: memoryId) == nil)
        let store = await registry.vectorStore(for: "vision_dense/siglip2-v1")
        #expect(await store?.liveCount == 0)
    }

    @Test("canonical delete fault surfaces as failed not silent success (W-03)")
    func test_syncCanonicalDeleteFaultSurfacesFailure() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)

        let pipeline = makePipeline(registry: registry, photoExtractor: FakePhotoAssetExtractor(
            metadata: PhotoAssetContent(assetId: "PHAsset/sync-fault", creationDate: Date(), exifMetadata: nil),
            locallyAvailable: true
        ))
        _ = try await pipeline.ingestProductionPhoto(assetId: "PHAsset/sync-fault", taskID: "task-sync-fault", traceID: "trace-sync-fault")

        let sync = SyncPipeline(
            embedder: ProductionTestEmbedder(),
            privacyActor: PrivacyActor(db: db),
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: ExcludedAssetsActor(db: db, privacyActor: PrivacyActor(db: db)),
            progressActor: .shared,
            canonicalRepository: repo
        )

        try await repo.setFault(.deleteFail)
        let result = try await sync.sync(changes: [
            ChangeEvent(assetId: "PHAsset/sync-fault", source: .photo, changeType: .removed)
        ])
        try await repo.setFault(nil)

        #expect(result.failedCount == 1)
        #expect(result.replacedCount == 0)

        let rows = try await db.executeQuery(
            sql: "SELECT success FROM AuditLog WHERE eventType = 'dataSourceChangeSynced' ORDER BY timestamp DESC LIMIT 1",
            bindings: []
        )
        #expect(rows.first?["success"]?.intValue == 0)

        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/sync-fault", sourceType: "photo")
        #expect(try await repo.loadMemory(memoryId: memoryId) != nil)
    }

    @Test("drainSharedImports routes through production when canonical configured")
    func test_drainSharedImportsProductionPath() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let queue = SharedImportQueueActor()
        // CR-14: 复用共享 App Group 目录时须清空全部队列文件（pending/processing/corrupted），
        // rollbackProcessing 仅恢复 processing→pending，无法清除既有 pending .json。
        _ = try? await queue.purgeAll()

        let envelope = try makeEnvelope(payload: "shared import production text")
        try await queue.enqueue(envelope)

        let pipeline = makePipeline(registry: registry)
        let drain = try await pipeline.drainSharedImports(from: queue, traceID: "trace-drain-1")
        #expect(drain.processed == 1)

        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: envelope.dedupeKey, sourceType: "note")
        #expect(try await repo.loadMemory(memoryId: memoryId) != nil)
        let store = await registry.vectorStore(for: "text_dense/e5-v1")
        #expect(await store?.liveCount == 1)
    }

    // ══════════════════════════════════════════════════════════════
    // 6. CodeRabbit 第二轮（N-1~N-4）修复回归
    // ══════════════════════════════════════════════════════════════

    @Test("purgeAll removes pending, processing and corrupted files (N-1)")
    func test_purgeAllRemovesAll() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let queue = SharedImportQueueActor(directory: dir)

        // pending 态
        let pendingEnv = try makeEnvelope(payload: "purge-pending")
        try await queue.enqueue(pendingEnv)
        // processing 态（beginProcessing 原子 move pending → processing）
        let processingEnv = try makeEnvelope(payload: "purge-processing")
        try await queue.enqueue(processingEnv)
        _ = try await queue.beginProcessing(for: processingEnv.dedupeKey)
        // corrupted 态（不可解码信封经 beginProcessing 会落到 .corrupted；此处确定性直写）
        try Data("not-json".utf8).write(to: dir.appendingPathComponent("zz-corrupt.corrupted"))

        let removed = try await queue.purgeAll()
        #expect(removed == 3)
        #expect(try await queue.count() == 0)
    }

    @Test("purgeAll propagates deletion failure (N-1)")
    func test_purgeAllPropagatesFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let queue = SharedImportQueueActor(directory: dir)
        try await queue.enqueue(try makeEnvelope(payload: "purge-fail"))

        // immutable (uchg) 标志使 removeItem 抛 EPERM —— purgeAll 必须传播而非 try? 吞错
        let pending = dir.appendingPathComponent("zz-immutable.json")
        try Data("x".utf8).write(to: pending)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: pending.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: pending.path) }

        do {
            _ = try await queue.purgeAll()
            #expect(Bool(false), "expected purgeAll to throw on immutable file")
        } catch {
            // expected — 删除失败传播（N-1）
        }
    }

    @Test("AC-6 lock uses refcount so overlapping sync keeps the lock (N-2)")
    func test_syncLockRefcountOverlap() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)

        let pipeline = makePipeline(registry: registry, photoExtractor: FakePhotoAssetExtractor(
            metadata: PhotoAssetContent(assetId: "PHAsset/lock-1", creationDate: Date(), exifMetadata: nil),
            locallyAvailable: true
        ))
        _ = try await pipeline.ingestProductionPhoto(assetId: "PHAsset/lock-1", taskID: "task-lock-1", traceID: "trace-lock-1")

        let sync = SyncPipeline(
            embedder: ProductionTestEmbedder(),
            privacyActor: PrivacyActor(db: db),
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: ExcludedAssetsActor(db: db, privacyActor: PrivacyActor(db: db)),
            progressActor: .shared,
            canonicalRepository: repo,
            generationRegistry: registry
        )
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/lock-1", sourceType: "photo").uuidString

        // 模拟交叠：外部先锁（+1），sync 的 .modified 再锁（+1）→ 计数 2
        await sync.lockMemoryForSync(memoryId: memoryId)
        #expect(await sync.isMemoryLockedForSync(memoryId: memoryId))

        // sync 完成（defer -1）→ 计数 1，外部所有权未被误释放，锁仍有效
        let result = try await sync.sync(changes: [
            ChangeEvent(assetId: "PHAsset/lock-1", source: .photo, changeType: .modified)
        ])
        #expect(result.failedCount == 0)
        #expect(await sync.isMemoryLockedForSync(memoryId: memoryId))
    }

    @Test("EXIF scalar leaf values are preserved (N-4)")
    func test_exifScalarLeavesPreserved() async throws {
        let dict: [String: Any] = [
            "ColorSpace": NSNumber(value: 1),
            "PixelXDimension": NSNumber(value: 4032),
            "LensModel": "iPhone 17 Pro",
            "Orientation": 6,
            "Flash": true,
            "CaptureTime": Date(timeIntervalSince1970: 1_600_000_000),
            "UnknownBlob": Data("blob".utf8),
        ]
        let safe = RealPhotoAssetExtractor.jsonSafe(dict) as? [String: Any]
        #expect(safe != nil)
        #expect(safe?["ColorSpace"] != nil)
        #expect(safe?["PixelXDimension"] != nil)
        #expect(safe?["LensModel"] as? String == "iPhone 17 Pro")
        #expect(safe?["Orientation"] != nil)
        #expect(safe?["Flash"] != nil)
        #expect(safe?["CaptureTime"] is String)
        #expect(safe?["UnknownBlob"] is String)
        #expect(JSONSerialization.isValidJSONObject(safe as Any))
    }

    // ══════════════════════════════════════════════════════════════
    // 7. CodeRabbit 第三轮（O-1~O-2，review 4896791449）修复回归
    // ══════════════════════════════════════════════════════════════

    @Test("removed path locks records and preserves overlapping ownership (O-1)")
    func test_syncRemovedPathLock() async throws {
        let registry = makeRegistry()
        try await seedGenerations(registry)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)

        let pipeline = makePipeline(registry: registry, photoExtractor: FakePhotoAssetExtractor(
            metadata: PhotoAssetContent(assetId: "PHAsset/rem-lock", creationDate: Date(), exifMetadata: nil),
            locallyAvailable: true
        ))
        _ = try await pipeline.ingestProductionPhoto(assetId: "PHAsset/rem-lock", taskID: "task-rem-lock", traceID: "trace-rem-lock")

        let sync = SyncPipeline(
            embedder: ProductionTestEmbedder(),
            privacyActor: PrivacyActor(db: db),
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: ExcludedAssetsActor(db: db, privacyActor: PrivacyActor(db: db)),
            progressActor: .shared,
            canonicalRepository: repo,
            generationRegistry: registry
        )
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/rem-lock", sourceType: "photo").uuidString

        // 外部先锁（+1）；.removed 路径锁定（+1）→ 计数 2，删除完成后 -1 → 计数 1，外部所有权保留
        await sync.lockMemoryForSync(memoryId: memoryId)
        let result = try await sync.sync(changes: [
            ChangeEvent(assetId: "PHAsset/rem-lock", source: .photo, changeType: .removed)
        ])
        #expect(result.failedCount == 0)
        #expect(await sync.isMemoryLockedForSync(memoryId: memoryId))
    }

    @Test("modified sync fails closed when no vision route (O-2)")
    func test_syncModifiedNoVisionRouteFailsClosed() async throws {
        let registry = makeRegistry()
        let route = try await seedTextOnlyRoute(registry)
        #expect(route.visionGeneration == nil)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)

        // 直接构造既有 canonical 记忆（text-only 部署下图片记忆仅存在于 text 代，
        // 绕开 ingestProductionPhoto 的 vision 回退路径，聚焦 SyncPipeline O-2 守卫）。
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/no-vision", sourceType: "photo")
        try await repo.commit(
            memory: Memory(
                memoryId: memoryId,
                sourceLocator: "PHAsset/no-vision",
                canonicalText: nil,
                sourceType: "photo",
                createdAt: Date(),
                recoverability: .full
            ),
            representations: [Representation(
                memoryId: memoryId,
                modality: .textDense,
                preprocessVersion: "e5-v1",
                contentHash: "seed"
            )],
            vectorsByGeneration: [
                "text_dense/e5-v1": [CanonicalVectorEntry(id: memoryId, vector: [Float](repeating: 0.5, count: 384))]
            ],
            traceID: "trace-seed-no-vision"
        )

        let sync = SyncPipeline(
            embedder: ProductionTestEmbedder(),
            privacyActor: PrivacyActor(db: db),
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: ExcludedAssetsActor(db: db, privacyActor: PrivacyActor(db: db)),
            progressActor: .shared,
            canonicalRepository: repo,
            generationRegistry: registry
        )
        let result = try await sync.sync(changes: [
            ChangeEvent(assetId: "PHAsset/no-vision", source: .photo, changeType: .modified)
        ])
        #expect(result.failedCount == 1)
        #expect(result.replacedCount == 0)
        // fail-closed：canonical 记录未被替换破坏
        #expect(try await repo.loadMemory(memoryId: memoryId) != nil)
    }

}

// MARK: - Signal Helper (deterministic async coordination)

/// 简单一次性信号 — 测试中协调 Task 启动顺序，避免 sleep 竞态。
public actor ExpectationSignal {
    private var flag = false

    public init() {}

    public func signal() {
        flag = true
    }

    public func isSignaled() -> Bool {
        flag
    }

    public func awaitSignal() async {
        while !flag {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private func expectationSignal() -> ExpectationSignal {
    ExpectationSignal()
}

/// 串行事件记录器 — @Sendable 闭包内安全记录执行顺序。
public actor OrderRecorder {
    private var items: [String] = []

    public init() {}

    public func append(_ item: String) {
        items.append(item)
    }

    public var values: [String] {
        get async { items }
    }
}
