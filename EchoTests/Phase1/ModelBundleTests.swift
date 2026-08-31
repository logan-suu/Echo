// ==========================================
// 文件: ModelBundleTests.swift
// 对应规格: docs/02-architecture/技术选型文档.md v6.0 §1~3
// 任务: 1.5 - 模型打包到 Bundle；3F.3/WP4 v6.0 四模型运行时清单
// AC 覆盖:
//   - AC-VISION: SigLIP2-B/32 视觉（3F.3：转换源已登记，.mlmodelc pending）
//   - AC-VISION-TEXT: SigLIP2-B/32 配对文本塔存在于 Bundle
//   - AC-EMBED: multilingual-e5-small Core ML 模型存在于 Bundle
//   - AC-ASR: Whisper tiny GGUF 存在于 Bundle
//   - AC-NO-NETWORK: 所有模型通过 Bundle 加载 (R-005)
// 架构约束: AGENTS.md §1.2 R-005, ADR-009 决策 2 (provenance register)
// 生成时间: 2026-07-04 (3F.3: 2026-08-06)
// ==========================================

import Foundation
import Testing

// MARK: - Expected Models

/// Xcode 将 .mlpackage 编译为 .mlmodelc，放在 app bundle 根目录
struct ExpectedModels {
    /// (name, bundleResourceName, extension, minBytes)
    ///
    /// v6.0 生产模型集：E5、SigLIP2 图像塔、SigLIP2 配对文本塔、Whisper 均随 App 分发。
    /// MobileCLIP-B / SenseVoice 因许可问题退役，不再打包。
    static let all: [(String, String, String, Int)] = [
        ("multilingual-e5-small", "MultilingualE5Small", "mlmodelc", 10_000_000),
        ("SigLIP2 image tower", "SigLIP2BasePatch32", "mlmodelc", 10_000_000),
        ("SigLIP2 text tower", "SigLIP2TextBasePatch32", "mlmodelc", 10_000_000),
        ("Whisper tiny Q5_1", "whisper-tiny-q5_1", "gguf", 30_000_000),
    ]
}

// MARK: - Tests

struct ModelBundleTests {

    // AC-NO-NETWORK: 所有模型可通过 Bundle 访问
    @Test func allModelsPresentInBundle() {
        let bundlePath = Bundle.main.bundlePath
        let fm = FileManager.default
        var found = 0

        for (name, resource, ext, _) in ExpectedModels.all {
            let path = bundlePath + "/" + resource + "." + ext
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir) {
                found += 1
            }
        }

        if found != ExpectedModels.all.count {
            // List what's actually in the bundle
            let actual = (try? fm.contentsOfDirectory(atPath: bundlePath)) ?? []
            let filtered = actual.filter { $0.contains("mlmodelc") || $0.contains("gguf") }
            Issue.record(Comment(
                "Expected \(ExpectedModels.all.count), found \(found). Bundle: \(filtered.joined(separator: ", "))"
            ))
        }
        #expect(found == ExpectedModels.all.count)
    }

    // 清单完整性（已打包工件数）
    @Test func modelCountIsFour() {
        #expect(ExpectedModels.all.count == 4)
    }

    // 3F.3 / ADR-009 决策 2: SigLIP2 转换源已在 model-manifest.json 登记为 pending-conversion
    @Test func siglip2ConversionSourceRegistered() throws {
        guard let url = Bundle.main.url(forResource: "model-manifest", withExtension: "json") else {
            Issue.record("model-manifest.json missing from bundle")
            return
        }
        let data = try Data(contentsOf: url)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try #require(json["models"] as? [[String: Any]])
        let siglip2 = try #require(models.first { ($0["modelId"] as? String)?.contains("siglip2") == true })
        let provenance = try #require(siglip2["provenance"] as? String)
        #expect(provenance == "pending-evaluation",
                "SigLIP2 provenance must be 'pending-evaluation' after 3F.3a conversion complete (was pending-conversion-and-approval)")
    }
}
