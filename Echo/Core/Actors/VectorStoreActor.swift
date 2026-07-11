// ==========================================
// 文件: VectorStoreActor.swift
// 对应规格: docs/02-architecture/技术选型文档.md §4 (端侧向量数据库)
//            docs/02-architecture/架构设计文档.md §4.2 (Actor 隔离), §4.3 (数据竞争防护)
// 任务: 1.3 - 集成向量数据库，封装 VectorStoreActor
// 架构约束: AGENTS.md §4.2 (Actor 隔离契约), R-007 (禁止 @unchecked Sendable),
//            R-008 (跨 Actor 调用必须 await)
// 技术选型: ProximaKit 1.7.0 (纯 Swift HNSW + 余弦相似度, 替代 LanceDB Mobile)
// 生成时间: 2026-07-04
// ==========================================

import Foundation
import ProximaKit

// MARK: - Actor

/// 向量存储 Actor — 封装 ProximaKit HNSW 索引，提供线程安全的向量摄入、检索、删除与持久化。
///
/// ## Actor 隔离契约 (AGENTS.md §4.2)
/// - 可变状态封装: 所有 ProximaKit HNSWIndex 操作封装在 Actor 中
/// - 串行执行: 同一 Actor 的操作串行执行，无数据竞争
/// - 仅值类型传递: 跨 Actor 传递参数均为 Sendable 值类型
/// - 读取操作（检索）可并发，写入操作通过 Actor 串行化
///
/// ## TODO (Phase 2): Pipeline 集成
/// - PrivacyCheckpoint: 所有方法入口需调用 `PrivacyActor.shared.validate()`
/// - ProgressActor: 长任务（如 batchIngest 大规模数据）需报告进度
/// - TaskQueueActor: 大规模写入任务需入队串行执行
public actor VectorStoreActor {

    // MARK: - Properties

    private let index: HNSWIndex

    /// 向量维度（只读，非隔离属性）
    public nonisolated var dimension: Int {
        index.dimension
    }

    // MARK: - Initialization

    /// 创建一个新的内存向量存储。
    ///
    /// - Parameter dimension: 向量维度（默认 512，匹配 MobileCLIP-B LT 512d 视觉向量；文本 384d 需零填充至 512d 后写入）
    public init(dimension: Int = 512) {
        // 使用余弦相似度作为距离度量，对齐架构文档中的检索公式
        self.index = HNSWIndex(dimension: dimension, metric: CosineDistance())
    }

    // MARK: - Private Init (for load)

    private init(index: HNSWIndex) {
        self.index = index
    }

    // MARK: - Write Operations (Actor-isolated)

    /// 摄入单条向量及其元数据。
    ///
    /// - Parameters:
    ///   - vector: 浮点向量（维度必须匹配 `dimension`）
    ///   - id: 唯一标识符（重复 ID 会替换已有向量）
    ///   - metadata: 可选元数据（通常为 JSON 编码的结构体）
    /// - Throws: `VectorStoreError.dimensionMismatch` 若向量维度不匹配
    public func ingest(vector: [Float], id: UUID, metadata: Data? = nil) async throws {
        guard vector.count == dimension else {
            throw VectorStoreError.dimensionMismatch(expected: dimension, got: vector.count)
        }
        try await index.add(Vector(vector), id: id, metadata: metadata)
    }

    /// 批量摄入向量。
    ///
    /// 先校验所有向量维度，再逐条写入——避免部分写入成功、部分失败的不一致状态。
    ///
    /// - Parameter entries: 向量、ID、元数据三元组数组
    /// - Throws: `VectorStoreError.dimensionMismatch` 若任一向量维度不匹配（在写入前检测，已写入数据不受影响）
    public func batchIngest(_ entries: [(vector: [Float], id: UUID, metadata: Data?)]) async throws {
        // Phase 1: pre-validate all dimensions before any write
        for entry in entries {
            guard entry.vector.count == dimension else {
                throw VectorStoreError.dimensionMismatch(expected: dimension, got: entry.vector.count)
            }
        }
        // Phase 2: all-clear — write sequentially
        for entry in entries {
            try await index.add(Vector(entry.vector), id: entry.id, metadata: entry.metadata)
        }
    }

    /// 删除指定 ID 的向量。
    ///
    /// - Parameter id: 要删除的向量 ID
    /// - Returns: `true` 若 ID 存在并被删除，`false` 若 ID 不存在
    @discardableResult
    public func delete(id: UUID) async -> Bool {
        await index.remove(id: id)
    }

    // MARK: - Read Operations

    /// 检索与查询向量最相似的 k 个近邻。
    ///
    /// - Parameters:
    ///   - query: 查询向量
    ///   - k: 返回结果数量
    ///   - filter: 可选过滤闭包（在图遍历期间应用，比后过滤更高效）
    /// - Returns: 按距离升序排列的搜索结果（余弦距离越小越相似）
    public func search(
        query: [Float],
        k: Int,
        filter: (@Sendable (UUID) -> Bool)? = nil
    ) async -> [SearchResult] {
        let queryVec = Vector(query)
        return await index.search(query: queryVec, k: k, filter: filter)
    }

    // MARK: - State Queries

    /// 当前活跃向量数量（不含已删除标记）
    public var liveCount: Int {
        get async { await index.liveCount }
    }

    /// 索引是否为空
    public var isEmpty: Bool {
        get async { await index.isEmpty }
    }

    // MARK: - Persistence

    /// 将当前索引持久化到文件。
    ///
    /// 使用 ProximaKit 的二进制 `.pxkt` v2 格式，写入前自动压缩删除标记。
    ///
    /// - Parameter url: 目标文件 URL（建议使用 App 沙盒内路径 + `NSFileProtectionComplete`）
    /// - Throws: `VectorStoreError.persistenceFailed` 若写入失败
    public func save(to url: URL) async throws {
        do {
            try await index.save(to: url)
            try (url as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
        } catch {
            throw VectorStoreError.persistenceFailed(underlying: error)
        }
    }

    /// 从持久化文件加载向量存储 Actor。
    ///
    /// - Parameter url: `.pxkt` 文件 URL
    /// - Returns: 恢复的 VectorStoreActor 实例
    /// - Throws: `VectorStoreError.persistenceFailed` 若文件不存在或格式无效
    public static func load(from url: URL) throws -> VectorStoreActor {
        do {
            let idx = try HNSWIndex.load(from: url)
            return VectorStoreActor(index: idx)
        } catch {
            throw VectorStoreError.persistenceFailed(underlying: error)
        }
    }
}

// MARK: - Error Types

/// VectorStoreActor 统一错误类型
public enum VectorStoreError: Error, LocalizedError, Sendable {
    /// 向量维度与索引不匹配
    case dimensionMismatch(expected: Int, got: Int)

    /// 持久化操作失败（包装底层错误）
    case persistenceFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .dimensionMismatch(let expected, let got):
            return "Vector dimension mismatch: expected \(expected), got \(got)"
        case .persistenceFailed(let error):
            return "Persistence operation failed: \(error.localizedDescription)"
        }
    }
}
