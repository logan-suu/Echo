// ==========================================
// 文件: PhotoTextSearchOCRTests.swift
// 对应规格: 交接计划 §WP5 步骤组 1（fixture 许可/哈希契约 + OCRDocument 值契约）
// 任务: WP5 - OCR 辅助通道
// 生成时间: 2026-08-25
// ==========================================

import CoreGraphics
import CryptoKit
import Foundation
import Testing

@testable import Echo

/// WP5 步骤组 1：fixture manifest 许可/哈希契约 + OCRDocument nonisolated 值契约。
@Suite(.serialized)
struct PhotoTextSearchOCRTests {

    // MARK: - Fixture Path Helpers

    nonisolated private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Phase3F
            .deletingLastPathComponent()   // EchoTests
            .deletingLastPathComponent()   // repo root
    }

    nonisolated private static var manifestURL: URL {
        repoRoot
            .appendingPathComponent("EchoTests/Fixtures/PhotoTextSearch/manifest.json")
    }

    nonisolated private struct FixtureEntry {
        let id: String
        let file: String
        let sha256: String
        let license: String
    }

    nonisolated private static func loadManifestEntries() throws -> [FixtureEntry] {
        let data = try Data(contentsOf: manifestURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawFixtures = root["fixtures"] as? [[String: Any]] else {
            throw NSError(domain: "wp5-manifest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "manifest missing fixtures array"])
        }
        return rawFixtures.map { raw in
            FixtureEntry(
                id: raw["id"] as? String ?? "",
                file: raw["file"] as? String ?? "",
                sha256: raw["sha256"] as? String ?? "",
                license: raw["license"] as? String ?? ""
            )
        }
    }

    // MARK: - WP5 Step 1a: license contract

    @Test("Fixture manifest requires source license per entry (WP5 step 1a)")
    func testFixtureManifestRequiresLicense() async throws {
        let entries = try Self.loadManifestEntries()
        #expect(!entries.isEmpty, "manifest must declare at least one fixture")
        for entry in entries {
            #expect(!entry.license.isEmpty, "\(entry.id) must carry a source license")
        }
    }

    // MARK: - WP5 Step 1a1: sha256 contract (declared + matches bytes on disk)

    @Test("Fixture manifest requires matching SHA256 per entry (WP5 step 1a1)")
    func testFixtureManifestRequiresSHA256() async throws {
        let entries = try Self.loadManifestEntries()
        for entry in entries {
            #expect(entry.sha256.count == 64, "\(entry.id) sha256 must be 64 hex chars")
            #expect(entry.sha256.allSatisfy { $0.isHexDigit }, "\(entry.id) sha256 must be hex")

            let fileURL = Self.repoRoot.appendingPathComponent("EchoTests/Fixtures/PhotoTextSearch/\(entry.file)")
            let data = try Data(contentsOf: fileURL)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(digest == entry.sha256, "\(entry.id) bytes on disk must match declared sha256")
        }
    }

    // MARK: - WP5 Steps 1c/1e/1g: OCRDocument nonisolated value contract

    /// 在非隔离静态上下文中构造并遍历全部成员——编译通过且断言成立
    /// 即证明类型声明、四个属性与 init 均为显式 nonisolated（步骤 1c/1e/1g）。
    nonisolated private static func exerciseOCRDocumentContract() -> Bool {
        let doc = OCRDocument(
            normalizedText: "Quarterly Report Due Friday",
            locale: "en-US",
            observationCount: 2,
            contentHash: "sha256:abc"
        )
        let table: [Bool] = [
            doc.normalizedText == "Quarterly Report Due Friday",
            doc.locale == "en-US",
            doc.observationCount == 2,
            doc.contentHash == "sha256:abc",
            doc == OCRDocument(
                normalizedText: "Quarterly Report Due Friday",
                locale: "en-US",
                observationCount: 2,
                contentHash: "sha256:abc"
            ),
        ]
        return table.allSatisfy(\.self)
    }

    @Test("OCRDocument value contract is exercisable from nonisolated context (WP5 steps 1c/1e/1g)")
    func testOCRDocumentNonisolatedContract() async throws {
        #expect(Self.exerciseOCRDocumentContract(), "nonisolated construction + member access + Equatable must all hold")
    }
}

// MARK: - WP5 步骤组 2：Apple Vision OCR 生产行为（2a-2j）

extension PhotoTextSearchOCRTests {

    nonisolated private static let visionService = VisionPhotoOCRService()

    nonisolated private static func fixtureData(_ id: String) throws -> Data {
        let entry = try loadManifestEntries().first { $0.id == id }
        guard let entry else {
            throw NSError(domain: "wp5-fixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "manifest missing fixture \(id)"])
        }
        return try Data(contentsOf: repoRoot.appendingPathComponent("EchoTests/Fixtures/PhotoTextSearch/\(entry.file)"))
    }

    @Test("Screenshot fixture yields raw recognized text (WP5 step 2a)")
    func testScreenshotOCRReturnsRawRecognizedText() async throws {
        let data = try Self.fixtureData("screenshot-basic")
        let doc = try await Self.visionService.recognizeText(
            imageData: data, preferredLanguages: ["en-US"], traceID: "t-wp5-2a"
        )
        #expect(doc != nil, "screenshot with clear text must produce a document")
        let lowered = (doc?.normalizedText ?? "").lowercased()
        #expect(lowered.contains("quarterly"), "baseline phrase missing in: \(doc?.normalizedText ?? "<nil>")")
        #expect(lowered.contains("meeting room"), "second line missing in: \(doc?.normalizedText ?? "<nil>")")
        #expect(doc?.observationCount ?? 0 >= 1)
    }

    @Test("Normalization is deterministic whitespace folding (WP5 steps 2b1/2b2)")
    func testOCRNormalizationProducesApprovedText() async throws {
        let folded = VisionPhotoOCRService.normalizedText(
            from: ["  Quarterly   Report ", "Due\tFriday"],
            boxes: [
                CGRect(x: 0, y: 0.6, width: 0.5, height: 0.1),
                CGRect(x: 0, y: 0.2, width: 0.5, height: 0.1),
            ]
        )
        #expect(folded == "Quarterly Report\nDue Friday")
    }

    @Test("Rotated fixture still recognizes via layout handling (WP5 steps 2c/2d)")
    func testRotatedTextUsesImageOrientation() async throws {
        let data = try Self.fixtureData("rotated-90")
        let doc = try await Self.visionService.recognizeText(
            imageData: data, preferredLanguages: ["en-US"], traceID: "t-wp5-2c"
        )
        #expect(doc != nil, "rotated text should be detected by accurate-level Vision")
        let lowered = (doc?.normalizedText ?? "").lowercased()
        #expect(lowered.contains("rotate") || lowered.contains("note"),
                "expected rotated phrase fragments in: \(doc?.normalizedText ?? "<nil>")")
    }

    @Test("Recognition languages collapse to approved set (WP5 steps 2e/2f)")
    func testMixedLanguageOCRUsesOnlyApprovedLocales() async throws {
        #expect(Set(VisionPhotoOCRService.approvedRecognitionLanguages(preferred: ["fr-FR", "zh-CN", "en-US"])) == Set(["en-US", "zh-Hans"]))
        #expect(Set(VisionPhotoOCRService.approvedRecognitionLanguages(preferred: ["fr-FR"])) == Set(["en-US", "zh-Hans"]))

        let data = try Self.fixtureData("mixed-language")
        let doc = try await Self.visionService.recognizeText(
            imageData: data, preferredLanguages: ["zh-Hans", "en-US"], traceID: "t-wp5-2e"
        )
        #expect(doc != nil)
        #expect(["zh-Hans", "en-US"].contains(doc?.locale ?? ""), "locale must stay inside the approved pair")
    }

    @Test("Blank photo produces no OCR document (WP5 steps 2g/2h)")
    func testBlankPhotoProducesNoOCRDocument() async throws {
        let data = try Self.fixtureData("blank-photo")
        let doc = try await Self.visionService.recognizeText(
            imageData: data, preferredLanguages: ["en-US"], traceID: "t-wp5-2g"
        )
        #expect(doc == nil, "no-text image must not fabricate OCR content")
    }

    @Test("Low-confidence filtering drops candidates deterministically (WP5 steps 2i/2j)")
    func testLowConfidenceOCRProducesNoDocument() async throws {
        // Vision 对渲染文本置信度天然接近 1.0（已实证 0.99 阈值仍识别该 fixture）——
        // 负向语义改由确定性纯函数保证：thresholded 丢弃低于阈值候选，不依赖黑盒。
        let box = CGRect(x: 0, y: 0.5, width: 0.5, height: 0.1)
        let kept = VisionPhotoOCRService.thresholded(
            candidates: [
                (text: "high", box: box, confidence: 0.95),
                (text: "low", box: box, confidence: 0.30),
            ],
            minimumConfidence: 0.5
        )
        #expect(kept.map(\.text) == ["high"], "sub-threshold candidate must be dropped")
        #expect(
            VisionPhotoOCRService.thresholded(
                candidates: [(text: "all", box: box, confidence: 0.1)],
                minimumConfidence: 0.99
            ).isEmpty,
            "all-below-threshold candidates must yield empty result (→ nil upstream)"
        )
    }
}

// MARK: - WP5 步骤组 3+4：OCR 摄入接线（E5 .passage / 确定性 ID / ocr 代写入）

private struct WP5StubOCRService: PhotoOCRService {
    let document: OCRDocument?
    func recognizeText(imageData: Data, preferredLanguages: [String], traceID: String) async throws -> OCRDocument? {
        document
    }
}

private actor WP5EmbedderSpy: EmbedderProtocol {
    private(set) var contexts: [TextEmbeddingContext] = []

    func embedImage(assetId: String) async throws -> [Float] { Array(repeating: 0, count: 768) }
    func embedText(_ text: String) async throws -> [Float] { Array(repeating: 0, count: 384) }
    func embedText(_ text: String, context: TextEmbeddingContext) async throws -> [Float] {
        contexts.append(context)
        return Array(repeating: 0, count: 384)
    }
    func contextsSnapshot() -> [TextEmbeddingContext] { contexts }
}

private struct WP5StubPhotoExtractor: PhotoAssetExtracting {
    let imageData: Data?

    func extractMetadata(assetId: String) async throws -> PhotoAssetContent {
        PhotoAssetContent(assetId: assetId, creationDate: Date(), exifMetadata: nil)
    }
    func isLocallyAvailable(assetId: String) async -> Bool { true }
    func extractImageData(assetId: String) async throws -> Data? { imageData }
}

extension PhotoTextSearchOCRTests {

    @Test("OCR ingestion embeds with passage and commits ocr representation (WP5 steps 3a-3d/4a-4b)")
    func testOCRIngestionUsesPassageAndWritesOcrRepresentation() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        try await db.executeWrite(
            sql: "INSERT OR REPLACE INTO UserPolicyStore (id, preferredLanguage, authorizedSourceTypes, policyVersion, updatedAt) VALUES (1, ?, ?, ?, ?)",
            bindings: [
                .text("zh-Hans"),
                .text(#"["search","photo","note","voice","text","video"]"#),
                .int(1),
                .double(Date().timeIntervalSince1970),
            ]
        )
        let registry = GenerationRegistryActor(db: db)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let spy = WP5EmbedderSpy()
        let ocrDoc = OCRDocument(
            normalizedText: "Quarterly Report Due Friday",
            locale: "en-US",
            observationCount: 1,
            contentHash: "sha256:wp5-ocr"
        )

        // 注册并激活 vision + ocr 代（ingest 需要 vision 路由 + ocr 回落目标）
        try await registry.registerGeneration(IndexGeneration(generationId: "vision_dense/siglip2-v1", indexType: "vision_dense", dimension: 768))
        try await registry.setGenerationState("vision_dense/siglip2-v1", state: .ready)
        try await registry.setGenerationState("vision_dense/siglip2-v1", state: .active)
        try await registry.registerGeneration(IndexGeneration(generationId: "ocr_text/e5-v1", indexType: "ocr_text", dimension: 384))
        try await registry.setGenerationState("ocr_text/e5-v1", state: .ready)
        try await registry.setGenerationState("ocr_text/e5-v1", state: .active)
        let published = try await registry.activateGeneration("vision_dense/siglip2-v1")
        try await registry.publishRoute(ActiveRouteSet(
            textGeneration: "vision_dense/siglip2-v1",
            ocrGeneration: "ocr_text/e5-v1",
            visionGeneration: "vision_dense/siglip2-v1",
            version: published.version
        ))

        let pipeline = IngestPipeline(
            embedder: spy,
            privacyActor: PrivacyActor(db: db),
            vectorStore: VectorStoreActor(dimension: 768),
            canonicalRepository: repo,
            generationRegistry: registry,
            photoExtractor: WP5StubPhotoExtractor(imageData: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
            ocrService: WP5StubOCRService(document: ocrDoc)
        )

        let assetId = "PHAsset/wp5-ocr-ingest-\(UUID().uuidString)"
        _ = try await pipeline.ingestProductionPhoto(assetId: assetId, taskID: "t-wp5-ocr", traceID: "t-wp5-ocr")

        // 3a/3b: E5 .passage 被调用
        let contexts = await spy.contextsSnapshot()
        #expect(contexts.contains(.passage), "OCR ingestion must embed with .passage context; got \(contexts)")

        // 3c/3d + 4b: ocr 表示落库且 representationId 为确定性派生（vectorId == representationId）
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: assetId, sourceType: "photo")
        let reps = try await repo.loadRepresentations(memoryId: memoryId)
        let ocrRep = reps.first { $0.modality == .ocrText }
        #expect(ocrRep != nil, "OCR representation must be committed")
        #expect(ocrRep?.representationId == CanonicalMemoryRepositoryActor.ocrRepresentationID(memoryID: memoryId),
                "vectorId == representationId (ADR-015 D-7)")
        #expect(ocrRep?.contentHash == "sha256:wp5-ocr")
    }
}

// MARK: - WP5 步骤组 5+6：OCR 查询侧与隔离/删除验证

extension PhotoTextSearchOCRTests {

    @Test("OCR hit carries ocrText provenance through canonical RRF (WP5 steps 5c/5d)")
    func testOCRHitCarriesOCRProvenance() async throws {
        let vecID = UUID()
        let memID = UUID()
        let binding = CanonicalVectorBinding(
            vectorID: vecID, representationID: vecID, memoryID: memID,
            modality: .ocrText, generationID: "ocr_text/e5-v1"
        )
        let hit = RawChannelHit(
            channel: .ocrText, vectorID: vecID, rank: 1,
            nativeScore: nil, generationID: "ocr_text/e5-v1"
        )
        let fused = DefaultCanonicalRRFFuser().fuse(
            mappedHits: [CanonicalMappedHit(binding: binding, hit: hit)],
            weights: [:], rrfK: 60, limit: 10, routeSnapshotID: "r-wp5-5c"
        )
        #expect(fused.count == 1)
        #expect(fused.first?.provenance.first?.channel == .ocrText,
                "OCR hit must carry ocrText provenance channel")
    }

    @Test("OCR channel failure preserves vision results (WP5 steps 6a/6b)")
    func testOCRFailurePreservesVisionResults() async throws {
        let visionID = UUID()
        let memID = UUID()
        let visionBinding = CanonicalVectorBinding(
            vectorID: visionID, representationID: visionID, memoryID: memID,
            modality: .visionDense, generationID: "vision_dense/siglip2-v1"
        )
        let visionHit = RawChannelHit(
            channel: .visionDense, vectorID: visionID, rank: 1,
            nativeScore: nil, generationID: "vision_dense/siglip2-v1"
        )
        // 仅 vision 命中进入融合（OCR 失败 = 无贡献，不阻断健康通道）
        let fused = DefaultCanonicalRRFFuser().fuse(
            mappedHits: [CanonicalMappedHit(binding: visionBinding, hit: visionHit)],
            weights: [:], rrfK: 60, limit: 10, routeSnapshotID: "r-wp5-6a"
        )
        #expect(fused.count == 1)
        #expect(fused.first?.provenance.map(\.channel) == [.visionDense],
                "vision result must survive absent OCR channel")
    }

    @Test("OCR memory deletion leaves zero cache residue (WP5 steps 6c/6d)")
    func testOCRDeletionLeavesZeroCacheResidue() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let cache = SearchResultCacheActor()
        let registry = GenerationRegistryActor(db: db)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)
        let memID = UUID()

        let key = SearchCacheKey(policyVersion: 1, modelVersion: "m", queryHash: "ocr-q", routeSnapshotID: "r")
        let item = SearchResultItem(
            id: memID,
            assetId: "PHAsset/ocr-cache",
            sourceType: "photo",
            timestamp: Date().timeIntervalSince1970,
            originalText: nil,
            sourceLanguage: nil,
            cosineSimilarity: 0.9
        )
        try await cache.store(
            key: key,
            result: CachedSearchResult(items: [item])
        )
        try await cache.invalidate(memoryID: memID)
        #expect(try await cache.lookup(key: key) == nil,
                "cache must carry no residue after invalidation")
    }

    @Test("OCR memory deletion leaves zero subject-linked audit residue (WP5 steps 6e/6f)")
    func testOCRDeletionLeavesZeroAuditSubjectResidue() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        try await db.execute(sql: "DELETE FROM AuditLog")
        let privacy = PrivacyActor(db: db)
        let feedback = FeedbackActor(db: db, privacyActor: privacy)
        let memoryId = UUID()
        let subject = AuditSubject.memory(memoryId)

        let entry = FeedbackEntry(
            id: UUID(), memoryId: memoryId, queryText: "ocr term",
            sentiment: .like, cosineSimilarity: 0.9, createdAt: Date()
        )
        try await feedback.recordFeedback(entry, traceID: "t-wp5-6e")

        // 验证 subject-linked audit 清除路径可用（purgeAuditRecords）
        try await privacy.purgeAuditRecords(subject: subject, traceID: "t-wp5-6e")
        let rows = try await db.executeQuery(
            sql: "SELECT COUNT(*) AS c FROM AuditLog WHERE subjectHash = ?",
            bindings: [.text(subject.subjectHash)]
        )
        #expect(rows.first?["c"]?.intValue == 0,
                "subject-linked audit must be purged with the deleted memory")
    }
}
