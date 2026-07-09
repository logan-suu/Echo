// ==========================================
// 文件: IngestPipeline.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-004 (图片记忆摄入)
//            docs/02-architecture/数据流全链路技术说明文档.md §3.1 (图片摄入时序)
//            docs/02-architecture/架构设计文档.md §2.1 (Cognitive Pipeline), §3.1 (IngestPipeline)
// 任务: 2.3 - IngestPipeline：图片摄入（US-ING-004）
// AC 覆盖: US-ING-004 AC-1 (禁止模糊处理), AC-2 (EXIF 元数据保留),
//          AC-3 (CLIP 向量生成), AC-4 (PHAsset 引用), AC-5 (审计 .imageIngested)
// 架构约束: AGENTS.md §4.1 (Pipeline 契约 — 纯函数、无状态、审计强制、错误分级),
//           R-006 (PrivacyCheckpoint 强制注入), R-008 (跨 Actor await),
//           AGENTS.md §4.4 (L1~L4 统一错误分级)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-09
// ==========================================

import Foundation

// MARK: - Ingest Pipeline Error

/// IngestPipeline 统一错误类型（L1~L4 分级，AGENTS.md §4.4）
public enum IngestError: Error, LocalizedError, Sendable {
    /// 隐私校验拒绝 — 用户未授权 photo 数据源
    case privacyDenied(sourceTypes: [String])
    /// 资产已被用户手动排除（US-SRC-008）
    case assetExcluded(assetId: String)
    /// 嵌入生成失败 — 模型未加载或推理失败（L3 阻断）
    case embeddingFailed(underlying: Error)
    /// 向量存储写入失败
    case vectorStoreWriteFailed(underlying: Error)
    /// 审计日志写入失败（非阻断）
    case auditLogFailed(underlying: Error)

    /// L1~L4 错误分级
    public nonisolated var errorLevel: Int {
        switch self {
        case .privacyDenied:           return 2  // L2 可恢复（用户可重新授权）
        case .assetExcluded:           return 4  // L4 数据冲突（用户操作冲突）
        case .embeddingFailed:         return 3  // L3 阻断（模型加载失败）
        case .vectorStoreWriteFailed:  return 2  // L2 可恢复（磁盘空间等）
        case .auditLogFailed:          return 1  // L1 瞬态（非阻断）
        }
    }

    public var errorDescription: String? {
        switch self {
        case .privacyDenied(let types):
            return "Privacy denied for source types: \(types.joined(separator: ","))"
        case .assetExcluded(let assetId):
            return "Asset excluded by user: \(assetId)"
        case .embeddingFailed(let error):
            return "CLIP embedding failed: \(error.localizedDescription)"
        case .vectorStoreWriteFailed(let error):
            return "Vector store write failed: \(error.localizedDescription)"
        case .auditLogFailed(let error):
            return "Audit log write failed: \(error.localizedDescription)"
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
/// - `privacyActor`: 隐私校验 Actor（默认 .shared）
/// - `vectorStore`: 向量存储 Actor
/// - `excludedAssets`: 排除资产管理 Actor（默认 .shared）
///
/// ## 数据流（架构文档 §3.1）
/// ```
/// call → PrivacyActor.validate() → ExcludedAssetsActor.contains()
///     → Embedder.embedImage() → VectorStoreActor.ingest()
///     → PrivacyActor.writeAuditLog(.imageIngested)
/// ```
public actor IngestPipeline {

    // MARK: - Dependencies

    private let embedder: any EmbedderProtocol
    private let privacyActor: PrivacyActor
    private let vectorStore: VectorStoreActor
    private let excludedAssets: ExcludedAssetsActor

    // MARK: - Initialization

    public init(
        embedder: any EmbedderProtocol,
        privacyActor: PrivacyActor = .shared,
        vectorStore: VectorStoreActor,
        excludedAssets: ExcludedAssetsActor = .shared
    ) {
        self.embedder = embedder
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
    /// 3. CLIP 嵌入: 通过 embedder 生成 768 维向量（AC-3）
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
        if (try? await excludedAssets.contains(assetId: assetId)) == true {
            throw IngestError.assetExcluded(assetId: assetId)
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

        // Step 5: Write to VectorStore (with metadata, AC-4: assetId reference)
        let metadata: Data
        do {
            metadata = try await memory.encodeMetadata()
        } catch {
            throw IngestError.vectorStoreWriteFailed(underlying: error)
        }

        do {
            try await vectorStore.ingest(vector: embedding, id: memory.id, metadata: metadata)
        } catch {
            throw IngestError.vectorStoreWriteFailed(underlying: error)
        }

        // Step 6: Audit log (AC-5: .imageIngested, privacyBlurApplied=false)
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        do {
            try await privacyActor.writeAuditLog(
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
        } catch {
            // AC-5 requires audit record; audit failure is L1 (non-blocking for ingestion)
            // but we log it for observability
            throw IngestError.auditLogFailed(underlying: error)
        }

        return memory
    }
}
