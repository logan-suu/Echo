// ==========================================
// 文件: QueryRepresentationFactory.swift
// 对应规格: 自然语言照片检索交接计划 §7.3（WP4 步骤 1a-1j）
// 任务: WP4 - 生产多通道查询与规范 RRF 接线（每通道原生载荷生成 + 部分失败隔离）
// 架构约束: SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor 下值契约显式 nonisolated；
//           单通道生成失败记录到 failures 不阻断健康通道（部分失败隔离语义）。
// 生成时间: 2026-08-25
// ==========================================

import CryptoKit
import Foundation

/// 查询表示工厂契约——按路由快照声明的通道集合生成每通道原生载荷。
public nonisolated protocol QueryRepresentationFactory: Sendable {
    func makeQuery(
        text: String,
        locale: String,
        route: SearchRouteSnapshot,
        traceID: String
    ) async -> QueryRepresentationOutcome
}

/// 默认实现——双嵌入器协作生成稠密载荷，词法通道保留原文与 locale。
///
/// - textDense / ocrText：E5 `.query` 上下文 384d 稠密向量
/// - visionDense：配对 SigLIP2 文本塔 768d 稠密向量（同 checkpoint 同对齐空间）
/// - lexical：原始查询文本 + locale（不经向量化）
///
/// 任一通道生成抛错时记入 `failures` 并继续其余通道（部分失败隔离，
/// 交接计划 WP4 步骤 2a/2b：vision failure 不移除 text payload）。
public struct DefaultQueryRepresentationFactory: QueryRepresentationFactory {
    /// E5 上下文感知嵌入器（.query 用于检索侧）
    public nonisolated let textEmbedder: any ContextualTextEmbedder
    /// 配对 SigLIP2 文本塔（与图像塔同 checkpoint 同对齐空间）
    public nonisolated let visionEmbedder: any VisionTextEmbedder
    /// E5 对齐空间标识——与视觉塔的 alignmentSpaceID 相互独立（跨空间禁止混用）。
    public nonisolated let e5AlignmentSpaceID: String

    public init(
        textEmbedder: any ContextualTextEmbedder,
        visionEmbedder: any VisionTextEmbedder,
        e5AlignmentSpaceID: String = "aligned-e5-v1"
    ) {
        self.textEmbedder = textEmbedder
        self.visionEmbedder = visionEmbedder
        self.e5AlignmentSpaceID = e5AlignmentSpaceID
    }

    // MARK: - QueryRepresentationFactory

    public func makeQuery(
        text: String,
        locale: String,
        route: SearchRouteSnapshot,
        traceID: String
    ) async -> QueryRepresentationOutcome {
        var payloads: [SearchChannel: ChannelQueryPayload] = [:]
        var failures: [SearchChannel: ChannelFailure] = [:]

        for declared in route.channels {
            let channel = declared.channel
            do {
                switch channel {
                case .textDense:
                    payloads[.textDense] = try await e5Payload(
                        text: text, traceID: traceID, failing: channel
                    )
                case .ocrText:
                    // OCR 通道同样索引 E5 向量（摄入侧 .passage / 查询侧 .query）
                    payloads[.ocrText] = try await e5Payload(
                        text: text, traceID: traceID, failing: channel
                    )
                case .visionDense:
                    let vec = try await visionEmbedder.embedVisionQuery(
                        text: text, locale: locale, traceID: traceID
                    )
                    payloads[.visionDense] = .dense(
                        try DenseQueryVector(
                            values: vec,
                            dimension: visionEmbedder.dimension,
                            modelManifestID: visionEmbedder.modelManifestID,
                            alignmentSpaceID: visionEmbedder.alignmentSpaceID
                        )
                    )
                case .lexical:
                    // 词法通道保留原文与 locale，不经向量化
                    payloads[.lexical] = .lexical(text: text, locale: locale)
                }
            } catch {
                failures[channel] = ChannelFailure(
                    channel: channel,
                    code: "queryGenerationFailed",
                    level: "L1",
                    retryable: true
                )
            }
        }

        let multi = MultiChannelQuery(
            queryHash: Self.stableHash(text),
            locale: locale,
            payloads: payloads,
            routeSnapshotID: route.snapshotID,
            traceID: traceID
        )
        return QueryRepresentationOutcome(query: multi, failures: failures)
    }

    // MARK: - Private

    private func e5Payload(
        text: String,
        traceID: String,
        failing channel: SearchChannel
    ) async throws -> ChannelQueryPayload {
        let vector = try await textEmbedder.embed(
            text: text, context: .query, traceID: traceID
        )
        return .dense(
            try DenseQueryVector(
                values: vector,
                dimension: textEmbedder.dimension,
                modelManifestID: textEmbedder.modelManifestID,
                alignmentSpaceID: e5AlignmentSpaceID
            )
        )
    }

    /// 稳定查询哈希——SHA-256 over UTF-8 bytes 的 hex 前 32 位。
    private static func stableHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).lowercased()
    }
}
