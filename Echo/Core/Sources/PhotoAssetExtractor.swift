// ==========================================
// 文件: PhotoAssetExtractor.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-004 (图片摄入)
//            docs/02-architecture/数据流全链路技术说明文档.md §3.1 (图片摄入时序)
//            docs/decisions/ADR-008-source-import-boundaries.md §决策-1 (PhotoKit 授权边界)
// 任务: 3F.5 - Production ingestion
// AC 覆盖: US-ING-004 AC-2 (EXIF 元数据完整保留), AC-4 (PHAsset 引用，不复制存储),
//          US-SRC-001 AC-6 (仅处理已下载本地资源)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (零网络), R-007 (禁止 unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
//       PhotoKit SDK 标注 @MainActor，真实实现经 MainActor.run 跳转访问（与 3F.2 一致）
// 生成时间: 2026-08-10
// ==========================================

import Foundation
@preconcurrency import Photos
import UIKit

/// 图片资产提取结果 — 供生产摄入管线消费（不跨边界传递 PHAsset）。
public struct PhotoAssetContent: Sendable, Equatable {
    public nonisolated let assetId: String
    /// 原始创建时间（AC-2：保留时间戳元数据）
    public nonisolated let creationDate: Date?
    /// JSON 编码的 EXIF 元数据（AC-2：GPS 按 UserPolicy 决定）
    public nonisolated let exifMetadata: Data?

    public nonisolated init(
        assetId: String,
        creationDate: Date?,
        exifMetadata: Data?
    ) {
        self.assetId = assetId
        self.creationDate = creationDate
        self.exifMetadata = exifMetadata
    }
}

/// 图片资产提取协议 — 抽象 PhotoKit 边界，支持测试注入 Fake。
///
/// 仅返回值类型（PhotoAssetContent / UIImage 数据），PHAsset 不跨边界传递。
/// 方法均为 async（真实实现经 MainActor.run 访问 @MainActor 的 PhotoKit）。
public protocol PhotoAssetExtracting: Sendable {
    /// 提取资产元数据（创建时间 + EXIF）。
    func extractMetadata(assetId: String) async throws -> PhotoAssetContent
    /// 是否已下载到本地（US-SRC-001 AC-6：isNetworkAccessAllowed=false）。
    func isLocallyAvailable(assetId: String) async -> Bool
}

/// 真实 PhotoKit 图片资产提取实现。
///
/// - EXIF 经 `requestImageDataAndOrientation` + CGImageSource 解析
/// - 下载检测：isNetworkAccessAllowed=false，nil 表示未下载（AC-6）
public struct RealPhotoAssetExtractor: PhotoAssetExtracting {

    public nonisolated init() {}

    public nonisolated func extractMetadata(assetId: String) async throws -> PhotoAssetContent {
        try await Self.fetchMetadata(assetId: assetId)
    }

    public nonisolated func isLocallyAvailable(assetId: String) async -> Bool {
        await Self.assetDownloaded(assetId)
    }

    // MARK: - @MainActor PhotoKit Helpers

    @MainActor
    private static func fetchMetadata(assetId: String) async throws -> PhotoAssetContent {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
            throw EmbedderError.assetUnavailable(assetId: assetId)
        }
        let creationDate = asset.creationDate
        var exifData: Data?
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                if let data, let source = CGImageSourceCreateWithData(data as CFData, nil) {
                    exifData = Self.extractEXIF(from: source)
                }
                continuation.resume()
            }
        }
        return PhotoAssetContent(
            assetId: assetId,
            creationDate: creationDate,
            exifMetadata: exifData
        )
    }

    @MainActor
    private static func assetDownloaded(_ assetId: String) async -> Bool {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
            return false
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data != nil)
            }
        }
    }

    /// 从 CGImageSource 提取 EXIF 字典（JSON 编码，GPS 保留原始值，展示层按 UserPolicy 决定）。
    private nonisolated static func extractEXIF(from source: CGImageSource) -> Data? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif: [String: Any] = properties.reduce(into: [:]) { result, pair in
            result[(pair.key as String)] = pair.value
        }
        guard JSONSerialization.isValidJSONObject(exif) else { return nil }
        return try? JSONSerialization.data(withJSONObject: exif)
    }
}

/// 测试用 Fake 图片资产提取器 — 注入固定元数据与本地可用性。
public actor FakePhotoAssetExtractor: PhotoAssetExtracting {

    private let metadata: PhotoAssetContent
    private let locallyAvailable: Bool

    public init(metadata: PhotoAssetContent, locallyAvailable: Bool = true) {
        self.metadata = metadata
        self.locallyAvailable = locallyAvailable
    }

    public func extractMetadata(assetId: String) async throws -> PhotoAssetContent {
        metadata
    }

    public func isLocallyAvailable(assetId: String) async -> Bool {
        locallyAvailable
    }
}
