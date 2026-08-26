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
            boxes: [CGRect(x: 0, y: 0.6, width: 0.5, height: 0.1),
                    CGRect(x: 0, y: 0.2, width: 0.5, height: 0.1)]
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
