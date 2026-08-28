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
