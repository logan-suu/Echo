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
