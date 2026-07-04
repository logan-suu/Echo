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
        ("MobileCLIP-B LT text",  "MobileCLIP-B-lt_text",  "mlmodelc", 10_000_000),
        ("multilingual-e5-small", "MultilingualE5Small",   "mlmodelc", 10_000_000),
        ("SenseVoice INT8",       "SenseVoiceSmall_int8",  "mlmodelc", 10_000_000),
        ("SenseVoice Preprocessor","SenseVoicePreprocessor","mlmodelc",   1_000_000),
        ("SenseVoice GGUF",       "sensevoice-small-q4_k",  "gguf",    50_000_000),
    ]
}

// MARK: - Tests

struct ModelBundleTests {

    // AC-NO-NETWORK: 所有模型可通过 Bundle 访问
    @Test func allModelsPresentInBundle() {
        let bundle = Bundle.main
        var found = 0
        var details: [String] = []

        for (name, resource, ext, minBytes) in ExpectedModels.all {
            let fullName = "\(resource).\(ext)"
            let path = bundle.path(forResource: resource, ofType: ext)

            if let path {
                let url = URL(fileURLWithPath: path)
                if let size = fileSize(at: url), size >= minBytes {
                    found += 1
                } else {
                    let s = fileSize(at: url) ?? 0
                    details.append("\(name): size \(s) < \(minBytes)")
                }
            } else {
                // Fallback: try direct filesystem check
                let directPath = bundle.bundlePath + "/" + fullName
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: directPath, isDirectory: &isDir) {
                    let url = URL(fileURLWithPath: directPath)
                    if let size = fileSize(at: url), size >= minBytes {
                        found += 1
                        details.append("\(name): found via direct path")
                    } else {
                        details.append("\(name): direct path size too small")
                    }
                } else {
                    details.append("\(name) not found (\(fullName))")
                }
            }
        }

        if found != ExpectedModels.all.count {
            Issue.record(Comment(
                "\(found)/\(ExpectedModels.all.count) in \(bundle.bundlePath). \(details.joined(separator: "; "))"
            ))
        }
        #expect(found == ExpectedModels.all.count)
    }

    // 清单完整性
    @Test func modelCountIsSix() {
        #expect(ExpectedModels.all.count == 6)
    }
}

// MARK: - Helpers

private func fileSize(at url: URL) -> Int? {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey]) else {
        return nil
    }
    return values.totalFileSize ?? values.fileSize
}
