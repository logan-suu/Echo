// ==========================================
// 文件: PhotoTextSearchConversionTests.swift
// 对应规格: 自然语言照片检索交接计划 §7.2（提议契约）
// 任务: WP2 - 精确双塔转换验证性试验（步骤 0a-0d 起步切片）
// AC 覆盖: VisionTextEmbedder 协议 nonisolated 声明与 actor 一致性验证
// 架构约束: SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor 下显式 nonisolated 惯例；R-008 await
// 生成时间: 2026-08-25
// ==========================================

import Foundation
import Testing

@testable import Echo

/// WP2 转换契约测试：配对文本塔运行时接口的隔离与一致性。
@Suite("PhotoTextSearchConversion")
struct PhotoTextSearchConversionTests {

    /// Actor 测试替身——证明协议可被 actor 无 MainActor 跳跃 conform。
    private actor DummyVisionTextEmbedder: VisionTextEmbedder {
        nonisolated let modelManifestID = "test-siglip2-text-dummy"
        nonisolated let alignmentSpaceID = "siglip2-b32-256-aligned"
        nonisolated let dimension = 768

        func embedVisionQuery(text: String, locale: String, traceID: String) async throws -> [Float] {
            [Float](repeating: 1.0 / sqrt(768), count: 768)
        }
    }

    // MARK: - WP2 Step 0a/0b: VisionTextEmbedder nonisolated 协议

    @Test("VisionTextEmbedder conformance without MainActor hop (WP2 step 0a)")
    func testVisionTextEmbedderProtocolIsNonisolated() async throws {
        let dummy = DummyVisionTextEmbedder()
        let vector = try await dummy.embedVisionQuery(text: "red flower", locale: "en-US", traceID: "t-wp2-0a")
        #expect(vector.count == 768)
        #expect(await dummy.modelManifestID == "test-siglip2-text-dummy")
        #expect(await dummy.alignmentSpaceID == "siglip2-b32-256-aligned")
    }
}
