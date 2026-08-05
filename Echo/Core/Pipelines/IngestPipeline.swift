// ==========================================
// 文件: IngestPipeline.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-004 (图片记忆摄入),
//            US-ING-005 (视频记忆摄入画面+音频双通道)
//            US-ING-001/002 (备忘录文本记忆摄入), US-ING-003 (语音备忘录转写摄入)
//            docs/02-architecture/数据流全链路技术说明文档.md §3.1 (图片摄入时序), §3.2 (视频摄入)
//            docs/02-architecture/架构设计文档.md §2.1 (Cognitive Pipeline), §3.1 (IngestPipeline)
// 任务: 2.3 - IngestPipeline：图片摄入（US-ING-004）
//        2.4 - IngestPipeline：视频摄入（US-ING-005）
//        2.5 - IngestPipeline：备忘录 + 语音转写（US-ING-001~003）
// AC 覆盖: US-ING-004 AC-1~AC-5 (图片摄入),
//          US-ING-005 AC-1 (帧采样 ≤2fps/≤20, CLIP 向量化), AC-2 (SenseVoice 转写+文本向量化),
//          AC-3 (memoryGroupId 关联), AC-4 (PHAsset 引用), AC-5 (审计 .videoIngested)
// 架构约束: AGENTS.md §4.1 (Pipeline 契约 — 纯函数、无状态、审计强制、错误分级),
//           R-006 (PrivacyCheckpoint 强制注入), R-008 (跨 Actor await),
//           AGENTS.md §4.4 (L1~L4 统一错误分级)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-09 (v1 图片), 2026-07-11 (v2 视频), 2026-07-12 (v3 文本+语音)
// ==========================================

import Foundation

// MARK: - Ingest Pipeline Error

/// IngestPipeline 统一错误类型（L1~L4 分级，AGENTS.md §4.4）
public enum IngestError: Error, LocalizedError, Sendable, Equatable {
    /// 隐私校验拒绝 — 用户未授权所需数据源
    case privacyDenied(sourceTypes: [String])
    /// 资产已被用户手动排除（US-SRC-008）
    case assetExcluded(assetId: String)
    /// ExcludedAssets 查询失败（数据库读错误，fail-closed）
    case excludedAssetsLookupFailed(underlying: Error)
    /// 嵌入生成失败 — 模型未加载或推理失败（L3 阻断）
    case embeddingFailed(underlying: Error)
    /// 元数据编码失败
    case metadataEncodingFailed(underlying: Error)
    /// 向量存储写入失败
    case vectorStoreWriteFailed(underlying: Error)
    /// 审计日志写入失败（L1 瞬态，非阻断，调用方不应 throw 此错误）
    case auditLogFailed(underlying: Error)
    /// 视频帧列表为空（US-ING-005 AC-1）
    case emptyFrames
    /// 视频帧数超过上限（US-ING-005 AC-1: 总帧数 ≤20）
    case tooManyFrames(max: Int)
    /// 音频转写失败（US-ING-005 AC-2）
    case audioTranscriptionFailed(underlying: Error)
    /// 文本输入为空（US-ING-001 AC-2：原始文本必须有效）
    case emptyText
    /// Share 分享内容类型当前不受摄入支持（图片/文件分享由 3F.5 生产摄入处理）
    case unsupportedSharedContent(kind: String)

    /// L1~L4 错误分级
    public nonisolated var errorLevel: Int {
        switch self {
        case .privacyDenied:              return 2  // L2 可恢复（用户可重新授权）
        case .assetExcluded:              return 4  // L4 数据冲突（用户操作冲突）
        case .excludedAssetsLookupFailed: return 2  // L2 可恢复（SQLite 读错误，fail-closed）
        case .embeddingFailed:            return 3  // L3 阻断（模型加载失败）
        case .metadataEncodingFailed:     return 2  // L2 可恢复（编码/序列化异常）
        case .vectorStoreWriteFailed:     return 2  // L2 可恢复（磁盘空间等）
        case .auditLogFailed:             return 1  // L1 瞬态（非阻断）
        case .emptyFrames:                return 2  // L2 可恢复（调用方传入非法参数）
        case .tooManyFrames:              return 2  // L2 可恢复（调用方传入超限帧数）
        case .audioTranscriptionFailed:               return 2  // L2 可恢复（ASR 模型未加载等）
        case .emptyText:                              return 2  // L2 可恢复（调用方传入非法参数）
        case .unsupportedSharedContent:               return 2  // L2 可恢复（调用方传入非法参数）
        }
    }

    public var errorDescription: String? {
        switch self {
        case .privacyDenied(let types):
            return "Privacy denied for source types: \(types.joined(separator: ","))"
        case .assetExcluded(let assetId):
            return "Asset excluded by user: \(assetId)"
        case .excludedAssetsLookupFailed(let error):
            return "ExcludedAssets lookup failed: \(error.localizedDescription)"
        case .embeddingFailed(let error):
            return "CLIP embedding failed: \(error.localizedDescription)"
        case .metadataEncodingFailed(let error):
            return "Metadata encoding failed: \(error.localizedDescription)"
        case .vectorStoreWriteFailed(let error):
            return "Vector store write failed: \(error.localizedDescription)"
        case .auditLogFailed(let error):
            return "Audit log write failed (non-blocking): \(error.localizedDescription)"
        case .emptyFrames:
            return "Video ingestion requires at least one frame"
        case .tooManyFrames(let max):
            return "Video ingestion frame count exceeds limit (\(max))"
        case .audioTranscriptionFailed(let error):
            return "Audio transcription failed: \(error.localizedDescription)"
        case .emptyText:
            return "Text input is empty or whitespace-only"
        case .unsupportedSharedContent(let kind):
            return "Unsupported shared content kind: \(kind)"
        }
    }

    // MARK: Equatable (manual — Error associated values are not Equatable)
    public static func == (lhs: IngestError, rhs: IngestError) -> Bool {
        switch (lhs, rhs) {
        case (.privacyDenied(let a), .privacyDenied(let b)): return a == b
        case (.assetExcluded(let a), .assetExcluded(let b)): return a == b
        case (.excludedAssetsLookupFailed, .excludedAssetsLookupFailed): return true
        case (.embeddingFailed, .embeddingFailed): return true
        case (.metadataEncodingFailed, .metadataEncodingFailed): return true
        case (.vectorStoreWriteFailed, .vectorStoreWriteFailed): return true
        case (.auditLogFailed, .auditLogFailed): return true
        case (.emptyFrames, .emptyFrames): return true
        case (.tooManyFrames(let a), .tooManyFrames(let b)): return a == b
        case (.audioTranscriptionFailed, .audioTranscriptionFailed): return true
        case (.emptyText, .emptyText): return true
        case (.unsupportedSharedContent(let a), .unsupportedSharedContent(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Ingest Pipeline

/// 记忆摄入管线 — 协调图片/视频/文本的端到端摄入流程。
///
/// ## Pipeline 契约（AGENTS.md §4.1）
/// - 纯函数性: 相同输入产生相同输出（通过依赖注入的 embedder+actor），无隐式全局依赖
/// - 无状态: Pipeline 本身不持有可变状态（仅持有对其他 Actor 的引用）
/// - 副作用隔离: 所有副作用通过 Actor 调用实现（PrivacyActor, VectorStoreActor 等）
/// - 审计强制: 每个 execute 方法入口调用 PrivacyActor.validate()（R-006）
/// - 错误分级: 所有 throws 映射到 L1~L4 统一错误矩阵（AGENTS.md §4.4）
///
/// ## 依赖注入
/// - `embedder`: 嵌入服务（CLIP 编码），生产环境使用 MobileCLIPEmbedder，测试使用 StubEmbedder
/// - `asrEngine`: 语音转写引擎（SenseVoice），生产环境使用 SenseVoiceASREngine，测试使用 StubASREngine
/// - `privacyActor`: 隐私校验 Actor（默认 .shared）
/// - `vectorStore`: 向量存储 Actor
/// - `excludedAssets`: 排除资产管理 Actor（默认 .shared）
///
/// ## 数据流（架构文档 §3.1, §3.2）
/// ```
/// Image: call → PrivacyActor.validate() → ExcludedAssets.contains()
///     → Embedder.embedImage() → VectorStore.ingest()
///     → PrivacyActor.writeAuditLog(.imageIngested)
///
/// Video: call → PrivacyActor.validate() → ExcludedAssets.contains()
///     → for each frame: Embedder.embedImage() → MemoryEntry → VectorStore.ingest()
///     → ASREngine.transcribe() → Embedder.embedText() → MemoryEntry → VectorStore.ingest()
///     → PrivacyActor.writeAuditLog(.videoIngested)
///
/// Text:  call → PrivacyActor.validate() → Embedder.embedText() → zero-pad(384→512)
///     → VectorStore.ingest() → PrivacyActor.writeAuditLog(.memoryIngested)
///
/// Voice: call → PrivacyActor.validate() → ASREngine.transcribe()
///     → Embedder.embedText() → zero-pad(384→512)
///     → VectorStore.ingest() → PrivacyActor.writeAuditLog(.voiceIngested)
/// ```
public actor IngestPipeline {

    // MARK: - Dependencies

    private let embedder: any EmbedderProtocol
    private let asrEngine: (any ASREngineProtocol)?
    private let privacyActor: PrivacyActor
    private let vectorStore: VectorStoreActor
    private let excludedAssets: ExcludedAssetsActor

    // MARK: - Initialization

    public init(
        embedder: any EmbedderProtocol,
        asrEngine: (any ASREngineProtocol)? = nil,
        privacyActor: PrivacyActor = .shared,
        vectorStore: VectorStoreActor,
        excludedAssets: ExcludedAssetsActor = .shared
    ) {
        self.embedder = embedder
        self.asrEngine = asrEngine
        self.privacyActor = privacyActor
        self.vectorStore = vectorStore
        self.excludedAssets = excludedAssets
    }

    // MARK: - Image Ingestion (US-ING-004)

    /// 摄入单张图片记忆（US-ING-004 全部 AC）。
    ///
    /// **流程**（对应架构文档 §3.1 图片摄入时序）：
    /// 1. PrivacyCheckpoint: 校验 photo 数据源授权（R-006）
    /// 2. ExcludedAssets: 检查是否被用户手动排除（US-SRC-008）
    /// 3. 视觉嵌入: 通过 embedder 生成 512d 向量（MobileCLIP-B LT；AC-3）
    /// 4. VectorStore: 写入向量 + 元数据
    /// 5. Audit: 记录 .imageIngested，privacyBlurApplied=false（AC-5）
    ///
    /// - Parameters:
    ///   - assetId: PHAsset.localIdentifier（AC-4：直接引用，不复制存储）
    ///   - exifMetadata: JSON 编码的 EXIF 元数据，nil 表示获取失败（AC-2）
    ///   - traceID: 审计追溯 ID（默认自动生成）
    /// - Returns: 摄入完成的 MemoryEntry
    /// - Throws: `IngestError` 按 L1~L4 分级
    public func ingestImage(
        assetId: String,
        exifMetadata: Data? = nil,
        traceID: String = UUID().uuidString
    ) async throws -> MemoryEntry {
        let startTime = Date()

        // Step 1: PrivacyCheckpoint (R-006)
        let checkpoint = await privacyActor.validate(
            operation: .ingest,
            traceID: traceID,
            sourceTypes: ["photo"]
        )
        guard checkpoint.isAllowed else {
            throw IngestError.privacyDenied(sourceTypes: checkpoint.sourceTypes)
        }

        // Step 2: ExcludedAssets check (US-SRC-008)
        // fail-closed: if the DB read fails, we block ingestion rather than
        // silently allowing a potentially excluded asset through (AGENTS.md §4.4)
        do {
            if try await excludedAssets.contains(assetId: assetId) {
                throw IngestError.assetExcluded(assetId: assetId)
            }
        } catch let error as IngestError {
            throw error  // re-throw assetExcluded
        } catch {
            throw IngestError.excludedAssetsLookupFailed(underlying: error)
        }

        // Step 3: CLIP embedding (AC-3)
        let embedding: [Float]
        do {
            embedding = try await embedder.embedImage(assetId: assetId)
        } catch {
            throw IngestError.embeddingFailed(underlying: error)
        }

        // Step 4: Create MemoryEntry (AC-1: privacyBlurApplied=false)
        let memory = MemoryEntry(
            assetId: assetId,
            embedding: embedding,
            sourceType: "photo",
            timestamp: Date(),
            exifMetadata: exifMetadata,
            privacyBlurApplied: false,  // AC-1: 禁止模糊处理
            traceID: traceID
        )

        // Step 5: Encode metadata + Write to VectorStore (AC-4: assetId reference)
        let metadata: Data
        do {
            metadata = try memory.encodeMetadata()
        } catch {
            throw IngestError.metadataEncodingFailed(underlying: error)
        }

        do {
            try await vectorStore.ingest(vector: embedding, id: memory.id, metadata: metadata)
        } catch {
            throw IngestError.vectorStoreWriteFailed(underlying: error)
        }

        // Step 6: Audit log (AC-5: .imageIngested, privacyBlurApplied=false)
        // Best-effort only — audit failure is L1 transient and MUST NOT block
        // a successfully completed ingestion (AGENTS.md §4.4 L1, §5.4).
        // Aligned with project-wide pattern: PrivacyActor.validate() line 392,
        // ExcludedAssetsActor lines 210/220/254/358 all use try? for audit writes.
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        try? await privacyActor.writeAuditLog(
            eventType: .imageIngested,
            traceID: traceID,
            policyVersion: checkpoint.policyVersion,
            success: true,
            sourceType: "photo",
            affectedCount: 1,
            excludedWritten: false,
            sourceLanguage: nil,
            elapsedMs: elapsedMs
        )

        return memory
    }

    // MARK: - Video Ingestion (US-ING-005)

    /// 摄入视频记忆（US-ING-005 全部 AC）— 画面关键帧 + 音频转写双通道。
    ///
    /// **流程**（对应架构文档 §3.2 视频摄入）：
    /// 1. PrivacyCheckpoint: 校验 video 数据源授权（R-006）
    /// 2. ExcludedAssets: 检查是否被用户手动排除（US-SRC-008）
    /// 3. 画面通道: 逐帧 CLIP 嵌入 → MemoryEntry(sourceType="video_frame") → VectorStore
    /// 4. 音频通道: ASREngine 转写 → embedText → MemoryEntry(sourceType="video_audio") → VectorStore
    /// 5. 关联: 所有 MemoryEntry 共享同一 memoryGroupId（AC-3）
    /// 6. Audit: 记录 .videoIngested（AC-5）
    ///
    /// - Parameters:
    ///   - assetId: PHAsset.localIdentifier（AC-4：视频原文件引用，不复制存储）
    ///   - frameAssetIds: 关键帧的 PHAsset.localIdentifier 列表（AC-1：≤20 帧）
    ///   - audioTrackAssetId: 音频轨道的 PHAsset.localIdentifier，nil 表示无音频（AC-2）
    ///   - traceID: 审计追溯 ID（默认自动生成）
    /// - Returns: 所有摄入完成的 [MemoryEntry]（帧 + 音频）
    /// - Throws: `IngestError` 按 L1~L4 分级
    public func ingestVideo(
        assetId: String,
        frameAssetIds: [String],
        audioTrackAssetId: String? = nil,
        traceID: String = UUID().uuidString
    ) async throws -> [MemoryEntry] {
        let startTime = Date()

        // AC-1: Must have at least one frame and at most 20
        guard !frameAssetIds.isEmpty else {
            throw IngestError.emptyFrames
        }
        guard frameAssetIds.count <= 20 else {
            throw IngestError.tooManyFrames(max: 20)
        }

        // Step 1: PrivacyCheckpoint (R-006) — check video source authorization
        let checkpoint = await privacyActor.validate(
            operation: .ingest,
            traceID: traceID,
            sourceTypes: ["video"]
        )
        guard checkpoint.isAllowed else {
            throw IngestError.privacyDenied(sourceTypes: checkpoint.sourceTypes)
        }

        // Step 2: ExcludedAssets check (US-SRC-008) — fail-closed
        do {
            if try await excludedAssets.contains(assetId: assetId) {
                throw IngestError.assetExcluded(assetId: assetId)
            }
        } catch let error as IngestError {
            throw error
        } catch {
            throw IngestError.excludedAssetsLookupFailed(underlying: error)
        }

        // Step 3: Generate shared memoryGroupId (AC-3)
        let groupId = UUID()
        var memories: [MemoryEntry] = []
        // R-1.3: 在 do 块外声明，供 Step 6 审计日志使用（hasAudio/audioTranscriptLength）
        var hasAudio: Bool = false
        var audioTranscriptLength: Int = 0

        // R-1.3: 帧/音频写入回滚 — Step 4+5 任一失败时清理已写入的半成品。
        // 原实现帧逐条写入后再处理音频，ASR 或音频写入失败时已写帧永久残留。
        do {
            // Step 4: Frame channel — each frame: embed → MemoryEntry → ingest (AC-1)
            for frameAssetId in frameAssetIds {
                let frameEmbedding: [Float]
                do {
                    frameEmbedding = try await embedder.embedImage(assetId: frameAssetId)
                } catch {
                    throw IngestError.embeddingFailed(underlying: error)
                }

                let frameMemory = MemoryEntry(
                    assetId: frameAssetId,           // AC-4: PHAsset reference
                    embedding: frameEmbedding,
                    sourceType: "video_frame",
                    timestamp: Date(),
                    exifMetadata: nil,               // AC-1: video frames don't carry EXIF
                    privacyBlurApplied: false,        // AC-1: no blurring
                    traceID: traceID,
                    memoryGroupId: groupId            // AC-3
                )

                let frameMetadata: Data
                do {
                    frameMetadata = try frameMemory.encodeMetadata()
                } catch {
                    throw IngestError.metadataEncodingFailed(underlying: error)
                }

                do {
                    try await vectorStore.ingest(vector: frameEmbedding, id: frameMemory.id, metadata: frameMetadata)
                } catch {
                    throw IngestError.vectorStoreWriteFailed(underlying: error)
                }

                memories.append(frameMemory)
            }

            // Step 5: Audio channel — transcribe → embedText → MemoryEntry → ingest (AC-2)
            if let audioId = audioTrackAssetId {
                if let asr = asrEngine {
                    hasAudio = true

                    let transcript: String
                    do {
                        transcript = try await asr.transcribe(audioTrackAssetId: audioId)
                    } catch {
                        throw IngestError.audioTranscriptionFailed(underlying: error)
                    }
                    audioTranscriptLength = transcript.count

                    let audioEmbedding: [Float]
                    do {
                        audioEmbedding = try await embedder.embedText(transcript)
                    } catch {
                        throw IngestError.embeddingFailed(underlying: error)
                    }

                    let audioMemory = MemoryEntry(
                        assetId: assetId,
                        embedding: audioEmbedding,
                        sourceType: "video_audio",
                        timestamp: Date(),
                        exifMetadata: nil,
                        privacyBlurApplied: false,
                        traceID: traceID,
                        memoryGroupId: groupId
                    )

                    let audioMetadata: Data
                    do {
                        audioMetadata = try audioMemory.encodeMetadata()
                    } catch {
                        throw IngestError.metadataEncodingFailed(underlying: error)
                    }

                    do {
                        try await vectorStore.ingest(vector: audioEmbedding, id: audioMemory.id, metadata: audioMetadata)
                    } catch {
                        throw IngestError.vectorStoreWriteFailed(underlying: error)
                    }

                    memories.append(audioMemory)
                }
            }
        } catch {
            // R-1.3: 任一步骤失败 → 回滚本次已写入的帧与音频记忆，再重新抛出
            for memory in memories {
                _ = await vectorStore.delete(id: memory.id)
            }
            throw error
        }

        // Step 6: Audit log (AC-5: .videoIngested, frameCount, audioTranscriptLength, hasAudio)
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        try? await privacyActor.writeAuditLog(
            eventType: .videoIngested,
            traceID: traceID,
            policyVersion: checkpoint.policyVersion,
            success: true,
            sourceType: "video",
            affectedCount: memories.count,
            excludedWritten: false,
            sourceLanguage: nil,
            elapsedMs: elapsedMs,
            frameCount: frameAssetIds.count,
            audioTranscriptLength: audioTranscriptLength,
            hasAudio: hasAudio
        )

        return memories
    }

    // MARK: - Text Ingestion (US-ING-001, US-ING-002)

    /// 摄入文本记忆（US-ING-001/002 — 备忘录文本）。
    ///
    /// **流程**：
    /// 1. Guard: 文本非空（AC-2：originalText 逐字节一致）
    /// 2. PrivacyCheckpoint: 校验 note 数据源授权（R-006）
    /// 3. Embedding: embedder.embedText(text) → 384d 向量
    /// 4. Zero-pad: 384d → 512d（策略 A，Phase 2 Qwen3 升级后移除）
    /// 5. VectorStore: 写入 512d 向量 + 元数据（含 originalText）
    /// 6. Audit: 记录 .memoryIngested，sourceLanguage + traceID（AC-5：无原文）
    ///
    /// - Parameters:
    ///   - text: 原始文本（AC-2：逐字节一致）
    ///   - sourceLanguage: "zh-Hans" 或 "en-US"（AC-1）
    ///   - sourceId: 数据源标识符（AC-4：原始备忘录引用）
    ///   - traceID: 审计追溯 ID
    /// - Returns: 摄入完成的 MemoryEntry
    /// - Throws: `IngestError` 按 L1~L4 分级
    public func ingestText(
        text: String,
        sourceLanguage: String,
        sourceId: String,
        traceID: String = UUID().uuidString
    ) async throws -> MemoryEntry {
        let startTime = Date()

        // AC-2: Guard against empty text (whitespace-only is also empty)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IngestError.emptyText
        }

        // Step 1: PrivacyCheckpoint (R-006)
        let checkpoint = await privacyActor.validate(
            operation: .ingest,
            traceID: traceID,
            sourceTypes: ["note"]
        )
        guard checkpoint.isAllowed else {
            throw IngestError.privacyDenied(sourceTypes: checkpoint.sourceTypes)
        }

        // Step 2: Text embedding (AC-3: multilingual-e5-small → 384d)
        let rawEmbedding: [Float]
        do {
            rawEmbedding = try await embedder.embedText(text)
        } catch {
            throw IngestError.embeddingFailed(underlying: error)
        }

        // Step 3: Zero-pad 384d → 512d for unified VectorStore (Strategy A)
        let paddedEmbedding: [Float]
        if rawEmbedding.count < 512 {
            paddedEmbedding = rawEmbedding + Array(repeating: 0.0, count: 512 - rawEmbedding.count)
        } else {
            paddedEmbedding = rawEmbedding
        }

        // Step 4: Create MemoryEntry (AC-2: originalText preserved, AC-4: sourceId as asset reference)
        let memory = MemoryEntry(
            assetId: sourceId,
            embedding: paddedEmbedding,
            sourceType: "text",
            timestamp: Date(),
            exifMetadata: nil,
            privacyBlurApplied: false,
            traceID: traceID,
            originalText: text
        )

        // Step 5: Write to VectorStore
        let metadata: Data
        do {
            metadata = try memory.encodeMetadata()
        } catch {
            throw IngestError.metadataEncodingFailed(underlying: error)
        }

        do {
            try await vectorStore.ingest(vector: paddedEmbedding, id: memory.id, metadata: metadata)
        } catch {
            throw IngestError.vectorStoreWriteFailed(underlying: error)
        }

        // Step 6: Audit log (AC-5: .memoryIngested, sourceLanguage, traceID, NO original text)
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        try? await privacyActor.writeAuditLog(
            eventType: .memoryIngested,
            traceID: traceID,
            policyVersion: checkpoint.policyVersion,
            success: true,
            sourceType: "text",
            affectedCount: 1,
            excludedWritten: false,
            sourceLanguage: sourceLanguage,
            elapsedMs: elapsedMs
        )

        return memory
    }

    // MARK: - Voice Ingestion (US-ING-003)

    /// 摄入语音转写记忆（US-ING-003 — 语音备忘录转写）。
    ///
    /// **流程**：
    /// 1. PrivacyCheckpoint: 校验 voice 数据源授权（R-006）
    /// 2. Transcribe: ASREngine.transcribe() → 文本（AC-1）
    /// 3. Embedding: embedder.embedText(transcript) → 384d
    /// 4. Zero-pad: 384d → 512d
    /// 5. VectorStore: 写入向量 + 元数据（含转写文本）
    /// 6. Audit: 记录 .voiceIngested（AC-5）
    /// 7. AC-3: 原始音频不持久化，仅保留转写文本
    ///
    /// - Parameters:
    ///   - audioAssetId: 语音备忘录的 PHAsset.localIdentifier（原始文件仅引用，不持久化）
    ///   - sourceLanguage: 转写文本的语言（nil 则由 Swift NLTagger 自动检测）
    ///   - transcriptConfidence: SFSpeechRecognizer 转写置信度 0~1，< 0.7 标记 uncertain（AC-4）
    ///   - traceID: 审计追溯 ID
    /// - Returns: 摄入完成的 MemoryEntry
    /// - Throws: `IngestError` 按 L1~L4 分级
    public func ingestVoice(
        audioAssetId: String,
        sourceLanguage: String? = nil,
        transcriptConfidence: Float? = nil,
        traceID: String = UUID().uuidString
    ) async throws -> MemoryEntry {
        let startTime = Date()

        // Step 1: PrivacyCheckpoint (R-006)
        let checkpoint = await privacyActor.validate(
            operation: .ingest,
            traceID: traceID,
            sourceTypes: ["voice"]
        )
        guard checkpoint.isAllowed else {
            throw IngestError.privacyDenied(sourceTypes: checkpoint.sourceTypes)
        }

        // Step 2: Transcribe audio (AC-1: SenseVoice offline transcription)
        guard let asr = asrEngine else {
            throw IngestError.audioTranscriptionFailed(
                underlying: ASREngineError.modelNotLoaded
            )
        }

        let transcript: String
        do {
            transcript = try await asr.transcribe(audioTrackAssetId: audioAssetId)
        } catch {
            throw IngestError.audioTranscriptionFailed(underlying: error)
        }

        // Step 3: Detect language (use NLTagger → only zh-Hans/en-US per AGENTS.md §6.2)
        let detectedLanguage = sourceLanguage ?? "zh-Hans"
        // TODO: Integrate NLTagger language detection:
        //   import NaturalLanguage
        //   NLTagger(tagSchemes: [.language]).string = transcript
        //   let lang = tagger.tag(at: transcript.startIndex, unit: .document, scheme: .language)?.rawValue
        //   Map to zh-Hans/en-US (fallback zh-Hans)

        // Step 4: Text embedding (AC-3: multilingual-e5-small → 384d)
        let rawEmbedding: [Float]
        do {
            rawEmbedding = try await embedder.embedText(transcript)
        } catch {
            throw IngestError.embeddingFailed(underlying: error)
        }

        // Step 5: Zero-pad 384d → 512d
        let paddedEmbedding: [Float]
        if rawEmbedding.count < 512 {
            paddedEmbedding = rawEmbedding + Array(repeating: 0.0, count: 512 - rawEmbedding.count)
        } else {
            paddedEmbedding = rawEmbedding
        }

        // Step 6: Create MemoryEntry (AC-3: audio NOT persisted, only transcription kept)
        // AC-4: transcriptConfidence < 0.7 → marked .uncertainTranscript via low confidence value
        let confidence = transcriptConfidence ?? 1.0
        let memory = MemoryEntry(
            assetId: audioAssetId,
            embedding: paddedEmbedding,
            sourceType: "voice",
            timestamp: Date(),
            exifMetadata: nil,
            privacyBlurApplied: false,
            traceID: traceID,
            originalText: transcript,
            transcriptConfidence: confidence
        )

        // Step 7: Write to VectorStore
        let metadata: Data
        do {
            metadata = try memory.encodeMetadata()
        } catch {
            throw IngestError.metadataEncodingFailed(underlying: error)
        }

        do {
            try await vectorStore.ingest(vector: paddedEmbedding, id: memory.id, metadata: metadata)
        } catch {
            throw IngestError.vectorStoreWriteFailed(underlying: error)
        }

        // Step 8: Audit log (AC-5: .voiceIngested, transcriptModelVersion)
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        try? await privacyActor.writeAuditLog(
            eventType: .voiceIngested,
            traceID: traceID,
            policyVersion: checkpoint.policyVersion,
            success: true,
            sourceType: "voice",
            affectedCount: 1,
            excludedWritten: false,
            sourceLanguage: detectedLanguage,
            elapsedMs: elapsedMs
        )

        return memory
    }

    // MARK: - Shared Import Ingestion (3F.2, ADR-008 §决策-2/3)

    /// 摄入一封 App Group 分享信封（US-SRC-001/003 — share-only 用户中介）。
    ///
    /// **流程**（对应 ADR-008 §决策-2/3）：
    /// 1. PrivacyCheckpoint：按信封来源类型校验授权（note/voice/thirdParty）
    /// 2. ExcludedAssets：按 `dedupeKey` 校验（fail-closed，US-SRC-008 AC-4）
    /// 3. 内容分支：
    ///    - text/url → `embedText`（备忘录/第三方文本）
    ///    - audio → `transcribe` → `embedText`（语音备忘录转写）
    ///    - image/file → 抛出 `.unsupportedSharedContent`（3F.5 生产摄入接管）
    /// 4. 审计 `.shareExtensionImported`（US-SRC-003 AC-4：appBundleId + contentType，hash-only）
    ///
    /// - Parameter envelope: App Group 分享信封
    /// - Returns: 摄入完成的 MemoryEntry（assetId = envelope.dedupeKey）
    /// - Throws: `IngestError` 按 L1~L4 分级
    public func ingestShared(
        _ envelope: SharedImportEnvelope,
        traceID: String = UUID().uuidString
    ) async throws -> MemoryEntry {
        let startTime = Date()

        // Step 1: PrivacyCheckpoint (R-006) — 按信封来源类型校验
        let sourceTypes = [envelope.sourceType.rawValue]
        let checkpoint = await privacyActor.validate(
            operation: .ingest,
            traceID: traceID,
            sourceTypes: sourceTypes
        )
        guard checkpoint.isAllowed else {
            throw IngestError.privacyDenied(sourceTypes: checkpoint.sourceTypes)
        }

        // Step 2: ExcludedAssets check (US-SRC-008 AC-4) — fail-closed
        do {
            if try await excludedAssets.contains(assetId: envelope.dedupeKey) {
                throw IngestError.assetExcluded(assetId: envelope.dedupeKey)
            }
        } catch let error as IngestError {
            throw error
        } catch {
            throw IngestError.excludedAssetsLookupFailed(underlying: error)
        }

        // Step 3: 内容分支
        switch envelope.contentKind {
        case .text, .url:
            return try await ingestSharedText(
                envelope, checkpointPolicyVersion: checkpoint.policyVersion, startTime: startTime, traceID: traceID
            )
        case .audio:
            return try await ingestSharedAudio(
                envelope, checkpointPolicyVersion: checkpoint.policyVersion, startTime: startTime, traceID: traceID
            )
        case .image, .file:
            // 图片/文件分享的提取与推理由 3F.5 生产摄入接管（本任务聚焦队列与来源边界）
            throw IngestError.unsupportedSharedContent(kind: envelope.contentKind.rawValue)
        }
    }

    /// 队列排空：恢复中断 → 逐个 开始→摄入→完成，恰好一次处理（ADR-008 §决策-3）。
    ///
    /// - Parameter queue: App Group 分享队列
    /// - Returns: 处理/失败/恢复计数
    public func drainSharedImports(
        from queue: SharedImportQueueActor,
        traceID: String = UUID().uuidString
    ) async throws -> SharedImportDrainResult {
        let recovered = try await queue.recoverInterrupted()
        let envelopes = try await queue.pendingEnvelopes()
        var processed = 0
        var failed = 0
        for envelope in envelopes {
            guard let started = try await queue.beginProcessing(for: envelope.dedupeKey) else { continue }
            do {
                _ = try await ingestShared(started, traceID: traceID)
                try await queue.finishProcessing(for: envelope.dedupeKey)
                processed += 1
            } catch {
                try? await queue.rollbackProcessing(for: envelope.dedupeKey)
                failed += 1
            }
        }
        return SharedImportDrainResult(
            processed: processed,
            failed: failed,
            recovered: recovered
        )
    }

    // MARK: - Shared Import Helpers

    private func ingestSharedText(
        _ envelope: SharedImportEnvelope,
        checkpointPolicyVersion: Int,
        startTime: Date,
        traceID: String
    ) async throws -> MemoryEntry {
        let trimmed = envelope.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IngestError.emptyText }

        let rawEmbedding: [Float]
        do {
            rawEmbedding = try await embedder.embedText(envelope.payload)
        } catch {
            throw IngestError.embeddingFailed(underlying: error)
        }
        let padded = zeroPad(rawEmbedding)
        let memory = MemoryEntry(
            assetId: envelope.dedupeKey,
            embedding: padded,
            sourceType: envelope.sourceType.rawValue,
            timestamp: envelope.createdAt,
            exifMetadata: nil,
            privacyBlurApplied: false,
            traceID: traceID,
            originalText: envelope.payload
        )
        try await writeSharedMemory(memory, embedding: padded)
        await writeShareExtensionAudit(
            envelope,
            policyVersion: checkpointPolicyVersion,
            startTime: startTime,
            traceID: traceID
        )
        return memory
    }

    private func ingestSharedAudio(
        _ envelope: SharedImportEnvelope,
        checkpointPolicyVersion: Int,
        startTime: Date,
        traceID: String
    ) async throws -> MemoryEntry {
        guard let asr = asrEngine else {
            throw IngestError.audioTranscriptionFailed(underlying: ASREngineError.modelNotLoaded)
        }
        let transcript: String
        do {
            transcript = try await asr.transcribe(audioTrackAssetId: envelope.payload)
        } catch {
            throw IngestError.audioTranscriptionFailed(underlying: error)
        }
        let rawEmbedding: [Float]
        do {
            rawEmbedding = try await embedder.embedText(transcript)
        } catch {
            throw IngestError.embeddingFailed(underlying: error)
        }
        let padded = zeroPad(rawEmbedding)
        let memory = MemoryEntry(
            assetId: envelope.dedupeKey,
            embedding: padded,
            sourceType: envelope.sourceType.rawValue,
            timestamp: envelope.createdAt,
            exifMetadata: nil,
            privacyBlurApplied: false,
            traceID: traceID,
            originalText: transcript
        )
        try await writeSharedMemory(memory, embedding: padded)
        await writeShareExtensionAudit(
            envelope,
            policyVersion: checkpointPolicyVersion,
            startTime: startTime,
            traceID: traceID
        )
        return memory
    }

    private func writeSharedMemory(_ memory: MemoryEntry, embedding: [Float]) async throws {
        let metadata: Data
        do {
            metadata = try memory.encodeMetadata()
        } catch {
            throw IngestError.metadataEncodingFailed(underlying: error)
        }
        do {
            try await vectorStore.ingest(vector: embedding, id: memory.id, metadata: metadata)
        } catch {
            throw IngestError.vectorStoreWriteFailed(underlying: error)
        }
    }

    /// 审计 `.shareExtensionImported`（US-SRC-003 AC-4：appBundleId + contentType，hash-only）。
    private func writeShareExtensionAudit(
        _ envelope: SharedImportEnvelope,
        policyVersion: Int,
        startTime: Date,
        traceID: String
    ) async {
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        // AGENTS.md §5.4 hash-only：content 在写入前被哈希，不含原文
        try? await privacyActor.writeAuditLog(
            eventType: .shareExtensionImported,
            traceID: traceID,
            policyVersion: policyVersion,
            success: true,
            sourceType: envelope.sourceType.rawValue,
            affectedCount: 1,
            excludedWritten: false,
            elapsedMs: elapsedMs,
            content: "appBundleId=\(envelope.sourceAppBundleId)|contentType=\(envelope.contentKind.rawValue)"
        )
    }

    private func zeroPad(_ embedding: [Float]) -> [Float] {
        if embedding.count < 512 {
            return embedding + Array(repeating: 0.0, count: 512 - embedding.count)
        }
        return embedding
    }
}

// MARK: - Shared Import Drain Result

/// 队列排空结果（ADR-008 §决策-3 恰好一次处理计数）
public struct SharedImportDrainResult: Sendable, Equatable {
    public nonisolated let processed: Int
    public nonisolated let failed: Int
    public nonisolated let recovered: Int

    public nonisolated init(processed: Int = 0, failed: Int = 0, recovered: Int = 0) {
        self.processed = processed
        self.failed = failed
        self.recovered = recovered
    }
}
