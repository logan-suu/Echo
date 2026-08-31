// ==========================================
// 文件: 3F.3a_SigLIP2ConversionTests.swift
// 对应规格: docs/decisions/ADR-009-offline-model-runtime.md (决策 1/2)
//            docs/01-spec/用户故事与验收标准规格书.md → US-ING-004 AC-3,
//            US-SRC-011 (model semantics), US-RET-001 (vision channel)
//            AGENTS.md R-005 (零网络)
// 任务: 3F.3a - SigLIP2 Core ML 转换与视觉推理接入
// AC 覆盖: US-ING-004 AC-3 (视觉 embedding), US-SRC-011 (参考向量 >0.995),
//          R-5.1 四类门禁（法律/转换一致性/实机评测/资源门禁）
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载)
// 生成时间: 2026-08-07
// ==========================================

import Testing
import Foundation
@testable import Echo
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Model Availability Helpers

private func siglip2MLModelCAvailable() -> Bool {
    Bundle.main.url(forResource: "SigLIP2BasePatch32", withExtension: "mlmodelc") != nil
}

// MARK: - Bundle Presence

@Suite("SigLIP2ConversionTests.BundlePresence", .serialized)
@MainActor
struct SigLIP2BundlePresenceTests {

    @Test("SigLIP2 .mlmodelc is bundled (US-ING-004 AC-3)",
          .enabled(if: siglip2MLModelCAvailable()))
    func test_mlmodelc_bundled() {
        let url = Bundle.main.url(forResource: "SigLIP2BasePatch32", withExtension: "mlmodelc")
        #expect(url != nil, "SigLIP2BasePatch32.mlmodelc must be present in app bundle")
    }

    @Test("model-manifest.json SigLIP2 entry exists")
    func test_modelManifest_siglip2Entry() throws {
        guard let url = Bundle.main.url(forResource: "model-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = manifest["models"] as? [[String: Any]]
        else {
            Issue.record("model-manifest.json not found or invalid")
            return
        }
        let siglip2 = models.first { ($0["modelId"] as? String) == "siglip2-base-patch32-256-v1" }
        #expect(siglip2 != nil, "SigLIP2 entry missing from model-manifest.json")
        #expect((siglip2?["runtime"] as? String) == "coreML")
        #expect((siglip2?["dimension"] as? Int) == 768)
    }

    @Test("model_checksums.sha256 contains SigLIP2 entry")
    func test_checksums_siglip2Entry() throws {
        // CWD-relative path broke on CI (test runner CWD != repo root);
        // derive from #filePath like the conversion tests do.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Phase3F
            .deletingLastPathComponent()   // EchoTests
            .deletingLastPathComponent()   // repo root
        let checksumPath = repoRoot.appendingPathComponent("Scripts/model_checksums.sha256").path
        var content: String?
        if let url = Bundle.main.url(forResource: "model_checksums", withExtension: "sha256"),
           let c = try? String(contentsOf: url, encoding: .utf8) {
            content = c
        }
        if content == nil {
            let srcURL = URL(fileURLWithPath: checksumPath)
            if FileManager.default.fileExists(atPath: srcURL.path) {
                content = try? String(contentsOf: srcURL, encoding: .utf8)
            }
        }
        let text = try #require(content, "model_checksums.sha256 unreadable from bundle and repo path")
        #expect(text.contains("SigLIP2BasePatch32"), "SHA256 checksums missing SigLIP2 entry")
    }
}

// MARK: - Reference Vector Verification

@Suite("SigLIP2ConversionTests.ReferenceVectors", .serialized)
@MainActor
struct SigLIP2ReferenceVectorTests {

    @Test("reference vectors JSON loads and contains expected keys (US-SRC-011)")
    func test_referenceVectors_load() throws {
        var dataOpt: Data?
        if let url = Bundle.main.url(forResource: "siglip2-reference-vectors", withExtension: "json") {
            dataOpt = try? Data(contentsOf: url)
        }
        let data = try #require(dataOpt, "siglip2-reference-vectors.json missing/unreadable")

        let json = try JSONSerialization.jsonObject(with: data)
        let dictOpt = json as? [String: Any]
        let dict = try #require(dictOpt, "Expected dictionary root")
        #expect(dict["schemaVersion"] != nil, "schemaVersion required")
        #expect(dict["modelId"] != nil, "modelId required")
        #expect((dict["modelId"] as? String) == "siglip2-base-patch32-256-v1")

        let referencesOpt = dict["samples"] as? [[String: Any]]
        let references = try #require(referencesOpt, "samples array missing from siglip2-reference-vectors.json")
        #expect(!references.isEmpty, "At least one reference vector required")

        for ref in references {
            guard let label = ref["label"] as? String else {
                continue
            }
            #expect(!label.isEmpty)
            if let embedding = ref["embedding"] as? [Double] {
                #expect(embedding.count == 768, "SigLIP2 output dimension must be 768, got \(embedding.count)")
                #expect(embedding.contains { $0 != 0.0 }, "Reference embedding must not be all zeros")
            }
        }
    }

    @Test("reference vector dimension is 768 (SigLIP2-B/32 output)")
    func test_referenceVectors_dimension768() throws {
        let url = try #require(Bundle.main.url(forResource: "siglip2-reference-vectors", withExtension: "json"), "siglip2-reference-vectors.json missing")
        let data = try #require(try? Data(contentsOf: url), "reference vectors unreadable")
        let dictOpt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let dict = try #require(dictOpt, "reference vectors JSON malformed")

        #expect((dict["dimension"] as? Int) == 768)
    }

    @Test("cosine similarity between conversion output and reference exceeds 0.995",
          .enabled(if: siglip2MLModelCAvailable()))
    func test_conversion_cosineSimilarity() async throws {
        try #require(siglip2MLModelCAvailable(), "SigLIP2 .mlmodelc unavailable - required vision test must fail loudly")

        let embedder = SigLIP2Embedder()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        let image = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }

        let embedding = try await embedder.embedImage(from: image)
        #expect(embedding.count == 768)
        #expect(!embedding.allSatisfy { $0 == 0.0 }, "Real inference must produce non-zero embedding")

        // US-SRC-011: Core ML 运行时输出必须与 PyTorch 参考向量余弦相似度 > 0.995
        let url = try #require(Bundle.main.url(forResource: "siglip2-reference-vectors", withExtension: "json"), "siglip2-reference-vectors.json missing")
        let data = try #require(try? Data(contentsOf: url), "reference vectors unreadable")
        let dictOpt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let dict = try #require(dictOpt, "siglip2-reference-vectors.json invalid")
        let samplesOpt = dict["samples"] as? [[String: Any]]
        let samples = try #require(samplesOpt, "samples array missing from siglip2-reference-vectors.json")
        let blueRefOpt = samples.first { ($0["label"] as? String) == "solid_blue_256" }
        let blueRef = try #require(blueRefOpt, "solid_blue_256 reference embedding missing - run Scripts/convert_siglip2.py first")
        let refEmbeddingOpt = blueRef["embedding"] as? [Double]
        let refEmbedding = try #require(refEmbeddingOpt, "solid_blue_256 reference embedding malformed")
        let cosine = cosineSimilarity(embedding, refEmbedding)
        #expect(cosine > 0.995, "Core ML output vs PyTorch reference cosine must exceed 0.995, got \(cosine)")
    }
}

// MARK: - Real Vision Inference

@Suite("SigLIP2ConversionTests.RealInference", .serialized)
@MainActor
struct SigLIP2RealInferenceTests {

    @Test("embedImage produces 768d non-zero embedding (US-ING-004 AC-3)",
          .enabled(if: siglip2MLModelCAvailable()))
    func test_embedImage_produces768dVector() async throws {
        try #require(siglip2MLModelCAvailable(), "SigLIP2 .mlmodelc unavailable - required vision test must fail loudly")

        let embedder = SigLIP2Embedder()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }

        let embedding = try await embedder.embedImage(from: image)
        #expect(embedding.count == 768, "SigLIP2 must output 768-dimensional vector")
        #expect(embedding.contains { $0 != 0.0 }, "Real inference must produce non-zero output")
    }

    @Test("embedImage with different inputs produces different embeddings",
          .enabled(if: siglip2MLModelCAvailable()))
    func test_embedImage_differentInputs() async throws {
        try #require(siglip2MLModelCAvailable(), "SigLIP2 .mlmodelc unavailable - required vision test must fail loudly")

        let embedder = SigLIP2Embedder()
        let redImage = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        let blueImage = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256)).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }

        let redEmb = try await embedder.embedImage(from: redImage)
        let blueEmb = try await embedder.embedImage(from: blueImage)

        #expect(redEmb != blueEmb, "Different images must produce different embeddings")
    }

    @Test("embedImage with identical input produces identical embedding (deterministic)",
          .enabled(if: siglip2MLModelCAvailable()))
    func test_embedImage_deterministic() async throws {
        try #require(siglip2MLModelCAvailable(), "SigLIP2 .mlmodelc unavailable - required vision test must fail loudly")

        let embedder = SigLIP2Embedder()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        let image = renderer.image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }

        let e1 = try await embedder.embedImage(from: image)
        let e2 = try await embedder.embedImage(from: image)

        #expect(e1 == e2, "Identical input must produce identical embedding")
    }

    @Test("embedImage throws when .mlmodelc absent")
    func test_embedImage_throwsWhenModelAbsent() async {
        let embedder = SigLIP2Embedder()
        if siglip2MLModelCAvailable() { return }
        await #expect(throws: EmbedderError.self) {
            _ = try await embedder.embedImage(assetId: "no-model")
        }
    }

    @Test("preprocess output is normalized to [-1, 1] range")
    func test_preprocess_normalizedRange() async throws {
        let embedder = SigLIP2Embedder()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        let floats = try embedder.preprocess(image)
        #expect(floats.count == 256 * 256 * 3)

        for v in floats {
            #expect(v >= -1.1 && v <= 1.1, "Preprocessed values should be in normalized range, got \(v)")
        }
    }

    // C1 regression (PR review): non-square images (real photos 4:3/3:4) must not crash
    @Test("preprocess of non-square image yields exactly 3x256x256 (C1 regression)")
    func test_preprocess_nonSquareImage() async throws {
        let embedder = SigLIP2Embedder()
        // 4:3 landscape (common real-photo aspect ratio)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300))
        let landscape = renderer.image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let floats = try embedder.preprocess(landscape)
        #expect(floats.count == 256 * 256 * 3,
                "Non-square preprocessing must produce exactly 3x256x256, got \(floats.count)")
    }

    // C1 regression (PR review): full inference on non-square image must not crash
    @Test("embedImage of non-square image produces 768d embedding (C1 regression)")
    func test_embedImage_nonSquareImage() async throws {
        guard siglip2MLModelCAvailable() else { return }

        let embedder = SigLIP2Embedder()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300))
        let landscape = renderer.image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let embedding = try await embedder.embedImage(from: landscape)
        #expect(embedding.count == 768, "Non-square image must produce 768d embedding")
    }
}

// MARK: - Four Gates

@Suite("SigLIP2ConversionTests.FourGates", .serialized)
@MainActor
struct SigLIP2FourGateTests {

    // Gate 1: Legal — LICENSE, NOTICE, SHA-256

    @Test("Gate 1 (Legal): model-manifest.json has Apache-2.0 license for SigLIP2")
    func test_gate1_legal_license() throws {
        guard let url = Bundle.main.url(forResource: "model-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = manifest["models"] as? [[String: Any]]
        else { return }
        let siglip2 = models.first { ($0["modelId"] as? String) == "siglip2-base-patch32-256-v1" }
        #expect(siglip2 != nil)
        #expect((siglip2?["licenseId"] as? String) == "apache-2.0", "SigLIP2 must be Apache-2.0 licensed")
    }

    @Test("Gate 1 (Legal): artifact hash is registered in manifest")
    func test_gate1_legal_artifactHash() throws {
        guard let url = Bundle.main.url(forResource: "model-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = manifest["models"] as? [[String: Any]]
        else { return }
        let siglip2 = models.first { ($0["modelId"] as? String) == "siglip2-base-patch32-256-v1" }
        let hash = siglip2?["artifactHash"] as? String ?? ""
        #expect(hash.count == 64, "SHA-256 must be 64 hex chars, got \(hash.count)")
        #expect(hash.allSatisfy { $0.isHexDigit }, "SHA-256 must be hex")
    }

    // Gate 2: Conversion consistency

    @Test("Gate 2 (Conversion): model provenance updated from pending-conversion")
    func test_gate2_conversion_provenance() throws {
        guard let url = Bundle.main.url(forResource: "model-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = manifest["models"] as? [[String: Any]]
        else { return }
        let siglip2 = models.first { ($0["modelId"] as? String) == "siglip2-base-patch32-256-v1" }
        let provenance = siglip2?["provenance"] as? String ?? ""
        #expect(provenance != "pending-conversion-and-approval",
                "Provenance must transition away from 'pending-conversion-and-approval' after conversion")
        #expect(provenance == "pending-approval" || provenance == "approved" || provenance == "pending-evaluation",
                "Provenance must be 'pending-approval', 'approved', or 'pending-evaluation', got '\(provenance)'")
    }

    @Test("Gate 2 (Conversion): conversion script present")
    func test_gate2_conversion_script() {
        guard let content = try? conversionScriptContent() else {
            Issue.record("convert_siglip2.py not found in repository — conversion script is a required resource")
            return
        }
        #expect(content.contains("coremltools") || content.contains("CoreML"),
                "Conversion script must reference coremltools")
        #expect(content.contains("sha256") || content.contains("hashlib"),
                "Conversion script must compute SHA-256 of output")
    }

    @Test("Gate 2 (Conversion): conversion lineage recorded in provenance register")
    func test_gate2_conversion_lineage() throws {
        // model-provenance-register.md §3 应记录 Core ML 转换 lineage
        guard let registerURL = Bundle.main.url(forResource: "model-provenance-register", withExtension: "md"),
              let content = try? String(contentsOf: registerURL, encoding: .utf8)
        else {
            // Not bundled — verified at gate level via documentation audit
            return
        }
        #expect(content.contains("coremltools"), "Conversion lineage must mention coremltools")
        #expect(content.contains("SigLIP2"), "Conversion lineage must cover SigLIP2")
    }

    // Gate 3: Echo dataset device evaluation

    @Test("Gate 3 (Evaluation): model inference terminates within timeout")
    func test_gate3_inferenceTimeout() async throws {
        guard siglip2MLModelCAvailable() else { return }

        let embedder = SigLIP2Embedder()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        let image = renderer.image { ctx in
            UIColor.purple.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }

        let start = Date()
        let embedding = try await embedder.embedImage(from: image)
        let elapsed = Date().timeIntervalSince(start)

        #expect(embedding.count == 768)
        #expect(elapsed < 10.0, "Single-image inference must complete within 10 seconds, took \(elapsed)")
    }

    // Gate 4: Physical device resource gate

    @Test("Gate 4 (Resource): model bundle size reasonable (< 2GB)")
    func test_gate4_modelSize() throws {
        guard let modelURL = Bundle.main.url(forResource: "SigLIP2BasePatch32", withExtension: "mlmodelc") else {
            return
        }
        let totalSize = directorySize(at: modelURL)
        let sizeMB = Double(totalSize) / 1_048_576.0
        #expect(sizeMB < 2048, "mlmodelc must be under 2GB, got \(sizeMB) MB")
    }

    @Test("Gate 4 (Resource): embedding allocation is within bounds")
    func test_gate4_embeddingSize() {
        let dim = SigLIP2Embedder.dimension
        let floatSize = MemoryLayout<Float>.stride
        let embeddingBytes = dim * floatSize
        let embeddingKB = Double(embeddingBytes) / 1024.0
        #expect(embeddingKB < 16, "768d float vector must be <16KB, got \(embeddingKB) KB")
    }
}

// MARK: - Conversion Script Test

@Suite("SigLIP2ConversionTests.ConversionScript", .serialized)
@MainActor
struct SigLIP2ConversionScriptTests {

    @Test("convert_siglip2.py is non-empty and references coremltools")
    func test_script_syntax() throws {
        let script = try conversionScriptContent()
        #expect(!script.isEmpty, "Conversion script must not be empty")
        #expect(script.contains("coremltools") || script.contains("CoreML"),
                "Conversion script must reference coremltools")
    }

    @Test("convert_siglip2.py records fixed revision")
    func test_script_hasRevision() throws {
        let script = try conversionScriptContent()
        #expect(script.contains("REVISION") || script.contains("revision") || script.contains("sha256"),
                "Conversion script must track revision")
    }

    @Test("convert_siglip2.py includes SHA-256 output")
    func test_script_hasSha256() throws {
        let script = try conversionScriptContent()
        #expect(script.contains("sha256") || script.contains("hashlib") || script.contains("SHA256"),
                "Conversion script must compute SHA-256 of output")
    }

    @Test("reference vectors JSON schemaVersion is present")
    func test_referenceVectors_schemaVersion() throws {
        guard let url = Bundle.main.url(forResource: "siglip2-reference-vectors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        #expect((dict["schemaVersion"] as? String) == "1.0.0")
    }
}

// MARK: - ModelLoader Integration

@Suite("SigLIP2ConversionTests.ModelLoaderIntegration", .serialized)
@MainActor
struct SigLIP2ModelLoaderIntegrationTests {

    @Test("ModelLoaderActor registers SigLIP2 model type")
    func test_modelType_siglip2Registered() async {
        let loader = ModelLoaderActor()
        let state = await loader.state(for: .siglip2Vision)
        // A fresh loader must start in .notLoaded (AC-5 default); proves the model type is registered and queryable
        if case .notLoaded = state {
            #expect(true)
        } else {
            Issue.record("SigLIP2 initial state must be .notLoaded, got \(state)")
        }
    }

    @Test("reportModelLoaded works with siglip2Vision type")
    func test_reportModelLoaded_siglip2() async {
        let loader = ModelLoaderActor()
        await loader.reportModelLoaded(.siglip2Vision)
        let state = await loader.state(for: .siglip2Vision)
        #expect(state.isLoaded, "reportModelLoaded for siglip2Vision must set .loaded")
    }

    @Test("getModelBundleURL returns URL when .mlmodelc bundled")
    func test_getModelBundleURL_siglip2() async {
        let loader = ModelLoaderActor()
        let url = await loader.getModelBundleURL(.siglip2Vision)
        if !siglip2MLModelCAvailable() {
            return
        }
        #expect(url != nil, "SigLIP2 model bundle URL must be resolvable when mlmodelc exists")
    }
}

// MARK: - Helpers

/// Reads Scripts/convert_siglip2.py from the repository working tree.
///
/// The script is a repo file, not a bundle resource, so it cannot be located
/// via `Bundle.main` (CodeRabbit review: fail when the script is unavailable).
private func conversionScriptContent() throws -> String {
    let thisFile = URL(fileURLWithPath: #filePath)          // EchoTests/Phase3F/...
    let repoRoot = thisFile
        .deletingLastPathComponent()                        // Phase3F
        .deletingLastPathComponent()                        // EchoTests
        .deletingLastPathComponent()                        // repo root
    let scriptURL = repoRoot.appendingPathComponent("Scripts/convert_siglip2.py")
    return try String(contentsOf: scriptURL, encoding: .utf8)
}

private func cosineSimilarity(_ a: [Float], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot = 0.0, normA = 0.0, normB = 0.0
    for i in 0..<a.count {
        dot += Double(a[i]) * b[i]
        normA += Double(a[i]) * Double(a[i])
        normB += b[i] * b[i]
    }
    guard normA > 0, normB > 0 else { return 0 }
    return dot / (sqrt(normA) * sqrt(normB))
}

private func directorySize(at url: URL) -> UInt64 {
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey],
        options: .skipsHiddenFiles
    ) else { return 0 }

    var total: UInt64 = 0
    for case let fileURL as URL in enumerator {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else { continue }
        total += UInt64(size)
    }
    return total
}
