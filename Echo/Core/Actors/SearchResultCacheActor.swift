// ==========================================
// 文件: SearchResultCacheActor.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RET-007 (检索结果缓存),
//            docs/05-planning/phase3f-execution-plan.md → 3F.6 (Production search 与 feedback)
// 任务: 3F.6 - Production search 与 feedback（检索结果缓存实现）
// AC 覆盖: US-RET-007 AC-1 ✅ (TTL 过期视为未命中), AC-2 ✅ (策略变更批量失效旧缓存),
//          AC-3 ✅ (TTL 内命中返回), AC-4 ✅ (缓存键含 policyVersion/modelVersion/queryHash),
//          TTL 过期 (cacheTTL) + 条目上限 (maxEntries, v1 按写入时间 FIFO 逐出; 真 LRU 后续优化, CR-25)
// 架构约束: AGENTS.md §4.2 (Actor 隔离 — 可变缓存状态封装在 Actor 中),
//           R-007 (禁止 unchecked Sendable), R-008 (跨 Actor 调用必须 await),
//           R-006 (PrivacyCheckpoint 注入意图见各方法文档)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 状态: ✅ 已实现 (2026-08-11 GREEN) — lookup/store/invalidate 生产实现；
//       makeKey/stableHash 纯函数（确定性 FNV-1a 哈希）保持不变
// 生成时间: 2026-08-11 | 更新: 2026-08-11 (3F.6 实现)
// ==========================================

import Foundation

// MARK: - Search Cache Key

/// 检索结果缓存键（US-RET-007 AC-4）。
///
/// 键包含三个维度，任一变化即视为不同缓存条目：
/// - `policyVersion`: 隐私策略版本 — 策略变更后旧缓存必须失效（AC-2）
/// - `modelVersion`: 嵌入模型版本 — 模型更新后语义空间变化，旧向量结果不可复用
/// - `queryHash`: 查询文本的确定性哈希（FNV-1a 64-bit，hex 编码）
///
/// > 类型声明标记 `nonisolated`（SE-0470 隔离一致性）：否则 MainActor 隔离的
/// > Hashable 一致性无法在 Actor 缓存上下文（`entries` 字典键）中使用。
public nonisolated struct SearchCacheKey: Sendable, Hashable {
    /// 隐私策略版本（UserPolicy.policyVersion）
    public nonisolated let policyVersion: Int
    /// 嵌入模型版本（如 "multilingual-e5-small-v1"）
    public nonisolated let modelVersion: String
    /// 查询文本哈希（makeKey 生成）
    public nonisolated let queryHash: String

    public nonisolated init(policyVersion: Int, modelVersion: String, queryHash: String) {
        self.policyVersion = policyVersion
        self.modelVersion = modelVersion
        self.queryHash = queryHash
    }

    // MARK: Hashable（SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，显式 nonisolated）
    public nonisolated static func == (lhs: SearchCacheKey, rhs: SearchCacheKey) -> Bool {
        lhs.policyVersion == rhs.policyVersion
            && lhs.modelVersion == rhs.modelVersion
            && lhs.queryHash == rhs.queryHash
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(policyVersion)
        hasher.combine(modelVersion)
        hasher.combine(queryHash)
    }
}

// MARK: - Cached Search Result

/// 缓存的检索结果条目。
public struct CachedSearchResult: Sendable {
    /// 缓存的检索结果列表
    public nonisolated let items: [SearchResultItem]
    /// 缓存写入时间（TTL 过期判断基准）
    public nonisolated let cachedAt: Date

    public nonisolated init(items: [SearchResultItem], cachedAt: Date = Date()) {
        self.items = items
        self.cachedAt = cachedAt
    }
}

// MARK: - Search Result Cache Actor

/// 检索结果缓存 Actor（US-RET-007）。
///
/// ## Actor 隔离（AGENTS.md §4.2）
/// - 可变缓存状态（`entries` 字典）封装在 Actor 中，串行访问无数据竞争
/// - 内存态缓存（无 SQLite 持久化）— 进程重启即失效，符合检索结果缓存语义
///
/// ## 缓存语义（US-RET-007）
/// - `cacheTTL`: 条目 TTL（默认 3600s），过期条目在 lookup 时视为未命中
/// - `maxEntries`: 条目上限（默认 200），超出时逐出最旧条目（LRU 语义）
/// - `invalidate(policyVersion:)`: 策略变更时批量失效旧缓存（AC-2）
///
/// ## 隐私校验（R-006）
/// 缓存为纯读/写辅助设施，生产调用方（SearchPipeline）负责在入口注入
/// PrivacyCheckpoint（operation: .search）后再访问缓存；本 Actor 不重复校验。
public actor SearchResultCacheActor {

    // MARK: - Properties

    /// 条目 TTL（秒）
    private let cacheTTL: TimeInterval
    /// 条目数量上限
    private let maxEntries: Int
    /// 缓存存储（实现阶段填充：含 TTL 判定与 LRU 逐出）
    private var entries: [SearchCacheKey: CachedSearchResult] = [:]

    // MARK: - Initialization

    public init(cacheTTL: TimeInterval = 3600, maxEntries: Int = 200) {
        self.cacheTTL = cacheTTL
        self.maxEntries = maxEntries
    }

    // MARK: - Cache Operations

    /// 查询缓存条目（US-RET-007 AC-1/AC-3）。
    ///
    /// TTL 判定：`Date().timeIntervalSince(cachedAt) > cacheTTL` → 逐出并返回 nil
    /// （过期视为未命中，不抛错 — 调用方按未命中路径重新检索）。
    ///
    /// - Parameter key: 缓存键（policyVersion + modelVersion + queryHash）
    /// - Returns: 命中且未过期的缓存结果，未命中返回 nil
    public func lookup(key: SearchCacheKey) async throws -> CachedSearchResult? {
        guard let entry = entries[key] else { return nil }
        if Date().timeIntervalSince(entry.cachedAt) > cacheTTL {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    /// 写入缓存条目（US-RET-007 AC-3）。
    ///
    /// 超限逐出：`entries.count > maxEntries` 时移除 cachedAt 最旧条目。
    /// 语义说明（PR#58 CR-25）：v1 为**写入时间 FIFO 逐出**（lookup 不更新 cachedAt），
    /// 非严格 LRU；频繁读取的热条目可能被更新的冷条目挤出 — 属 v1 已知简化，
    /// 真 LRU（lastAccessedAt）列入后续优化。
    ///
    /// - Parameters:
    ///   - key: 缓存键
    ///   - result: 待缓存的检索结果
    public func store(key: SearchCacheKey, result: CachedSearchResult) async throws {
        entries[key] = result
        if entries.count > maxEntries,
           let oldest = entries.min(by: { $0.value.cachedAt < $1.value.cachedAt }) {
            entries.removeValue(forKey: oldest.key)
        }
    }

    /// 按策略版本批量失效缓存（US-RET-007 AC-2）。
    ///
    /// 策略变更后语义授权集变化，旧缓存结果可能包含已撤销数据源的历史命中，
    /// 必须全部失效，防止隐私越界结果被复用。
    ///
    /// - Parameter policyVersion: 失效的策略版本（仅移除该版本的条目，其他版本保留）
    /// WP3 步骤 3e/3f：删除任何包含该 memoryId 的完整 cache entry，返回删除条数。
    public func invalidate(memoryID: UUID) async throws -> Int {
        let before = entries.count
        entries = entries.filter { _, result in
            !result.items.contains { $0.id == memoryID }
        }
        return before - entries.count
    }

    /// consent purge / route migration 全量失效，返回清除条数。
    public func invalidateAll() async throws -> Int {
        let count = entries.count
        entries.removeAll()
        return count
    }

    public func invalidate(policyVersion: Int) async throws {
        entries = entries.filter { $0.key.policyVersion != policyVersion }
    }

    // MARK: - Key Building (Pure, Implemented)

    /// 构建缓存键（US-RET-007 AC-4）。
    ///
    /// `queryHash` 由确定性 FNV-1a 64-bit 哈希生成（hex 编码）—
    /// 纯函数、跨进程/跨运行确定性，不依赖 CryptoKit。
    ///
    /// - Parameters:
    ///   - policyVersion: 隐私策略版本
    ///   - modelVersion: 嵌入模型版本
    ///   - query: 原始查询文本
    /// - Returns: 完整缓存键
    public nonisolated static func makeKey(
        policyVersion: Int,
        modelVersion: String,
        query: String
    ) -> SearchCacheKey {
        SearchCacheKey(
            policyVersion: policyVersion,
            modelVersion: modelVersion,
            queryHash: stableHash(query)
        )
    }

    /// FNV-1a 64-bit 确定性哈希（hex 编码）。
    private nonisolated static func stableHash(_ input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
