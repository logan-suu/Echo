// ==========================================
// 文件: PhotoAssetExtractor.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-004 (图片摄入)
//            docs/02-architecture/数据流全链路技术说明文档.md §3.1 (图片摄入时序)
//            docs/decisions/ADR-008-source-import-boundaries.md §决策-1 (PhotoKit 授权边界)
// 任务: 3F.5 - Production ingestion
// AC 覆盖: US-ING-004 AC-2 (EXIF 元数据完整保留), AC-4 (PHAsset 引用，不复制存储),
//          US-SRC-001 AC-6 (仅处理已下载本地资源)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (零网络), R-007 (禁止 unchecked Sendable)
// PR#57 CodeRabbit fix: CR-23 EXIF 叶值递归 sanitize（Date→ISO8601/Data→base64，避免整组 EXIF 丢弃）;
//                       CR-24 Fake 提取器 #if DEBUG 包裹
// PR#57 CodeRabbit fix (round 2): N-4 jsonSafe 显式保留 String/NSNumber/NSNull 标量叶值
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
    /// 提取原始图像数据（WP5 OCR 摄入用）——协议扩展提供默认实现返回 nil，
    /// 未实现提取的资产跳过 OCR；真实实现经 PhotoKit requestImageDataAndOrientation。
    func extractImageData(assetId: String) async throws -> Data?
}

/// 真实 PhotoKit 图片资产提取实现。
///
/// - EXIF 经 `requestImageDataAndOrientation` + CGImageSource 解析
/// - 下载检测：isNetworkAccessAllowed=false，nil 表示未下载（AC-6）
public struct RealPhotoAssetExtractor: PhotoAssetExtracting {

    public nonisolated init() {}

    public nonisolated func extractMetadata(assetId: String) async throws -> PhotoAssetContent {
        guard let content = Self.fetchMetadata(assetId: assetId) else {
            throw EmbedderError.assetUnavailable(assetId: assetId)
        }
        return content
    }

    public nonisolated func isLocallyAvailable(assetId: String) async -> Bool {
        Self.assetDownloaded(assetId)
    }

    public nonisolated func extractImageData(assetId: String) async throws -> Data? {
        Self.fetchImageData(assetId: assetId)
    }

    // MARK: - @MainActor PhotoKit Helpers

    // WP7: 同步提取（isSynchronous=true）——后台线程同步回调，杜绝 continuation 挂起
    // （模拟器实证：异步回调可能永不触发导致摄入任务 0% 卡死）
    private nonisolated static func fetchMetadata(assetId: String) -> PhotoAssetContent? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
            return nil
        }
        let creationDate = asset.creationDate
        var exifData: Data?
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = true
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            if let data, let source = CGImageSourceCreateWithData(data as CFData, nil) {
                exifData = Self.extractEXIF(from: source)
            }
        }
        return PhotoAssetContent(
            assetId: assetId,
            creationDate: creationDate,
            exifMetadata: exifData
        )
    }

    // WP7: 同步化（同 fetchMetadata）
    private nonisolated static func assetDownloaded(_ assetId: String) -> Bool {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
            return false
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.isSynchronous = true
        var downloaded = false
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            downloaded = (data != nil)
        }
        return downloaded
    }

    /// 从 CGImageSource 提取 EXIF 字典（JSON 编码，GPS 保留原始值，展示层按 UserPolicy 决定）。
    private nonisolated static func extractEXIF(from source: CGImageSource) -> Data? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif: [String: Any] = properties.reduce(into: [:]) { result, pair in
            let key = pair.key as String
            if let safe = Self.jsonSafe(pair.value) {
                result[key] = safe
            }
        }
        guard JSONSerialization.isValidJSONObject(exif) else { return nil }
        return try? JSONSerialization.data(withJSONObject: exif)
    }

    /// 递归清洗 EXIF 叶值：Date→ISO8601、Data→base64，其它不可序列化叶值丢弃，
    /// 避免单个不支持的值丢弃整组 EXIF（CR-23，US-ING-004 AC-2）。internal 供测试验证标量保留（N-4）。
    nonisolated static func jsonSafe(_ value: Any) -> Any? {
        if let date = value as? Date {
            return ISO8601DateFormatter().string(from: date)
        }
        if let data = value as? Data {
            return data.base64EncodedString()
        }
        if let dict = value as? [String: Any] {
            return dict.compactMapValues { jsonSafe($0) }
        }
        if let array = value as? [Any] {
            return array.compactMap { jsonSafe($0) }
        }
        // N-4: JSON 标量叶值（String/NSNumber/Bool/NSNull）须显式保留——
        // isValidJSONObject 对标量返回 false，仅检查它会丢弃全部标量 EXIF 字段。
        if value is String || value is NSNumber || value is NSNull {
            return value
        }
        if JSONSerialization.isValidJSONObject(value) {
            return value
        }
        return nil
    }
}

#if DEBUG
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
#endif

// MARK: - WP5: OCR 图像数据提取（协议扩展默认实现）

extension PhotoAssetExtracting {
    /// 默认实现返回 nil——既有 conformer（含测试 stub）零改动；
    /// 真实提取器覆盖为 PhotoKit 数据。
    public func extractImageData(assetId: String) async throws -> Data? { nil }
}

extension RealPhotoAssetExtractor {
    // WP7: 同步提取（isSynchronous=true）——杜绝 continuation 挂起
    private nonisolated static func fetchImageData(assetId: String) -> Data? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = true
        var result: Data?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            result = data
        }
        return result
    }
}
