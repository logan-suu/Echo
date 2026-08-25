// ==========================================
// 文件: PhotoTextSearchContractsTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RET-003 / US-ING-004
// 任务: 自然语言照片检索交接计划 WP0 - 规格与 ADR 事实统一
// AC 覆盖: WP0 步骤 1a-1j (ADR 必需条款), 步骤 3a-3c (规格 CLIP-space 残留清除 + 能力禁用守卫)
// 架构约束: 遵循交接计划 §7 (SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor 下显式 nonisolated 惯例);
//           本套件为文档契约测试——断言 ADR/规格文本包含必需条款标记, 不触碰生产代码。
// 生成时间: 2026-08-25
// ==========================================

import Foundation
import Testing

@testable import Echo

/// WP0 文档契约测试。
///
/// 每个测试断言一份治理文档包含（或不包含）精确条款标记。
/// 标记字符串即条款的唯一机器可读锚点；修改文档时必须同步保留这些标记。
@Suite("PhotoTextSearchContracts")
struct PhotoTextSearchContractsTests {

    // MARK: - Fixtures

    /// 从测试文件路径推导仓库根目录（EchoTests/Phase3F → repo root 上三级）。
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // EchoTests/Phase3F
        .deletingLastPathComponent()   // EchoTests
        .deletingLastPathComponent()   // repo root

    private static let adrPath = "docs/decisions/ADR-015-photo-text-retrieval.md"
    private static let specPath = "docs/01-spec/用户故事与验收标准规格书.md"

    private static func readDoc(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - WP0 Step 1: ADR-015 必需条款

    @Test("ADR-015 requires native per-channel query representations")
    func testADRRequiresNativePerChannelQueries() throws {
        let adr = try Self.readDoc(Self.adrPath)
        #expect(adr.contains("native-per-channel-queries"))
    }

    @Test("ADR-015 requires canonical-ID fusion before RRF")
    func testADRRequiresCanonicalIDFusion() throws {
        let adr = try Self.readDoc(Self.adrPath)
        #expect(adr.contains("canonical-id-fusion-before-rrf"))
    }

    @Test("ADR-015 requires complete route snapshot rollback")
    func testADRRequiresCompleteRouteRollback() throws {
        let adr = try Self.readDoc(Self.adrPath)
        #expect(adr.contains("complete-route-snapshot-rollback"))
    }

    @Test("ADR-015 forbids reusing current vision vectors and mandates corrected reindex")
    func testADRRequiresCorrectedVisionReindex() throws {
        let adr = try Self.readDoc(Self.adrPath)
        #expect(adr.contains("corrected-vision-graph-mandatory-reindex"))
    }

    @Test("ADR-015 requires offline-only model artifacts")
    func testADRRequiresOfflineOnlyArtifacts() throws {
        let adr = try Self.readDoc(Self.adrPath)
        #expect(adr.contains("offline-only-model-artifacts"))
    }

    // MARK: - WP0 Step 3a/3b: 规格 CLIP-space 残留清除

    /// 活跃规格不得再要求「无配对文本塔的 CLIP-space 查询」。
    /// 两条陈旧 AC 正文（原 L415 / L490）与其自身修订横幅自相矛盾，必须移除。
    @Test("Active spec no longer requires unpaired CLIP-space queries")
    func testSpecRemovesUnpairedCLIPQueryRequirement() throws {
        let spec = try Self.readDoc(Self.specPath)
        #expect(!spec.contains("图片生成 CLIP 向量，与文本向量空间对齐"))
        #expect(!spec.contains("混合查询向量仍位于 CLIP 空间"))
    }

    // MARK: - WP0 Step 3c: 能力禁用守卫 (GREEN regression)

    /// 在 WP7 发布门禁全部通过之前，能力文案与路由必须保持禁用。
    @Test("Capability remains disabled before WP7")
    func testCapabilityRemainsDisabledBeforeWP7() throws {
        let adr = try Self.readDoc(Self.adrPath)
        #expect(adr.contains("capability-disabled-until-release-gates"))
    }
}

// MARK: - WP1 Step 1a/1b: 生产搜索显式 E5 query 上下文

/// 记录每次 embedText 收到的上下文；用于断言生产调用点显式传参。
private actor ContextRecordingEmbedder: EmbedderProtocol {
    private(set) var recordedContexts: [TextEmbeddingContext] = []
    private(set) var legacyCallCount = 0

    func embedImage(assetId: String) async throws -> [Float] {
        throw EmbedderError.preprocessingFailed(reason: "spy: image unsupported")
    }

    func embedImageData(_ data: Data) async throws -> [Float] {
        throw EmbedderError.preprocessingFailed(reason: "spy: image data unsupported")
    }

    func embedText(_ text: String) async throws -> [Float] {
        legacyCallCount += 1
        return [Float](repeating: 1.0 / sqrt(384), count: 384)
    }

    func embedText(_ text: String, context: TextEmbeddingContext) async throws -> [Float] {
        recordedContexts.append(context)
        return [Float](repeating: 1.0 / sqrt(384), count: 384)
    }
}

extension PhotoTextSearchContractsTests {

    /// WP1 步骤 2c/2d：TextEmbeddingContext 必须显式 nonisolated。
    /// 实现于步骤 1（创建即 nonisolated），本测试为回归守卫（GREEN regression）。
    @Test("TextEmbeddingContext declaration is explicitly nonisolated (WP1 step 2c)")
    func testTextEmbeddingContextIsNonisolated() throws {
        let source = try Self.readDoc("Echo/Core/Services/TextEmbedding.swift")
        #expect(source.contains("public nonisolated enum TextEmbeddingContext"))
    }


// MARK: - WP1 Step 2a: ContextualTextEmbedder conformance

/// Actor 测试替身——验证协议可被 actor 无 MainActor 跳跃地 conform。
private actor DummyContextualEmbedder: ContextualTextEmbedder {
    nonisolated let modelManifestID = "test-e5-dummy"
    nonisolated let dimension = 384

    func embed(text: String, context: TextEmbeddingContext, traceID: String) async throws -> [Float] {
        [Float](repeating: 1.0 / sqrt(384), count: 384)
    }
}

@Test("Contextual embedder conformance without MainActor hop (WP1 step 2a)")
func testContextualTextEmbedderConformanceWithoutMainActorHop() async throws {
    let dummy = DummyContextualEmbedder()
    let vector = try await dummy.embed(text: "red flower", context: .query, traceID: "t-2a")
    #expect(vector.count == 384)
    #expect(await dummy.modelManifestID == "test-e5-dummy")
}

@Test("Production search requests E5 query context (WP1 step 1a)")
func testSearchUsesE5QueryContext() async throws {
    let spy = ContextRecordingEmbedder()
    let pipeline = SearchPipeline(
        embedder: spy,
        vectorStore: VectorStoreActor(dimension: 384)
    )
    _ = try await pipeline.search(query: "red flower", k: 1)
    let contexts = await spy.recordedContexts
    let legacyCalls = await spy.legacyCallCount
    #expect(contexts == [.query])
    #expect(legacyCalls == 0)
}
}
