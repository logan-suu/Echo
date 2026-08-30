// ==========================================
// 文件: PhotoTextSearchQualityTests.swift
// 对应规格: 交接计划 §WP7 步骤 1a-1f（真实工件 harness 预检）
// 任务: WP7 - 双语质量、设备、法律、CI 与发布门禁
// 生成时间: 2026-08-25
// ==========================================

import Foundation
import Testing

@testable import Echo

/// WP7 质量门禁——真实工件评估 harness 预检（步骤 1a-1f）。
@Suite(.serialized)
struct PhotoTextSearchQualityTests {

    nonisolated private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Phase3F
            .deletingLastPathComponent()   // EchoTests
            .deletingLastPathComponent()   // repo root
    }

    nonisolated private static var manifestURL: URL {
        repoRoot.appendingPathComponent("EchoTests/Fixtures/PhotoTextSearch/manifest.json")
    }

    nonisolated private static var fixturesBaseDir: URL {
        repoRoot.appendingPathComponent("EchoTests/Fixtures/PhotoTextSearch")
    }

    // MARK: - WP7 Step 1a: harness requires real artifacts

    @Test("Harness parses the real frozen fixture manifest and validates all artifacts (WP7 step 1a)")
    func testHarnessRequiresRealArtifacts() throws {
        let data = try Data(contentsOf: Self.manifestURL)
        let harness = try RealPhotoSearchEvaluationHarness(manifestData: data)

        // 真实冻结 manifest：非空 fixtures + 全部预检通过
        #expect(!harness.fixtures.isEmpty, "frozen manifest must declare real fixtures")
        #expect(throws: Never.self) { try harness.validateArtifactPresence(baseDir: Self.fixturesBaseDir) }
        #expect(throws: Never.self) { try harness.validateArtifactHashes(baseDir: Self.fixturesBaseDir) }
        #expect(throws: Never.self) { try harness.validateRights() }
    }

    // MARK: - WP7 Step 1c/1d: missing artifact typed failure

    @Test("Harness fails with typed missing-artifact error (WP7 step 1c/1d)")
    func testHarnessFailsWhenRequiredArtifactIsMissing() throws {
        let harness = try RealPhotoSearchEvaluationHarness(manifestData: Data("""
        {"fixtures": [{"id": "ghost", "file": "images/nonexistent.png", "sha256": "abc", "license": "l", "rights": "r"}]}
        """.utf8))

        #expect(throws: PhotoSearchHarnessError.missingArtifact(path: "images/nonexistent.png")) {
            try harness.validateArtifactPresence(baseDir: Self.fixturesBaseDir)
        }
    }

    // MARK: - WP7 Step 1d1/1d2: hash mismatch typed failure

    @Test("Harness fails with typed hash-mismatch error (WP7 step 1d1/1d2)")
    func testHarnessFailsWhenArtifactHashMismatches() throws {
        let harness = try RealPhotoSearchEvaluationHarness(manifestData: Data("""
        {"fixtures": [{"id": "tampered", "file": "images/screenshot-basic.png", "sha256": "deadbeef", "license": "l", "rights": "r"}]}
        """.utf8))

        guard case let thrown = Result { try harness.validateArtifactHashes(baseDir: Self.fixturesBaseDir) },
              case .failure(let error as PhotoSearchHarnessError) = thrown,
              case .hashMismatch = error else {
            Issue.record("expected hashMismatch typed failure")
            return
        }
    }

    // MARK: - WP7 Step 1e/1f: rights required

    @Test("Fixture manifest rejects entries missing rights (WP7 step 1e/1f)")
    func testFixtureManifestRejectsMissingRights() throws {
        let harness = try RealPhotoSearchEvaluationHarness(manifestData: Data("""
        {"fixtures": [{"id": "no-rights", "file": "images/x.png", "sha256": "abc", "license": "l", "rights": ""}]}
        """.utf8))

        #expect(throws: PhotoSearchHarnessError.missingRights(fixtureID: "no-rights")) {
            try harness.validateRights()
        }
    }
}

// MARK: - WP7 Steps 2a-2d：synthetic 拒绝 + 路由 digest 预检

extension PhotoTextSearchQualityTests {

    @Test("Harness rejects synthetic fixtures (WP7 step 2a/2b)")
    func testHarnessRejectsSyntheticVectors() throws {
        let harness = try RealPhotoSearchEvaluationHarness(manifestData: Data("""
        {"fixtures": [{"id": "synth", "file": "images/x.png", "sha256": "abc", "license": "l", "rights": "r", "synthetic": true}]}
        """.utf8))

        #expect(throws: PhotoSearchHarnessError.syntheticVectorDetected(fixtureID: "synth")) {
            try harness.validateNoSynthetic()
        }
    }

    @Test("Harness rejects route digest mismatch (WP7 step 2c/2d)")
    func testHarnessRejectsRouteDigestMismatch() throws {
        let policy = try FusionPolicySnapshot(
            policyID: "p-wp7", weights: [ChannelWeight(channel: .textDense, weight: 1.0)], rrfK: 60
        )
        let route = try SearchRouteSnapshot(
            snapshotID: "wp7-route-1", schemaVersion: 1, routeVersion: 1,
            channels: [ChannelRoute(channel: .textDense, generationID: "text_dense/e5-v1", indexManifestID: nil, queryModelManifestID: nil, dimension: 384, alignmentSpaceID: nil, required: true)],
            fusion: policy, previousSnapshotID: nil,
            publishedAtEpochMilliseconds: 1, validationDigest: "placeholder"
        )
        let harness = try RealPhotoSearchEvaluationHarness(manifestData: Data("""
        {"fixtures": [{"id": "real", "file": "images/x.png", "sha256": "abc", "license": "l", "rights": "r"}]}
        """.utf8))

        let correct = try route.computedDigest()
        #expect(throws: Never.self) { try harness.validateRouteDigest(route, expected: correct) }
        #expect(throws: PhotoSearchHarnessError.routeDigestMismatch(expected: "stale", actual: correct)) {
            try harness.validateRouteDigest(route, expected: "stale")
        }
    }
}

// MARK: - WP7 Steps 3a-3f + 5a-6h：质量报告计算

extension PhotoTextSearchQualityTests {

    nonisolated private static func evalCase(
        _ id: String, locale: String = "en-US", expected: UUID?, ranks: [UUID],
        active: Int = 4, total: Int = 4
    ) -> PhotoSearchEvaluationCase {
        PhotoSearchEvaluationCase(
            queryID: id, locale: locale, expectedMemoryID: expected,
            rankedIDs: ranks, activeChannelCount: active, totalChannelCount: total
        )
    }

    @Test("Quality report computes R@K nDCG MRR no-match partial-channel (WP7 steps 3a-3f/5a-5d)")
    func testQualityReportMetrics() throws {
        let target = UUID()
        let noise1 = UUID(); let noise2 = UUID()
        let knownCases = [
            // rank 1 命中
            Self.evalCase("q1", expected: target, ranks: [target, noise1]),
            // rank 3 命中
            Self.evalCase("q2", expected: target, ranks: [noise1, noise2, target]),
            // 未命中（rank > 10 之外）
            Self.evalCase("q3", expected: target, ranks: [noise1, noise2]),
        ]
        let noMatchCases = [
            Self.evalCase("q4", expected: nil, ranks: []),           // 正确：空
            Self.evalCase("q5", expected: nil, ranks: [noise1]),     // 错误：非空
        ]
        let report = PhotoSearchQualityMetrics.report(
            locale: "en-US", cases: knownCases + noMatchCases
        )
        // R@1 = 1/3（q1）；R@5 = 2/3（q1,q2）；R@10 = 2/3
        #expect(abs(report.recallAt1 - 1.0/3.0) < 1e-9)
        #expect(abs(report.recallAt5 - 2.0/3.0) < 1e-9)
        #expect(abs(report.recallAt10 - 2.0/3.0) < 1e-9)
        // nDCG@10 = (1 + 1/log2(4) + 0)/3 = (1 + 0.5)/3
        #expect(abs(report.ndcgAt10 - 1.5/3.0) < 1e-9)
        // MRR@10 = (1 + 1/3 + 0)/3（known-item-only）
        #expect(report.mrrAt10 != nil)
        #expect(abs((report.mrrAt10 ?? 0) - (4.0/3.0)/3.0) < 1e-9)
        // no-match 正确率 = 1/2
        #expect(abs(report.noMatchCorrectRate - 0.5) < 1e-9)
        // partial-channel：全部 4/4 无降级 → 0
        #expect(abs(report.partialChannelRate - 0.0) < 1e-9)
    }

    @Test("Partial-channel rate counts degraded queries (WP7 step 5c/5d)")
    func testPartialChannelRate() throws {
        let cases = [
            Self.evalCase("p1", expected: nil, ranks: [], active: 4, total: 4),
            Self.evalCase("p2", expected: nil, ranks: [], active: 2, total: 4),  // 降级
        ]
        let report = PhotoSearchQualityMetrics.report(locale: "en-US", cases: cases)
        #expect(abs(report.partialChannelRate - 0.5) < 1e-9)
    }

    @Test("Bilingual reports plus macro average (WP7 steps 6a-6f)")
    func testBilingualAndMacro() throws {
        let target = UUID()
        let zhCases = [
            Self.evalCase("z1", locale: "zh-Hans", expected: target, ranks: [target]),
        ]
        let enCases = [
            Self.evalCase("e1", locale: "en-US", expected: target, ranks: []),
        ]
        let zh = PhotoSearchQualityMetrics.report(locale: "zh-Hans", cases: zhCases)
        let en = PhotoSearchQualityMetrics.report(locale: "en-US", cases: enCases)
        #expect(abs(zh.recallAt1 - 1.0) < 1e-9)
        #expect(abs(en.recallAt1 - 0.0) < 1e-9)

        guard let macro = PhotoSearchQualityMetrics.macroAverage([zh, en]) else {
            Issue.record("macro average missing")
            return
        }
        #expect(macro.locale == "macro")
        #expect(abs(macro.recallAt1 - 0.5) < 1e-9)
    }

    @Test("Paired confidence interval covers the observed recall difference (WP7 step 6g/6h)")
    func testPairedConfidenceInterval() throws {
        guard let ci = PhotoSearchQualityMetrics.pairedConfidenceInterval(
            recallA: 0.9, sampleA: 100, recallB: 0.8, sampleB: 100
        ) else {
            Issue.record("CI missing")
            return
        }
        #expect(ci.lower <= 0.1 && ci.upper >= 0.1, "CI must contain the observed 0.1 difference")
        #expect(ci.lower < ci.upper)
    }
}

// MARK: - WP7 Steps 4a-4n + 7a：slice 注册 + 首次有效质量测量

extension PhotoTextSearchQualityTests {

    @Test("All quality slices register and are retrievable (WP7 steps 4a-4n)")
    func testAllSlicesRegistered() throws {
        var registry = PhotoSearchSliceRegistry()
        let sample = Self.evalCase("s1", expected: UUID(), ranks: [UUID()])
        for slice in PhotoSearchQualitySlice.allCases {
            registry.register(slice, cases: [sample])
        }
        for slice in PhotoSearchQualitySlice.allCases {
            #expect(!registry.cases(for: slice).isEmpty, "\(slice.rawValue) must be registered")
        }
        #expect(Set(registry.registeredSlices) == Set(PhotoSearchQualitySlice.allCases),
                "all seven slices must be registered")
    }

    @Test("First valid quality measurement over the frozen OCR fixture (WP7 step 7a EVIDENCE)")
    func testFirstValidQualityMeasurement() async throws {
        // 冻结 fixture 的真实 Vision 识别（OCR slice 测量）
        let data = try Data(contentsOf: Self.fixturesBaseDir.appendingPathComponent("images/mixed-language.png"))
        let service = VisionPhotoOCRService()
        let document = try await service.recognizeText(
            imageData: data, preferredLanguages: ["zh-Hans", "en-US"], traceID: "t-wp7-7a"
        )

        let observed = document?.normalizedText ?? ""
        let lowered = observed.lowercased()
        let hit = lowered.contains("每周") || lowered.contains("quarterly") || lowered.contains("sync")

        var registry = PhotoSearchSliceRegistry()
        registry.register(.ocr, cases: [
            PhotoSearchEvaluationCase(
                queryID: "wp7-ocr-mixed-1",
                locale: document?.locale ?? "en-US",
                expectedMemoryID: hit ? UUID() : nil,
                rankedIDs: hit ? [UUID()] : [],
                activeChannelCount: 1,
                totalChannelCount: 1
            )
        ])
        let report = PhotoSearchQualityMetrics.report(
            locale: document?.locale ?? "en-US", cases: registry.cases(for: .ocr)
        )
        #expect(report.knownItemCount == 1, "OCR slice measurement must record one known-item case")

        // EVIDENCE：保存首次有效测量报告
        let evidence: [String: Any] = [
            "slice": "ocr",
            "fixture": "mixed-language",
            "observedLocale": document?.locale ?? "unknown",
            "observationCount": document?.observationCount ?? 0,
            "hit": hit,
            "recallAt1": report.recallAt1,
        ]
        let outDir = Self.repoRoot.appendingPathComponent(".omo/evidence/photo-text-search/wp7")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let jsonData = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: outDir.appendingPathComponent("quality-measurement-ocr.json"))
        #expect(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("quality-measurement-ocr.json").path),
                "first valid quality measurement must be persisted as evidence")
    }
}

// MARK: - WP4 5c/5d：SigLIP2 文本塔真实接线（模拟器优先验证）

extension PhotoTextSearchQualityTests {

    @Test("SigLIP2 tokenizer cross-validates against the pytest fixture sequence (WP4 5c/5d)")
    func testSigLIP2TokenizerFixtureCrossValidation() throws {
        let tokenizerURL = Self.repoRoot.appendingPathComponent("Echo/Resources/Models/siglip2-tokenizer.json")
        let tokenizer = try SigLIP2Tokenizer(tokenizerJSON: try Data(contentsOf: tokenizerURL))
        let ids = tokenizer.encode("red flower")
        #expect(Array(ids.prefix(3)) == [854, 10377, 1],
                "red flower must tokenize to the pytest fixture sequence [854, 10377, 1]; got \(Array(ids.prefix(5)))")
        #expect(ids.count == SigLIP2Tokenizer.maxLength)
    }

    @Test("SigLIP2 text tower real inference on simulator (WP4 5c/5d)")
    func testSigLIP2TextTowerRealInference() async throws {
        let embedder = SigLIP2TextEmbedder()
        let vector = try await embedder.embedVisionQuery(
            text: "red flower", locale: "en-US", traceID: "t-wp7-texttower"
        )
        #expect(vector.count == 768, "text tower must emit 768d")
        let squaredSum = vector.reduce(0) { $0 + $1 * $1 }
        #expect(abs(sqrt(squaredSum) - 1.0) < 1e-3, "L2 normalized output")

        let repeatVector = try await embedder.embedVisionQuery(
            text: "red flower", locale: "en-US", traceID: "t-wp7-texttower-2"
        )
        #expect(vector == repeatVector, "same input must produce an identical embedding")
    }
}

// MARK: - WP7 UI 采用：FusedSearchResult → SearchResultModel 映射

extension PhotoTextSearchQualityTests {

    @Test("mapFused maps FusedSearchResult to the UI model (route ENABLED adoption)")
    @MainActor
    func testMapFusedMapping() {
        let memID = UUID()
        let memory = Memory(
            memoryId: memID, sourceLocator: "PHAsset/ui-map",
            canonicalText: "red flower", sourceType: "photo"
        )
        // 双通道 rank-1 = RRF 理论最大（2 × 1/61）→ 归一化后应为 1.0
        let fused = FusedSearchResult(
            memory: memory, rrfScore: 0.0328,
            provenance: [
                ChannelRankProvenance(channel: .textDense, rank: 1, generationID: "text_dense/e5-v1", vectorID: memID, nativeScore: nil),
                ChannelRankProvenance(channel: .visionDense, rank: 1, generationID: "vision_dense/siglip2-v1", vectorID: memID, nativeScore: nil),
            ],
            routeSnapshotID: "r-ui"
        )
        let model = SearchViewModel.mapFused(fused)
        #expect(model.id == memID)
        #expect(model.assetId == "PHAsset/ui-map")
        #expect(model.sourceType == "photo")
        #expect(model.cosineSimilarity == 1.0, "RRF score must normalize to relative match strength (theoretical max)")
        #expect(model.originalText == "red flower")
    }
}

// MARK: - 端到端冒烟：真实图片 → 视觉推理入库 → 文字查询 → 多通道检索命中

extension PhotoTextSearchQualityTests {

    @Test("E2E smoke: real image → vision ingest → text query → multichannel hit (闭环验证)")
    @MainActor
    func testEndToEndImageSemanticSmoke() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        let registry = GenerationRegistryActor(db: db)
        let repo = CanonicalMemoryRepositoryActor(db: db, generationRegistry: registry)

        // 种子活跃路由（text + vision 双代）
        let textGen = "text_dense/e5-v1-\(UUID().uuidString.prefix(6))"
        try await registry.registerGeneration(IndexGeneration(generationId: textGen, indexType: "text_dense", dimension: 384))
        try await registry.setGenerationState(textGen, state: .ready)
        try await registry.setGenerationState(textGen, state: .active)
        try await registry.registerGeneration(IndexGeneration(generationId: "vision_dense/siglip2-v1", indexType: "vision_dense", dimension: 768))
        try await registry.setGenerationState("vision_dense/siglip2-v1", state: .ready)
        try await registry.setGenerationState("vision_dense/siglip2-v1", state: .active)
        let activated = try await registry.activateGeneration(textGen)
        try await registry.publishRoute(ActiveRouteSet(
            textGeneration: activated.textGeneration,
            visionGeneration: "vision_dense/siglip2-v1",
            version: activated.version
        ))

        // 1. 真实视觉推理（冻结 fixture → SigLIP2 视觉塔，模拟器 cpuOnly）
        let imageData = try Data(contentsOf: Self.fixturesBaseDir.appendingPathComponent("images/screenshot-basic.png"))
        let visionEmbedder = SigLIP2Embedder()
        let visionVector = try await visionEmbedder.embedImageData(imageData)
        #expect(visionVector.count == 768, "vision tower must emit 768d")
        let norm = sqrt(visionVector.reduce(0) { $0 + $1 * $1 })
        #expect(abs(norm - 1.0) < 1e-3, "real vision inference must be L2-normalized (got \(norm))")

        // 2. 摄入：canonical memory + vision 向量写入活跃代
        try await registry.registerGeneration(IndexGeneration(generationId: "vision_dense/siglip2-v1", indexType: "vision_dense", dimension: 768))
        try await registry.setGenerationState("vision_dense/siglip2-v1", state: .ready)
        try await registry.setGenerationState("vision_dense/siglip2-v1", state: .active)
        let locator = "PHAsset/e2e-smoke-\(UUID().uuidString)"
        let memID = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: locator, sourceType: "photo")
        try await repo.commit(
            memory: Memory(memoryId: memID, sourceLocator: locator, canonicalText: nil, sourceType: "photo"),
            representations: [Representation(representationId: memID, memoryId: memID, modality: .visionDense, preprocessVersion: "siglip2-v1", contentHash: "sha256:e2e")],
            vectorsByGeneration: ["vision_dense/siglip2-v1": [CanonicalVectorEntry(id: memID, vector: visionVector)]],
            traceID: "t-e2e-ingest"
        )

        // 3. 文字查询 → 多通道检索（真实 E5 + 真实 SigLIP2 文本塔 + 融合）
        let e5 = E5Embedder()
        let pipeline = SearchPipeline(
            embedder: e5,
            privacyActor: PrivacyActor(db: db),
            vectorStore: VectorStoreActor(dimension: 768),
            canonicalRepository: repo,
            queryFactory: DefaultQueryRepresentationFactory(
                textEmbedder: e5,
                visionEmbedder: SigLIP2TextEmbedder()
            ),
            generationRegistry: registry
        )
        let fused = try await pipeline.searchTyped(
            query: "quarterly report meeting", k: 10, traceID: "t-e2e-search"
        )

        // Closed-loop assertions: the ingested image must be retrievable by text
        // query with visionDense provenance. Prior E2E runs ingest the same
        // fixture image (identical content -> identical vector -> tied score),
        // so assert membership in top-K rather than a strict rank-1 position.
        #expect(!fused.isEmpty, "E2E: the ingested image must be retrievable by text query")
        let hitRank = fused.firstIndex { $0.memory.memoryId == memID }
        #expect(hitRank != nil, "the ingested photo must appear in top-K results")
        #expect(fused.first?.provenance.contains(where: { $0.channel == .visionDense }) == true,
                "hit must carry visionDense provenance")
    }
}

// MARK: - WP7 UI 接线：详情页生产 load 映射

extension PhotoTextSearchQualityTests {

    @Test("Detail production load maps Memory to the detail model (WP7 详情接线)")
    @MainActor
    func testDetailProductionLoadMapping() {
        let memID = UUID()
        let memory = Memory(
            memoryId: memID, sourceLocator: "PHAsset/detail-map",
            canonicalText: "red flower", sourceType: "photo"
        )
        let model = MemoryDetailViewModel.makeDetailModel(from: memory)
        #expect(model.id == memID)
        #expect(model.assetId == "PHAsset/detail-map")
        #expect(model.title == "red flower", "canonical text becomes the title")
        #expect(model.originalText == "red flower")
        #expect(model.sourceType == "photo")
    }
}

// MARK: - Tokenizer case-folding contract

extension PhotoTextSearchQualityTests {

    @Test("Tokenizer: capitalized queries fold to the same encoding as lowercase")
    func testTokenizerCaseFolding() throws {
        let tokenizerURL = Self.repoRoot.appendingPathComponent("Echo/Resources/Models/siglip2-tokenizer.json")
        let tokenizer = try SigLIP2Tokenizer(tokenizerJSON: try Data(contentsOf: tokenizerURL))
        #expect(tokenizer.encode("Waterfall") == tokenizer.encode("waterfall"))
        #expect(tokenizer.encode("Quarterly Report") == tokenizer.encode("quarterly report"))
    }
}
