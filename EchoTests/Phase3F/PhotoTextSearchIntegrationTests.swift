// ==========================================
// 文件: PhotoTextSearchIntegrationTests.swift
// 对应规格: 自然语言照片检索交接计划 §7.3/§7.4/§7.6（WP4 步骤 0a-0b 起步切片）
// 任务: WP4 - 生产多通道查询与规范 RRF 接线（值契约 nonisolated 表测试起步）
// 架构约束: SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor 下值契约显式 nonisolated；
//           类型形状严格遵循交接计划 §7.3/§7.4/§7.6
// 生成时间: 2026-08-25
// ==========================================

import Foundation
import Testing

@testable import Echo

/// WP4 生产多通道查询集成测试。
@Suite("PhotoTextSearchIntegration")
struct PhotoTextSearchIntegrationTests {

    // MARK: - WP4 Step 0a/0b: 十二值契约 nonisolated 表测试

    /// 表驱动遍历十二个 WP4 值契约类型的实例化冒烟。
    @Test("WP4 value contracts are nonisolated and constructible")
    func testWP4ValueContractsAreNonisolated() throws {
        // 1. SearchChannel（§7.3，自 SearchRouteSnapshot.swift 迁入）
        let channel: SearchChannel = .textDense

        // 2. DenseQueryVector (§7.3, throwing init)
        let dense = try DenseQueryVector(
            values: [Float](repeating: 0.25, count: 384),
            dimension: 384,
            modelManifestID: "multilingual-e5-small",
            alignmentSpaceID: "aligned-e5-v1"
        )
        #expect(dense.dimension == 384)

        // 3. ChannelQueryPayload (§7.3)
        let densePayload: ChannelQueryPayload = .dense(dense)
        let lexicalPayload: ChannelQueryPayload = .lexical(text: "red flower", locale: "en-US")
        if case .lexical(let text, let locale) = lexicalPayload {
            #expect(text == "red flower" && locale == "en-US")
        } else {
            Issue.record("expected lexical")
        }
        if case .dense(let v) = densePayload {
            #expect(v.dimension == 384)
        } else {
            Issue.record("expected dense")
        }

        // 4. MultiChannelQuery (§7.3)
        let query = MultiChannelQuery(
            queryHash: "hash-1",
            locale: "en-US",
            payloads: [.textDense: densePayload],
            routeSnapshotID: "snapshot-1",
            traceID: "trace-wp4"
        )
        guard case .dense(let embedded) = query.payloads[.textDense] else {
            Issue.record("expected dense payload for text channel")
            return
        }
        #expect(embedded.dimension == 384)

        // 5. ChannelFailure (§7.4)
        let failure = ChannelFailure(channel: .visionDense, code: "modelUnavailable",
                                     level: "L3", retryable: false)
        #expect(failure.retryable == false)

        // 6. QueryRepresentationOutcome (§7.3)
        let repOutcome = QueryRepresentationOutcome(
            query: query,
            failures: [.visionDense: failure]
        )
        #expect(repOutcome.failures[.visionDense] != nil)

        // 7. RawChannelHit (§7.4)
        let vectorID = UUID()
        let hit = RawChannelHit(
            channel: .textDense,
            vectorID: vectorID,
            rank: 1,
            nativeScore: 0.92,
            generationID: "text_dense/e5-v1"
        )
        #expect(hit.rank == 1)

        // 8. ChannelSkipReason (§7.4)
        let skip: ChannelSkipReason = .indexEmpty
        #expect(skip == .indexEmpty)

        // 9. ChannelSearchOutcome (§7.4)
        let outcome: ChannelSearchOutcome = .success(channel: .textDense, hits: [hit], elapsedMs: 5)
        if case .success(_, let hits, _) = outcome {
            #expect(hits.count == 1)
        } else {
            Issue.record("expected success")
        }
        let timedOut: ChannelSearchOutcome = .timedOut(channel: .visionDense, partialHits: [], elapsedMs: 1500)
        if case .timedOut(_, let partial, _) = timedOut {
            #expect(partial.isEmpty)
        } else {
            Issue.record("expected timedOut")
        }

        // 10. ChannelRankProvenance (§7.6)
        let provenance = ChannelRankProvenance(
            channel: .textDense,
            rank: 1,
            generationID: "text_dense/e5-v1",
            vectorID: vectorID,
            nativeScore: 0.92
        )
        #expect(provenance.vectorID == vectorID)

        // 11. CanonicalMappedHit (§7.6; CanonicalVectorBinding 来自 WP3 §7.5)
        let binding = CanonicalVectorBinding(
            vectorID: vectorID,
            representationID: vectorID,
            memoryID: UUID(),
            modality: .textDense,
            generationID: "text_dense/e5-v1"
        )
        let mappedHit = CanonicalMappedHit(binding: binding, hit: hit)
        #expect(mappedHit.binding.memoryID == binding.memoryID)

        // 12. FusedSearchResult (§7.6; Memory 为既有 canonical 类型)
        let memory = Memory(
            memoryId: binding.memoryID,
            sourceLocator: "PHAsset/wp4-fused",
            canonicalText: nil,
            sourceType: "photo"
        )
        let fused = FusedSearchResult(
            memory: memory,
            rrfScore: 0.0331,
            provenance: [provenance],
            routeSnapshotID: "snapshot-1"
        )
        #expect(fused.rrfScore > 0)
        #expect(fused.routeSnapshotID == "snapshot-1")
        _ = skip
        _ = channel
    }
}

// MARK: - WP4 Steps 1a-1j: QueryRepresentationFactory 四通道载荷生成

/// E5 spy——记录每次 embed 收到的上下文。
private actor ContextRecordingE5: ContextualTextEmbedder {
    nonisolated let modelManifestID = "stub-e5"
    nonisolated let dimension = 384
    private(set) var recordedContexts: [TextEmbeddingContext] = []

    func embed(text: String, context: TextEmbeddingContext, traceID: String) async throws -> [Float] {
        recordedContexts.append(context)
        return [Float](repeating: 0.25, count: 384)
    }
}

/// SigLIP2 文本塔 stub——固定 768d 单位向量。
private struct StubVisionEmbedder: VisionTextEmbedder {
    nonisolated let modelManifestID = "stub-siglip2-text"
    nonisolated let alignmentSpaceID = "aligned-siglip2-v1"
    nonisolated let dimension = 768

    func embedVisionQuery(text: String, locale: String, traceID: String) async throws -> [Float] {
        [Float](repeating: 1.0 / sqrt(768), count: 768)
    }
}

extension PhotoTextSearchIntegrationTests {

    private func fourChannelRoute() throws -> SearchRouteSnapshot {
        let policy = try FusionPolicySnapshot(
            policyID: "p-wp4",
            weights: [
                ChannelWeight(channel: .textDense, weight: 1.0),
                ChannelWeight(channel: .visionDense, weight: 0.8),
                ChannelWeight(channel: .ocrText, weight: 0.6),
                ChannelWeight(channel: .lexical, weight: 0.4),
            ],
            rrfK: 60
        )
        func route(_ ch: SearchChannel, dim: Int?) -> ChannelRoute {
            ChannelRoute(channel: ch, generationID: ch.rawValue + "/gen", indexManifestID: nil,
                         queryModelManifestID: nil, dimension: dim, alignmentSpaceID: nil, required: true)
        }
        return try SearchRouteSnapshot(
            snapshotID: "wp4-route", schemaVersion: 1, routeVersion: 1,
            channels: [
                route(.textDense, dim: 384), route(.visionDense, dim: 768),
                route(.ocrText, dim: 384), route(.lexical, dim: nil),
            ],
            fusion: policy, previousSnapshotID: nil,
            publishedAtEpochMilliseconds: 42, validationDigest: "ignored"
        )
    }

    @Test("Factory builds text-dense E5 query payload (WP4 step 1a)")
    func testQueryFactoryBuildsTextDenseE5Payload() async throws {
        let e5 = ContextRecordingE5()
        let factory = DefaultQueryRepresentationFactory(textEmbedder: e5, visionEmbedder: StubVisionEmbedder())
        let route = try fourChannelRoute()
        let outcome = await factory.makeQuery(text: "red flower", locale: "en-US", route: route, traceID: "t-1a")
        guard case .dense(let dv)? = outcome.query.payloads[.textDense] else {
            Issue.record("expected dense payload for textDense")
            return
        }
        #expect(dv.dimension == 384)
        #expect(dv.modelManifestID == "stub-e5")
    }

    @Test("Factory builds vision-dense SigLIP2 payload (WP4 step 1c)")
    func testQueryFactoryBuildsVisionDenseSigLIPPayload() async throws {
        let factory = DefaultQueryRepresentationFactory(
            textEmbedder: ContextRecordingE5(), visionEmbedder: StubVisionEmbedder()
        )
        let route = try fourChannelRoute()
        let outcome = await factory.makeQuery(text: "red flower", locale: "en-US", route: route, traceID: "t-1c")
        guard case .dense(let dv)? = outcome.query.payloads[.visionDense] else {
            Issue.record("expected dense payload for visionDense")
            return
        }
        #expect(dv.dimension == 768)
        #expect(dv.alignmentSpaceID == "aligned-siglip2-v1")
    }

    @Test("Factory builds OCR query payload via E5 query context (WP4 step 1e)")
    func testQueryFactoryBuildsOCRQueryPayload() async throws {
        let e5 = ContextRecordingE5()
        let factory = DefaultQueryRepresentationFactory(textEmbedder: e5, visionEmbedder: StubVisionEmbedder())
        let route = try fourChannelRoute()
        let outcome = await factory.makeQuery(text: "receipt total", locale: "en-US", route: route, traceID: "t-1e")
        guard case .dense(let dv)? = outcome.query.payloads[.ocrText] else {
            Issue.record("expected dense payload for ocrText")
            return
        }
        #expect(dv.dimension == 384)
        let contexts = await e5.recordedContexts
        #expect(contexts.allSatisfy { $0 == .query })
    }

    @Test("Lexical payload preserves query text (WP4 step 1g)")
    func testLexicalPayloadPreservesQueryText() async throws {
        let factory = DefaultQueryRepresentationFactory(
            textEmbedder: ContextRecordingE5(), visionEmbedder: StubVisionEmbedder()
        )
        let route = try fourChannelRoute()
        let outcome = await factory.makeQuery(text: "红色的花", locale: "zh-Hans", route: route, traceID: "t-1g")
        guard case .lexical(let text, _)? = outcome.query.payloads[.lexical] else {
            Issue.record("expected lexical payload")
            return
        }
        #expect(text == "红色的花")
    }

    @Test("Lexical payload preserves locale (WP4 step 1i)")
    func testLexicalPayloadPreservesLocale() async throws {
        let factory = DefaultQueryRepresentationFactory(
            textEmbedder: ContextRecordingE5(), visionEmbedder: StubVisionEmbedder()
        )
        let route = try fourChannelRoute()
        let outcome = await factory.makeQuery(text: "red flower", locale: "zh-Hans", route: route, traceID: "t-1i")
        #expect(outcome.query.locale == "zh-Hans")
    }
}
