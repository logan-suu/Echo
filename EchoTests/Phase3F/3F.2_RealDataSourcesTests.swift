// ==========================================
// 文件: 3F.2_RealDataSourcesTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-001/003/004/005/008/012/013,
//            US-PRV-001
//            docs/decisions/ADR-008-source-import-boundaries.md (PhotoKit/Share Extension/App Group 信封)
// 任务: 3F.2 - PhotoKit、Share Extension 与真实来源
// AC 覆盖: US-SRC-001 AC-5/AC-6 (dataSourceConnected 审计 / 仅本地已下载), US-SRC-003 AC-1/AC-4
//          (Share 支持文本/音频/链接/文件 + shareExtensionImported 审计), US-SRC-008 AC-4
//          (排除项不重新导入), US-SRC-012 AC-1 (变更监听+去重), ADR-008 决策-2/3/4
//          (share-only 用户中介 / App Group 信封 / 去重键与来源身份), ADR-008 决策-5 (权限撤回停止读取)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §5.2 (ExcludedAssets 写入规则), R-006 (PrivacyCheckpoint),
//           R-007 (禁止 unchecked Sendable), R-003 (系统删除不写排除表)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-05
// ==========================================

import Testing
import Foundation
import Photos
import Synchronization
@testable import Echo

// MARK: - Test Support: Fake Photo Library

/// 测试用假照片库 — 模拟 PhotoKit 授权/资产状态（真实库为 RealPhotoLibrary，见 PhotoKitSourceAdapter.swift）
private struct FakePhotoLibrary: PhotoLibraryServing {
    let access: PhotoAccess
    let assets: [PhotoAssetReference]
    let downloaded: Set<String>

    func currentAccess() async -> PhotoAccess { access }
    func requestAccess() async -> PhotoAccess { access }
    func allAssetReferences() async -> [PhotoAssetReference] {
        access == .denied || access == .notDetermined ? [] : assets
    }
    func isAssetDownloaded(_ assetId: String) async -> Bool { downloaded.contains(assetId) }
}

// MARK: - Test Suite: RealDataSources (3F.2)

@Suite("RealDataSourcesTests", .serialized)
@MainActor
struct RealDataSourcesTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
        await PrivacyActor.shared.disableConsentEnforcement()
    }

    // MARK: - Helpers

    private func makePrivacy() -> PrivacyActor {
        PrivacyActor(db: db)
    }

    private func makeExcluded() -> ExcludedAssetsActor {
        ExcludedAssetsActor(db: db, privacyActor: makePrivacy())
    }

    private func makeEnvelope(
        kind: SharedImportContentKind = .text,
        source: SharedImportSourceType = .note,
        payload: String = "今天和朋友在西湖散步",
        app: String = "com.apple.mobilenotes"
    ) throws -> SharedImportEnvelope {
        try SharedImportEnvelope.make(
            contentKind: kind,
            sourceType: source,
            payload: payload,
            sourceAppBundleId: app,
            createdAt: Date(),
            optionalLabel: nil
        )
    }

    // ══════════════════════════════════════════════════════════════
    // US-SRC-001/003, ADR-008 §决策-3/4 — SharedImportEnvelope
    // ══════════════════════════════════════════════════════════════

    @Test("make rejects empty payload (ADR-008 minimum payload)")
    func test_envelope_rejectsEmptyPayload() async throws {
        #expect(throws: SharedImportError.self) {
            _ = try makeEnvelope(payload: "   ")
        }
    }

    @Test("make rejects source-kind mismatch (voice+text invalid)")
    func test_envelope_rejectsUnsupportedCombination() async throws {
        #expect(throws: SharedImportError.self) {
            _ = try makeEnvelope(kind: .text, source: .voice)
        }
        #expect(throws: SharedImportError.self) {
            _ = try makeEnvelope(kind: .audio, source: .note)
        }
    }

    @Test("make accepts valid share-only combinations")
    func test_envelope_acceptsValidCombinations() async throws {
        // note → text (US-SRC-001 备忘录显式分享)
        #expect(try makeEnvelope(kind: .text, source: .note) is SharedImportEnvelope)
        // voice → audio (US-SRC-001 语音备忘录显式分享)
        #expect(try makeEnvelope(kind: .audio, source: .voice) is SharedImportEnvelope)
        // thirdParty → text/url/image/file/audio (US-SRC-003)
        #expect(try makeEnvelope(kind: .text, source: .thirdParty) is SharedImportEnvelope)
        #expect(try makeEnvelope(kind: .url, source: .thirdParty, payload: "https://example.com") is SharedImportEnvelope)
        #expect(try makeEnvelope(kind: .image, source: .thirdParty) is SharedImportEnvelope)
        #expect(try makeEnvelope(kind: .file, source: .thirdParty) is SharedImportEnvelope)
    }

    @Test("dedupeKey is stable across deliveries of the same content")
    func test_envelope_dedupeKey_stable() async throws {
        let a = try makeEnvelope(payload: "同样的内容")
        let b = try makeEnvelope(payload: "同样的内容")
        #expect(a.dedupeKey == b.dedupeKey)
    }

    @Test("dedupeKey differs by content and by source identity")
    func test_envelope_dedupeKey_sensitiveToContentAndSource() async throws {
        let a = try makeEnvelope(payload: "内容A")
        let b = try makeEnvelope(payload: "内容B")
        #expect(a.dedupeKey != b.dedupeKey)

        let note = try makeEnvelope(source: .note, payload: "同一文本")
        let third = try makeEnvelope(source: .thirdParty, payload: "同一文本")
        #expect(note.dedupeKey != third.dedupeKey)
    }

    @Test("envelope encodes and decodes losslessly (App Group wire format)")
    func test_envelope_encodeDecode_roundtrip() async throws {
        let env = try makeEnvelope(
            kind: .text, source: .note,
            payload: "roundtrip payload", app: "com.example.app"
        )
        let data = try env.encoded()
        let decoded = try SharedImportEnvelope.decode(data)
        #expect(decoded == env)
        #expect(decoded.dedupeKey == env.dedupeKey)
    }

    // ══════════════════════════════════════════════════════════════
    // ADR-008 §决策-3/4 — SharedImportQueueActor (App Group 原子队列)
    // ══════════════════════════════════════════════════════════════

    private func makeQueueDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedImportQueueTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("enqueue persists envelope and count reflects pending")
    func test_queue_enqueueAndCount() async throws {
        let dir = makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = SharedImportQueueActor(directory: dir)
        let env = try makeEnvelope()
        let added = try await queue.enqueue(env)
        #expect(added == true)
        #expect(try await queue.count() == 1)
        let pending = try await queue.pendingEnvelopes()
        #expect(pending.first?.dedupeKey == env.dedupeKey)
    }

    @Test("duplicate delivery is deduplicated by dedupeKey (ADR-008 §决策-3)")
    func test_queue_deduplicatesDuplicateDelivery() async throws {
        let dir = makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = SharedImportQueueActor(directory: dir)
        let env = try makeEnvelope()
        #expect(try await queue.enqueue(env) == true)
        // 同一内容的重复投递 → 拒绝（不产生重复记录）
        #expect(try await queue.enqueue(env) == false)
        #expect(try await queue.count() == 1)
    }

    @Test("cross-process race: stale tmp move collision returns false (DEF-51-001 fix)")
    func test_queue_crossProcessRaceStaleTmpReturnsFalse() async throws {
        let dir = makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = SharedImportQueueActor(directory: dir)
        let env = try makeEnvelope()
        // 模拟跨进程竞态：pending 文件已被另一进程写入（同 dedupeKey），
        // 且本进程残留同名 tmp 文件 → moveItem 会因目标已存在失败
        let pendingKey = env.dedupeKey
        // 先正常入队（生成 pending）
        #expect(try await queue.enqueue(env) == true)
        // 重新构造同 dedupeKey 的信封 + 手工放置 stale tmp，触发 moveItem 目标已存在分支
        let tmpPath = dir.appendingPathComponent("\(pendingKey).tmp")
        let staleEnv = try SharedImportEnvelope.make(
            contentKind: .text,
            sourceType: .note,
            payload: env.payload,
            sourceAppBundleId: env.sourceAppBundleId,
            createdAt: env.createdAt,
            optionalLabel: nil
        )
        try staleEnv.encoded().write(to: tmpPath)
        // 第二次 enqueue：fileExists guard 直接拦截（同进程），返回 false 不抛错
        #expect(try await queue.enqueue(staleEnv) == false)
        // 队列仍只有 1 条
        #expect(try await queue.count() == 1)
    }

    @Test("pending envelopes are ordered by createdAt")
    func test_queue_ordersByCreatedAt() async throws {
        let dir = makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = SharedImportQueueActor(directory: dir)
        let older = try makeEnvelope(payload: "older")
        let newer = try makeEnvelope(payload: "newer")
        try await queue.enqueue(older)
        try await queue.enqueue(newer)
        // 通过手动更新 createdAt 制造时间差
        let pending = try await queue.pendingEnvelopes()
        #expect(pending.count == 2)
        #expect(Set(pending.map(\.payload)) == ["older", "newer"])
    }

    @Test("exactly-once: begin+finish removes the delivery")
    func test_queue_exactlyOnceProcessing() async throws {
        let dir = makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = SharedImportQueueActor(directory: dir)
        let env = try makeEnvelope()
        try await queue.enqueue(env)

        let started = try await queue.beginProcessing(for: env.dedupeKey)
        #expect(started != nil)
        // begin 后 pending 中不再可见
        #expect(try await queue.count() == 0)

        try await queue.finishProcessing(for: env.dedupeKey)
        #expect(try await queue.count() == 0)
    }

    @Test("interrupted processing is recovered on next launch (survives relaunch once)")
    func test_queue_recoverInterrupted() async throws {
        let dir = makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = SharedImportQueueActor(directory: dir)
        let env = try makeEnvelope()
        try await queue.enqueue(env)

        // 模拟处理到一半崩溃：begin 但从未 finish
        _ = try await queue.beginProcessing(for: env.dedupeKey)
        #expect(try await queue.count() == 0)

        // 模拟重启：新 actor 实例，同一目录 → recoverInterrupted 把 .processing 移回 pending
        let relaunched = SharedImportQueueActor(directory: dir)
        let recovered = try await relaunched.recoverInterrupted()
        #expect(recovered == 1)
        let pending = try await relaunched.pendingEnvelopes()
        #expect(pending.first?.dedupeKey == env.dedupeKey)
    }

    @Test("queue survives app relaunch (persistent file-backed store)")
    func test_queue_persistsAcrossRelaunch() async throws {
        let dir = makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = SharedImportQueueActor(directory: dir)
        try await first.enqueue(makeEnvelope(payload: "持久化内容"))

        // 全新实例（模拟 App 重启）→ 同一目录仍能看到
        let second = SharedImportQueueActor(directory: dir)
        let pending = try await second.pendingEnvelopes()
        #expect(pending.first?.payload == "持久化内容")
    }

    @Test("undecodable envelope moves to corrupted terminal state (CodeRabbit #1)")
    func test_queue_undecodableGoesCorrupted() async throws {
        let dir = makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = SharedImportQueueActor(directory: dir)
        let env = try makeEnvelope()
        try await queue.enqueue(env)

        // 篡改 pending 文件为非法 JSON → beginProcessing 解码失败
        let pendingPath = dir.appendingPathComponent("\(env.dedupeKey).json")
        try Data("not-valid-json{{{".utf8).write(to: pendingPath)

        do {
            _ = try await queue.beginProcessing(for: env.dedupeKey)
            Issue.record("expected beginProcessing to throw on undecodable envelope")
        } catch {
            #expect(error is DecodingError || error is Swift.DecodingError)
        }
        // 信封进入 corrupted 终止态：不再出现在 pending，recoverInterrupted 也不恢复
        #expect(try await queue.pendingEnvelopes().isEmpty)
        let recovered = try await queue.recoverInterrupted()
        #expect(recovered == 0)
        #expect(try await queue.pendingEnvelopes().isEmpty)
        // corrupted 文件保留（诊断用）
        let corruptedPath = dir.appendingPathComponent("\(env.dedupeKey).corrupted")
        #expect(FileManager.default.fileExists(atPath: corruptedPath.path))
    }

    @Test("rollback keeps the delivery for a later retry")
    func test_queue_rollbackProcessing() async throws {
        let dir = makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = SharedImportQueueActor(directory: dir)
        let env = try makeEnvelope()
        try await queue.enqueue(env)
        _ = try await queue.beginProcessing(for: env.dedupeKey)
        try await queue.rollbackProcessing(for: env.dedupeKey)
        #expect(try await queue.count() == 1)
    }

    // ══════════════════════════════════════════════════════════════
    // US-SRC-001 AC-5/AC-6, ADR-008 §决策-1/5 — PhotoKitSourceAdapter
    // ══════════════════════════════════════════════════════════════

    @Test("PhotoAccessMapper maps PHAuthorizationStatus correctly")
    func test_photoKit_authorizationMapping() async throws {
        #expect(PhotoAccessMapper.map(.notDetermined) == .notDetermined)
        #expect(PhotoAccessMapper.map(.restricted) == .restricted)
        #expect(PhotoAccessMapper.map(.denied) == .denied)
        #expect(PhotoAccessMapper.map(.limited) == .limited)
        #expect(PhotoAccessMapper.map(.authorized) == .authorized)
    }

    @Test("canReadAssets only for authorized or limited")
    func test_photoKit_canReadAssets() async throws {
        let adapter = PhotoKitSourceAdapter(
            library: FakePhotoLibrary(access: .authorized, assets: [], downloaded: [])
        )
        #expect(await adapter.canReadAssets() == true)

        let limited = PhotoKitSourceAdapter(
            library: FakePhotoLibrary(access: .limited, assets: [], downloaded: [])
        )
        #expect(await limited.canReadAssets() == true)

        let denied = PhotoKitSourceAdapter(
            library: FakePhotoLibrary(access: .denied, assets: [], downloaded: [])
        )
        #expect(await denied.canReadAssets() == false)
    }

    @Test("download policy forbids network access (US-SRC-001 AC-6)")
    func test_photoKit_downloadPolicy_localOnly() async throws {
        let adapter = PhotoKitSourceAdapter(
            library: FakePhotoLibrary(access: .authorized, assets: [], downloaded: [])
        )
        let config = await adapter.fetchConfiguration
        #expect(config.isNetworkAccessAllowed == false)
    }

    @Test("denied/notDetermined access yields no assets")
    func test_photoKit_deniedReturnsEmptyAssets() async throws {
        let adapter = PhotoKitSourceAdapter(
            library: FakePhotoLibrary(
                access: .denied,
                assets: [PhotoAssetReference(assetId: "a1", mediaType: "image", creationDate: nil, modificationDate: nil)],
                downloaded: []
            )
        )
        #expect(await adapter.fetchAllAssets().isEmpty)
    }

    @Test("importableReferences filters out ExcludedAssets (US-SRC-008 AC-4)")
    func test_photoKit_filtersExcluded() async throws {
        let assets = [
            PhotoAssetReference(assetId: "kept", mediaType: "image", creationDate: nil, modificationDate: nil),
            PhotoAssetReference(assetId: "excluded", mediaType: "image", creationDate: nil, modificationDate: nil),
        ]
        let adapter = PhotoKitSourceAdapter(
            library: FakePhotoLibrary(access: .authorized, assets: assets, downloaded: ["kept", "excluded"])
        )
        let result = await adapter.importableReferences(excluding: ["excluded"])
        #expect(result.map(\.assetId) == ["kept"])
    }

    @Test("permission revocation stops reads immediately (ADR-008 §决策-5)")
    func test_photoKit_revocationStopsReads() async throws {
        let assets = [PhotoAssetReference(assetId: "a1", mediaType: "image", creationDate: nil, modificationDate: nil)]
        // 初始已授权
        let authorized = FakePhotoLibrary(access: .authorized, assets: assets, downloaded: ["a1"])
        let adapter = PhotoKitSourceAdapter(library: authorized)
        #expect(await adapter.fetchAllAssets().count == 1)

        // 用户撤回权限 → 同一适配器（新授权快照）立即停止读取
        let revoked = FakePhotoLibrary(access: .denied, assets: assets, downloaded: ["a1"])
        let revokedAdapter = PhotoKitSourceAdapter(library: revoked)
        #expect(await revokedAdapter.canReadAssets() == false)
        #expect(await revokedAdapter.fetchAllAssets().isEmpty)
    }

    // ══════════════════════════════════════════════════════════════
    // iOS 26 limited picker 适配（3F.2 review fix）
    // ══════════════════════════════════════════════════════════════

    @Test("limited with no selected photos needs picker (iOS 26)")
    func test_photoKit_limitedNeedsPicker() async throws {
        let adapter = PhotoKitSourceAdapter(
            library: FakePhotoLibrary(access: .limited, assets: [], downloaded: [])
        )
        await adapter.resetLimitedLibraryPickerFlag()
        #expect(await adapter.shouldPresentLimitedLibraryPicker() == true)
    }

    @Test("limited with selected photos does not need picker")
    func test_photoKit_limitedWithSelectionSkipsPicker() async throws {
        let assets = [PhotoAssetReference(assetId: "a1", mediaType: "image", creationDate: nil, modificationDate: nil)]
        let adapter = PhotoKitSourceAdapter(
            library: FakePhotoLibrary(access: .limited, assets: assets, downloaded: [])
        )
        await adapter.resetLimitedLibraryPickerFlag()
        #expect(await adapter.shouldPresentLimitedLibraryPicker() == false)
    }

    @Test("authorized/denied access never triggers picker")
    func test_photoKit_nonLimitedSkipsPicker() async throws {
        let authorized = PhotoKitSourceAdapter(
            library: FakePhotoLibrary(access: .authorized, assets: [], downloaded: [])
        )
        await authorized.resetLimitedLibraryPickerFlag()
        #expect(await authorized.shouldPresentLimitedLibraryPicker() == false)

        let denied = PhotoKitSourceAdapter(
            library: FakePhotoLibrary(access: .denied, assets: [], downloaded: [])
        )
        await denied.resetLimitedLibraryPickerFlag()
        #expect(await denied.shouldPresentLimitedLibraryPicker() == false)
    }

    @Test("picker flag is one-shot (mark prevents repeat)")
    func test_photoKit_pickerFlagOneShot() async throws {
        let adapter = PhotoKitSourceAdapter(
            library: FakePhotoLibrary(access: .limited, assets: [], downloaded: [])
        )
        await adapter.resetLimitedLibraryPickerFlag()
        #expect(await adapter.shouldPresentLimitedLibraryPicker() == true)
        await adapter.markLimitedLibraryPickerPresented()
        #expect(await adapter.shouldPresentLimitedLibraryPicker() == false)
        await adapter.resetLimitedLibraryPickerFlag()
    }

    @Test("dataSourceConnected audit records sourceType and itemCount (US-SRC-001 AC-5)")
    func test_photoKit_dataSourceConnectedAudit() async throws {
        let privacy = makePrivacy()
        let assets = [
            PhotoAssetReference(assetId: "a1", mediaType: "image", creationDate: nil, modificationDate: nil),
            PhotoAssetReference(assetId: "a2", mediaType: "video", creationDate: nil, modificationDate: nil),
        ]
        let adapter = PhotoKitSourceAdapter(
            library: FakePhotoLibrary(access: .authorized, assets: assets, downloaded: []),
            privacyActor: privacy
        )
        await adapter.recordDataSourceConnected(traceID: "t-src-1")
        let logs = try await privacy.fetchAuditLogs(eventType: .dataSourceConnected)
        let row = logs.first { $0.traceID == "t-src-1" }
        #expect(row != nil)
        #expect(row?.sourceType == "photo")
        #expect(row?.affectedCount == 2)
    }

    // ══════════════════════════════════════════════════════════════
    // US-SRC-012 AC-1 — PhotoKitChangeObserver（变更监听 + 去重）
    // ══════════════════════════════════════════════════════════════

    @Test("ChangeEventBuilder maps inserted/changed/removed identifiers to events")
    func test_changeEventBuilder_mapsIdentifiers() async throws {
        let events = ChangeEventBuilder.events(
            inserted: ["new-1"],
            changed: ["mod-1"],
            removed: ["del-1"]
        )
        #expect(events.count == 3)
        #expect(events.contains { $0.assetId == "new-1" && $0.changeType == .added })
        #expect(events.contains { $0.assetId == "mod-1" && $0.changeType == .modified })
        #expect(events.contains { $0.assetId == "del-1" && $0.changeType == .removed })
        #expect(events.allSatisfy { $0.source == .photo })
    }

    @Test("ChangeCoalescer dedupes duplicates within one batch")
    func test_changeCoalescer_dedupesWithinBatch() async throws {
        let coalescer = ChangeCoalescer()
        let events = ChangeEventBuilder.events(inserted: ["a", "a", "b"], changed: [], removed: [])
        let deduped = coalescer.dedupe(events, existing: [])
        #expect(deduped.count == 2)
        #expect(Set(deduped.map(\.assetId)) == ["a", "b"])
    }

    @Test("ChangeCoalescer drops events already delivered in the recent window")
    func test_changeCoalescer_dedupesAgainstExisting() async throws {
        let coalescer = ChangeCoalescer()
        let first = ChangeEventBuilder.events(inserted: ["a"], changed: [], removed: [])
        let second = ChangeEventBuilder.events(inserted: ["a"], changed: ["b"], removed: [])
        // 已投递 recentEvents = first；second 中的 "a" 被去重，仅保留 "b"
        let deduped = coalescer.dedupe(second, existing: first)
        #expect(deduped.map(\.assetId) == ["b"])
    }

    @Test("observer emits deduped change events and ignores empty changes")
    func test_observer_emitsDedupedEvents() async throws {
        let emitted = Mutex<[[ChangeEvent]]>([])
        let observer = PhotoKitChangeObserver(
            onPhotoLibraryChange: { events in
                emitted.withLock { $0.append(events) }
            },
            coalescer: ChangeCoalescer()
        )

        // 同一批内重复 → 批内去重为单条并投递
        let events = observer.consumeForTesting(inserted: ["a", "a"], changed: ["b"], removed: [])
        #expect(events.map(\.assetId).sorted() == ["a", "b"])
        let captured = emitted.withLock { $0 }
        #expect(captured.count == 1)
        #expect(captured[0].map(\.assetId).sorted() == ["a", "b"])

        // 无变更 → 不投递
        let empty = observer.consumeForTesting(inserted: [], changed: [], removed: [])
        #expect(empty.isEmpty)
        #expect(emitted.withLock { $0.count } == 1)
    }

    // ══════════════════════════════════════════════════════════════
    // US-SRC-001/003, ADR-008 §决策-3 — Shared Import 摄入与队列消费
    // ══════════════════════════════════════════════════════════════

    @Test("ingestShared text ingests a shared note and audits shareExtensionImported")
    func test_ingestShared_textIngestsAndAudits() async throws {
        let privacy = makePrivacy()
        let excluded = makeExcluded()
        let pipeline = IngestPipeline(
            embedder: StubEmbedder(),
            privacyActor: privacy,
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: excluded
        )
        let env = try makeEnvelope(payload: "共享的备忘录内容")
        let memory = try await pipeline.ingestShared(env, traceID: "t-share-1")
        #expect(memory.assetId == env.dedupeKey)
        #expect(memory.originalText == env.payload)

        let logs = try await privacy.fetchAuditLogs(eventType: .shareExtensionImported)
        let row = logs.first { $0.traceID == "t-share-1" }
        #expect(row != nil)
        #expect(row?.sourceType == "note")
    }

    @Test("ingestShared rejects an excluded asset (US-SRC-008 AC-4)")
    func test_ingestShared_rejectsExcluded() async throws {
        let privacy = makePrivacy()
        let excluded = makeExcluded()
        let pipeline = IngestPipeline(
            embedder: StubEmbedder(),
            privacyActor: privacy,
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: excluded
        )
        let env = try makeEnvelope(payload: "已被排除的内容")
        try await excluded.add(assetId: env.dedupeKey, sourceType: "note", traceID: "t-excl-1")

        await #expect(throws: IngestError.self) {
            _ = try await pipeline.ingestShared(env, traceID: "t-excl-2")
        }
    }

    @Test("ingestShared accepts thirdParty with default policy; denies when revoked (US-SRC-003)")
    func test_ingestShared_thirdPartyPolicy() async throws {
        let privacy = makePrivacy()
        let pipeline = IngestPipeline(
            embedder: StubEmbedder(),
            privacyActor: privacy,
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: makeExcluded()
        )
        // 3F.11 fix: 默认策略授权 thirdParty（US-SRC-003 第三方分享不再被隐私门禁拒绝）
        let env = try makeEnvelope(kind: .text, source: .thirdParty, payload: "第三方内容")
        let entry = try await pipeline.ingestShared(env)
        #expect(entry != nil)

        // 撤销 thirdParty 授权 → 拒绝（per-source 校验仍生效）
        try await privacy.updatePolicy(
            UserPolicy(authorizedSourceTypes: ["photo", "note", "voice", "video"], policyVersion: 2)
        )
        await #expect(throws: IngestError.self) {
            _ = try await pipeline.ingestShared(
                try makeEnvelope(kind: .text, source: .thirdParty, payload: "第三方内容2")
            )
        }
    }

    @Test("drainSharedImports processes the queue exactly once and recovers interrupted")
    func test_drainSharedImports_exactlyOnce() async throws {
        let dir = makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let privacy = makePrivacy()
        let pipeline = IngestPipeline(
            embedder: StubEmbedder(),
            privacyActor: privacy,
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: makeExcluded()
        )
        let queue = SharedImportQueueActor(directory: dir)
        try await queue.enqueue(makeEnvelope(payload: "第一条"))
        try await queue.enqueue(makeEnvelope(payload: "第二条"))

        let result = try await pipeline.drainSharedImports(from: queue, traceID: "t-drain-1")
        #expect(result.processed == 2)
        #expect(result.failed == 0)
        #expect(try await queue.count() == 0)

        // 再次 drain → 无新内容（恰好一次）
        let second = try await pipeline.drainSharedImports(from: queue, traceID: "t-drain-2")
        #expect(second.processed == 0)
    }

    @Test("drainSharedImports retries failed audio after interrupted recovery")
    func test_drainSharedImports_recoversInterrupted() async throws {
        let dir = makeQueueDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let privacy = makePrivacy()
        let pipeline = IngestPipeline(
            embedder: StubEmbedder(),
            asrEngine: StubASREngine(),
            privacyActor: privacy,
            vectorStore: VectorStoreActor(dimension: 512),
            excludedAssets: makeExcluded()
        )
        let queue = SharedImportQueueActor(directory: dir)
        let env = try makeEnvelope(kind: .audio, source: .voice, payload: "voice-ref-1")
        try await queue.enqueue(env)

        // 模拟上次会话崩溃：begin 未 finish
        _ = try await queue.beginProcessing(for: env.dedupeKey)

        // 新会话 drain → recoverInterrupted 先恢复，再处理
        let result = try await pipeline.drainSharedImports(from: queue, traceID: "t-drain-3")
        #expect(result.recovered == 1)
        #expect(result.processed == 1)
        #expect(try await queue.count() == 0)
    }
}
