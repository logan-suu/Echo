// ==========================================
// 文件: VideoAssetExtractor.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-005 (视频摄入)
//            docs/02-architecture/数据流全链路技术说明文档.md §3.2 (视频摄入)
// 任务: 3F.5 - Production ingestion
// AC 覆盖: US-ING-005 AC-1 (≤2fps, 总帧数 ≤20), AC-4 (PHAsset 引用，不复制存储)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (零网络), R-007 (禁止 unchecked Sendable)
// PR#57 review fix: @preconcurrency import AVFoundation（loadTracks 返回非 Sendable [AVAssetTrack]）
// PR#57 CodeRabbit fix: CR-6 长视频按时长均布采样（≤20 帧全时长覆盖）+ 跳过编码失败帧而非中止;
//                       CR-24 Fake 提取器 #if DEBUG 包裹
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
//       AVFoundation/PhotoKit SDK 标注 @MainActor，真实实现经 MainActor.run 访问
// 生成时间: 2026-08-10
// ==========================================

import Foundation
@preconcurrency import Photos
@preconcurrency import AVFoundation
import UIKit

/// 视频资产提取结果 — 供生产摄入管线消费（不跨边界传递 PHAsset/AVAsset）。
public struct VideoAssetContent: Sendable, Equatable {
    public nonisolated let assetId: String
    /// 原始创建时间
    public nonisolated let creationDate: Date?
    /// 关键帧 UIImage 数据（≤2fps，总帧数 ≤20，AC-1）
    public nonisolated let frameImages: [Data]
    /// 是否有音频轨道
    public nonisolated let hasAudio: Bool

    public nonisolated init(
        assetId: String,
        creationDate: Date?,
        frameImages: [Data],
        hasAudio: Bool
    ) {
        self.assetId = assetId
        self.creationDate = creationDate
        self.frameImages = frameImages
        self.hasAudio = hasAudio
    }
}

/// 视频资产提取协议 — 抽象 PhotoKit/AVFoundation 边界，支持测试注入 Fake。
public protocol VideoAssetExtracting: Sendable {
    /// 提取视频关键帧（≤2fps，≤20 帧）与音频轨道存在性。
    func extractFrames(assetId: String) async throws -> VideoAssetContent
    /// 导出音频轨道为本地文件 URL（无音频返回 nil）。
    func extractAudioTrack(assetId: String) async throws -> URL?
}

/// 真实 AVFoundation/PhotoKit 视频资产提取实现。
///
/// - 关键帧：AVAssetImageGenerator，每秒 ≤2 帧、总帧数 ≤20（AC-1）
/// - 音频轨道存在性：AVAsset.loadTracks(.audio)
public struct RealVideoAssetExtractor: VideoAssetExtracting {

    public nonisolated init() {}

    public nonisolated func extractFrames(assetId: String) async throws -> VideoAssetContent {
        try await Self.fetchFrames(assetId: assetId)
    }

    public nonisolated func extractAudioTrack(assetId: String) async throws -> URL? {
        try await Self.fetchAudioTrackURL(assetId: assetId)
    }

    // MARK: - @MainActor Helpers

    @MainActor
    private static func fetchFrames(assetId: String) async throws -> VideoAssetContent {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
            throw EmbedderError.assetUnavailable(assetId: assetId)
        }
        let creationDate = asset.creationDate

        let videoURL = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: nil) { avAsset, _, _ in
                if let avAsset = avAsset as? AVURLAsset {
                    continuation.resume(returning: avAsset.url)
                } else {
                    continuation.resume(throwing: EmbedderError.assetUnavailable(assetId: assetId))
                }
            }
        }

        let avAsset = AVURLAsset(url: videoURL)
        let duration = try await avAsset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return VideoAssetContent(assetId: assetId, creationDate: creationDate, frameImages: [], hasAudio: false)
        }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)

        // AC-1: 每秒 ≤2 帧且总帧数 ≤20 —— 长视频按时长均匀采样，避免帧全部集中在前 10 秒（CR-6）
        let fps: Double = 2.0
        let maxFrames = 20
        let interval = max(1.0 / fps, durationSeconds / Double(maxFrames))
        var sampleTimes: [CMTime] = []
        var t: Double = 0
        while t < durationSeconds, sampleTimes.count < maxFrames {
            sampleTimes.append(CMTime(seconds: t, preferredTimescale: 600))
            t += interval
        }

        var frameData: [Data] = []
        for time in sampleTimes {
            do {
                let cgImage = try await generator.image(at: time).image
                let image = UIImage(cgImage: cgImage)
                // CR-6: jpeg 编码失败时跳过该帧，不 append 空 Data（避免整段摄入中止）
                if let data = image.jpegData(compressionQuality: 0.8) {
                    frameData.append(data)
                }
            } catch {
                continue
            }
        }

        let hasAudio = try await !avAsset.loadTracks(withMediaType: .audio).isEmpty
        return VideoAssetContent(
            assetId: assetId,
            creationDate: creationDate,
            frameImages: frameData,
            hasAudio: hasAudio
        )
    }

    @MainActor
    private static func fetchAudioTrackURL(assetId: String) async throws -> URL? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
            return nil
        }
        let videoURL: URL? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: nil) { avAsset, _, _ in
                if let avAsset = avAsset as? AVURLAsset {
                    continuation.resume(returning: avAsset.url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let videoURL else { return nil }
        let avAsset = AVURLAsset(url: videoURL)
        let tracks = try await avAsset.loadTracks(withMediaType: AVMediaType.audio)
        guard !tracks.isEmpty else { return nil }
        return videoURL
    }
}

#if DEBUG
/// 测试用 Fake 视频资产提取器 — 注入固定帧与音频存在性。
public actor FakeVideoAssetExtractor: VideoAssetExtracting {

    private let content: VideoAssetContent
    private let audioURL: URL?

    public init(content: VideoAssetContent, audioURL: URL? = nil) {
        self.content = content
        self.audioURL = audioURL
    }

    public func extractFrames(assetId: String) async throws -> VideoAssetContent {
        content
    }

    public func extractAudioTrack(assetId: String) async throws -> URL? {
        audioURL
    }
}
#endif
