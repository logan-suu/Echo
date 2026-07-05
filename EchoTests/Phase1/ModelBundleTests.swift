// ==========================================
// 文件: ModelBundleTests.swift
// 对应规格: docs/02-architecture/技术选型文档.md v5.1b §1~3
// 任务: 1.5 - 模型打包到 Bundle
// AC 覆盖:
//   - AC-VISION: MobileCLIP-B LT Core ML 模型存在于 Bundle
//   - AC-EMBED: multilingual-e5-small Core ML 模型存在于 Bundle
//   - AC-ASR: SenseVoice Small (CoreML + GGUF) 存在于 Bundle
//   - AC-NO-NETWORK: 所有模型通过 Bundle 加载 (R-005)
// 架构约束: AGENTS.md §1.2 R-005
// 生成时间: 2026-07-04
// ==========================================

import Foundation
import Testing

// MARK: - Expected Models

/// Xcode 将 .mlpackage 编译为 .mlmodelc，放在 app bundle 根目录
struct ExpectedModels {
    /// (name, bundleResourceName, extension, minBytes)
    static let all: [(String, String, String, Int)] = [
        ("MobileCLIP-B LT image", "MobileCLIP-B-lt_image", "mlmodelc", 10_000_000),
        ("MobileCLIP-B LT text", "MobileCLIP-B-lt_text", "mlmodelc", 10_000_000),
        ("multilingual-e5-small", "MultilingualE5Small", "mlmodelc", 10_000_000),
        ("SenseVoice INT8", "SenseVoiceSmall_int8", "mlmodelc", 10_000_000),
        ("SenseVoice Preprocessor", "SenseVoicePreprocessor", "mlmodelc", 1_000_000),
        ("SenseVoice GGUF", "sensevoice-small-q4_k", "gguf", 50_000_000),
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

    // 清单完整性
    @Test func modelCountIsSix() {
        #expect(ExpectedModels.all.count == 6)
    }
}
