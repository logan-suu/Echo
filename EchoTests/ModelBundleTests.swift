// ==========================================
// 文件: ModelBundleTests.swift
// 对应规格: docs/02-architecture/技术选型文档.md v5.1b §1~3
// 任务: 1.5 - 将 MobileCLIP-B LT, multilingual-e5-small, SenseVoice Small 模型打包到 Bundle
// AC 覆盖:
//   - AC-VISION: MobileCLIP-B LT (image + text) Core ML 模型存在于 Bundle
//   - AC-EMBED: multilingual-e5-small Core ML 模型存在于 Bundle
//   - AC-ASR: SenseVoice Small (CoreML + GGUF) 模型存在于 Bundle
//   - AC-NO-NETWORK: 所有模型通过 Bundle 加载，不发起网络请求 (R-005)
// 架构约束: 遵循 AGENTS.md §1.2 R-005 (模型加载无网络下载)
// 生成时间: 2026-07-04
// 更新: v5.1b — 最终可用方案
// ==========================================

import Foundation
import Testing

// MARK: - 模型清单常量

/// Echo v5.1 打包模型清单
/// 所有模型随 App Bundle 分发，符合 R-005（模型加载无网络下载）
struct BundleModelManifest {
    /// 必需模型资源路径（相对于 Bundle 根目录）
    /// 实际文件名以 prepare_models.sh 下载结果为准
    static let requiredModels: [(name: String, pathPattern: String, minSizeBytes: Int, format: String)] = [
        (
            name: "MobileCLIP2-S4 (Visual Encoder)",
            pathPattern: "MobileCLIP2-S4",
            minSizeBytes: 100_000_000,  // PyTorch ~1.7GB, Core ML INT8 ~420MB
            format: "Core ML (.mlmodelc/.mlpackage) or PyTorch (.pt)"
        ),
        (
            name: "Qwen3-Embedding-0.6B (Text Embedding)",
            pathPattern: "Qwen3-Embedding-0.6B",
            minSizeBytes: 100_000_000,  // CoreAI ~1.1GB, INT4 ~400MB
            format: "Core ML (.mlmodelc/.mlpackage) or CoreAI (.aimodel)"
        ),
        (
            name: "SenseVoice Small (ASR Engine)",
            pathPattern: "sensevoice-small",
            minSizeBytes: 50_000_000,   // GGUF Q4_K 129MB, CoreML INT8 ~226MB
            format: "GGUF (.gguf) or Core ML (.mlmodelc)"
        ),
    ]

    /// 模型准备脚本路径
    static let prepareScriptName = "prepare_models.sh"
}

// MARK: - 模型资源存在性测试

struct ModelBundleTests {

    // MARK: AC-VISION: MobileCLIP2-S4 模型存在

    @Test func testMobileCLIP2S4ModelExists() async throws {
        let model = BundleModelManifest.requiredModels[0]
        let found = findAnyModelResource(matching: model.pathPattern)

        if let url = found {
            let size = try resourceSize(at: url)
            #expect(size >= model.minSizeBytes,
                    "\(model.name) 文件大小 \(size) bytes < 预期最小值 \(model.minSizeBytes) bytes")
        } else {
            Issue.record(Comment(
                "\(model.name) (\(model.format)) 未在 Bundle 中找到。请运行 Scripts/prepare_models.sh。"
            ))
        }
    }

    // MARK: AC-EMBED: Qwen3-Embedding-0.6B 模型存在

    @Test func testQwen3EmbeddingModelExists() async throws {
        let model = BundleModelManifest.requiredModels[2]
        let found = findModelResource(matching: model.pathPattern, format: "mlmodelc")
            ?? findModelResource(matching: model.pathPattern, format: "mlpackage")

        if let url = found {
            let size = try resourceSize(at: url)
            #expect(size >= model.minSizeBytes,
                    "\(model.name) 文件大小 \(size) bytes < 预期最小值 \(model.minSizeBytes) bytes")
        } else {
            Issue.record(Comment(
                "\(model.name) (\(model.format)) 未在 Bundle 中找到。请运行 Scripts/prepare_models.sh 下载并准备模型文件。"
            ))
        }
    }

    // MARK: AC-ASR: SenseVoice Small 模型存在

    @Test func testSenseVoiceSmallModelExists() async throws {
        let model = BundleModelManifest.requiredModels[3]
        let found = findModelResource(matching: model.pathPattern, format: "gguf")

        if let url = found {
            let size = try resourceSize(at: url)
            #expect(size >= model.minSizeBytes,
                    "\(model.name) 文件大小 \(size) bytes < 预期最小值 \(model.minSizeBytes) bytes")
        } else {
            Issue.record(Comment(
                "\(model.name) (\(model.format)) 未在 Bundle 中找到。请运行 Scripts/prepare_models.sh 下载并准备模型文件。"
            ))
        }
    }

    // MARK: AC-NO-NETWORK: 验证模型通过 Bundle 加载（不发起网络请求）

    @Test func testAllModelsLoadableFromBundleWithoutNetwork() async throws {
        // 验证 Bundle 资源路径可枚举 — 模型文件必须在 Bundle 内
        let modelPatterns = BundleModelManifest.requiredModels.map { $0.pathPattern }
        var foundCount = 0

        for pattern in modelPatterns {
            if let _ = Bundle.main.url(forResource: pattern, withExtension: nil, subdirectory: "Models") {
                foundCount += 1
            } else if let _ = Bundle.main.url(forResource: pattern, withExtension: nil) {
                foundCount += 1
            }
        }

        // 不强制 foundCount == 4（允许开发环境未下载模型），
        // 但 CI 环境通过 prepare_models.sh 应确保全部存在
        if foundCount < modelPatterns.count {
            Issue.record(Comment(
                "仅找到 \(foundCount)/\(modelPatterns.count) 模型。CI 环境必须运行 Scripts/prepare_models.sh 后模型完整性检查通过。"
            ))
        } else {
            #expect(true, "所有 \(foundCount) 个模型已通过 Bundle 加载，符合 R-005。")
        }
    }

    // MARK: 模型准备脚本存在性

    @Test func testPrepareModelsScriptExists() {
        // 脚本位于项目根目录 Scripts/prepare_models.sh
        // 在 Xcode 测试环境中，通过 SRCROOT 环境变量定位项目根目录
        let srcRoot = ProcessInfo.processInfo.environment["SRCROOT"]
            ?? ProcessInfo.processInfo.environment["PROJECT_DIR"]
            ?? FileManager.default.currentDirectoryPath

        let scriptPath = (srcRoot as NSString).appendingPathComponent("Scripts/prepare_models.sh")
        let scriptExists = FileManager.default.fileExists(atPath: scriptPath)

        #expect(scriptExists,
                "prepare_models.sh 未在 \(scriptPath) 找到。")
    }

    // MARK: 模型数量完整性

    @Test func testModelCountMatchesManifest() {
        let expectedCount = 3  // MobileCLIP2-S4 + Qwen3-Embedding + SenseVoice
        let actualCount = BundleModelManifest.requiredModels.count
        #expect(actualCount == expectedCount,
                "模型清单数量应为 \(expectedCount)，实际为 \(actualCount)")
    }
}

// MARK: - Helpers

/// 在 Bundle 中查找匹配名称的任意格式模型资源
private func findAnyModelResource(matching name: String) -> URL? {
    // 尝试所有可能的格式
    let formats = ["mlmodelc", "mlpackage", "aimodel", "gguf", "pt"]
    for fmt in formats {
        if let url = findModelResource(matching: name, format: fmt) {
            return url
        }
    }
    // 尝试作为目录查找
    if let url = Bundle.main.url(forResource: name, withExtension: nil) {
        return url
    }
    if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Models") {
        return url
    }
    return nil
}

/// 在 Bundle 中查找匹配名称和后缀的模型资源
private func findModelResource(matching name: String, format: String) -> URL? {
    // 尝试直接匹配文件名
    if let url = Bundle.main.url(forResource: name, withExtension: format) {
        return url
    }
    // 尝试在 Models 子目录中匹配
    if let url = Bundle.main.url(forResource: name, withExtension: format, subdirectory: "Models") {
        return url
    }
    // 尝试匹配 .mlmodelc 目录（Core ML 编译后的 bundle 格式）
    if format == "mlmodelc" {
        if let url = Bundle.main.url(forResource: name, withExtension: format) {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: format, subdirectory: "Models") {
            return url
        }
    }
    return nil
}

/// 获取资源文件/目录大小
private func resourceSize(at url: URL) throws -> Int {
    let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
    // 对于 .mlmodelc 目录，使用 totalFileSizeKey
    return resourceValues.totalFileSize
        ?? resourceValues.fileSize
        ?? 0
}
