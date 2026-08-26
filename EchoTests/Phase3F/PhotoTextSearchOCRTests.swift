// ==========================================
// 文件: PhotoTextSearchOCRTests.swift
// 对应规格: 交接计划 §WP5 步骤组 1（fixture 许可/哈希契约 + OCRDocument 值契约）
// 任务: WP5 - OCR 辅助通道
// 生成时间: 2026-08-25
// ==========================================

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
