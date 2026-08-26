// ==========================================
// 文件: PhotoSearchContracts.swift
// 对应规格: 自然语言照片检索交接计划 §7.3/§7.4/§7.6（WP4 步骤 0b）
// 任务: WP4 - 生产多通道查询与规范 RRF 接线（值契约全家桶）
// 架构约束: SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor 下值契约显式 nonisolated；
//           SearchChannel 自 SearchRouteSnapshot.swift 迁入保持单一来源。
// 生成时间: 2026-08-25
// ==========================================

import Foundation

// MARK: - Contract Errors

/// 值契约构造校验错误（WP4 步骤 0b）。
public nonisolated enum PhotoSearchContractError: Error, Sendable, Equatable {
    case dimensionMismatch(expected: Int, actual: Int)
}

// MARK: - Per-channel Query Payloads（§7.3）

/// 稠密查询向量——维度与 manifest 身份绑定，构造期校验防错配。
public nonisolated struct DenseQueryVector: Sendable, Equatable {
    public nonisolated let values: [Float]
    public nonisolated let dimension: Int
    public nonisolated let modelManifestID: String
    public nonisolated let alignmentSpaceID: String

    /// 校验 values 数量与声明维度一致（fail-closed 防零填充/静默截断）。
    public nonisolated init(
        values: [Float],
        dimension: Int,
        modelManifestID: String,
        alignmentSpaceID: String
    ) throws {
        guard values.count == dimension else {
            throw PhotoSearchContractError.dimensionMismatch(
                expected: dimension, actual: values.count
            )
        }
        self.values = values
        self.dimension = dimension
        self.modelManifestID = modelManifestID
        self.alignmentSpaceID = alignmentSpaceID
    }
}

/// 各通道原生查询载荷——稠密通道取向量、词法通道保留原文与 locale。
public nonisolated enum ChannelQueryPayload: Sendable, Equatable {
    case dense(DenseQueryVector)
    case lexical(text: String, locale: String)
}

/// 多通道查询聚合体——一次编排的完整查询表示。
public nonisolated struct MultiChannelQuery: Sendable, Equatable {
    public nonisolated let queryHash: String
    public nonisolated let locale: String
    public nonisolated let payloads: [SearchChannel: ChannelQueryPayload]
    public nonisolated let routeSnapshotID: String
    public nonisolated let traceID: String

    public nonisolated init(
        queryHash: String,
        locale: String,
        payloads: [SearchChannel: ChannelQueryPayload],
        routeSnapshotID: String,
        traceID: String
    ) {
        self.queryHash = queryHash
        self.locale = locale
        self.payloads = payloads
        self.routeSnapshotID = routeSnapshotID
        self.traceID = traceID
    }
}

/// 查询表示工厂产物——成功载荷与各通道生成失败并存（部分失败不阻断健康通道）。
public nonisolated struct QueryRepresentationOutcome: Sendable, Equatable {
    public nonisolated let query: MultiChannelQuery
    public nonisolated let failures: [SearchChannel: ChannelFailure]

    public nonisolated init(
        query: MultiChannelQuery,
        failures: [SearchChannel: ChannelFailure]
    ) {
        self.query = query
        self.failures = failures
    }
}

// MARK: - Typed Channel Hits & Outcomes（§7.4）

/// 单通道原始命中——向量 ID 与 generation 绑定，canonical 映射前的原始形态。
public nonisolated struct RawChannelHit: Sendable, Equatable {
    public nonisolated let channel: SearchChannel
    public nonisolated let vectorID: UUID
    public nonisolated let rank: Int
    public nonisolated let nativeScore: Float?
    public nonisolated let generationID: String

    public nonisolated init(
        channel: SearchChannel,
        vectorID: UUID,
        rank: Int,
        nativeScore: Float?,
        generationID: String
    ) {
        self.channel = channel
        self.vectorID = vectorID
        self.rank = rank
        self.nativeScore = nativeScore
        self.generationID = generationID
    }
}

/// 通道跳过原因——与失败严格区分（跳过 ≠ 错误）。
public nonisolated enum ChannelSkipReason: String, Sendable, Codable, Equatable {
    case routeUnavailable
    case payloadUnavailable
    case consentDenied
    case sourceUnauthorized
    case indexEmpty
}

/// 通道级失败——L1~L4 分级的通道内封装，绝不阻断其他通道。
public nonisolated struct ChannelFailure: Error, Sendable, Equatable {
    public nonisolated let channel: SearchChannel
    public nonisolated let code: String
    public nonisolated let level: String
    public nonisolated let retryable: Bool

    public nonisolated init(
        channel: SearchChannel,
        code: String,
        level: String,
        retryable: Bool
    ) {
        self.channel = channel
        self.code = code
        self.level = level
        self.retryable = retryable
    }
}

/// 通道检索五态结果——success/empty/skipped/timedOut/failed 严格互斥，
/// 单个不健康通道不得抹除健康通道结果。
public nonisolated enum ChannelSearchOutcome: Sendable {
    case success(channel: SearchChannel, hits: [RawChannelHit], elapsedMs: Int)
    case empty(channel: SearchChannel, elapsedMs: Int)
    case skipped(channel: SearchChannel, reason: ChannelSkipReason)
    case timedOut(channel: SearchChannel, partialHits: [RawChannelHit], elapsedMs: Int)
    case failed(channel: SearchChannel, failure: ChannelFailure)
}

/// 原生搜索通道契约——每通道只接受自己声明的原生 payload。
public nonisolated protocol NativeSearchChannel: Sendable {
    nonisolated var channel: SearchChannel { get }

    func search(
        payload: ChannelQueryPayload,
        route: SearchRouteSnapshot,
        limit: Int,
        traceID: String
    ) async -> ChannelSearchOutcome
}

// MARK: - RRF Result Provenance（§7.6）

/// 单通道排名溯源——融合结果必须保留每个有贡献的通道 rank。
public nonisolated struct ChannelRankProvenance: Sendable, Codable, Equatable {
    public nonisolated let channel: SearchChannel
    public nonisolated let rank: Int
    public nonisolated let generationID: String
    public nonisolated let vectorID: UUID
    public nonisolated let nativeScore: Float?

    public nonisolated init(
        channel: SearchChannel,
        rank: Int,
        generationID: String,
        vectorID: UUID,
        nativeScore: Float?
    ) {
        self.channel = channel
        self.rank = rank
        self.generationID = generationID
        self.vectorID = vectorID
        self.nativeScore = nativeScore
    }
}

/// canonical 映射命中——绑定与原始命中的配对形态。
public nonisolated struct CanonicalMappedHit: Sendable, Equatable {
    public nonisolated let binding: CanonicalVectorBinding
    public nonisolated let hit: RawChannelHit

    public nonisolated init(binding: CanonicalVectorBinding, hit: RawChannelHit) {
        self.binding = binding
        self.hit = hit
    }
}

/// 融合检索结果——canonical memory + RRF 分数 + 全通道 provenance。
public nonisolated struct FusedSearchResult: Sendable, Equatable {
    public nonisolated let memory: Memory
    public nonisolated let rrfScore: Double
    public nonisolated let provenance: [ChannelRankProvenance]
    public nonisolated let routeSnapshotID: String

    public nonisolated init(
        memory: Memory,
        rrfScore: Double,
        provenance: [ChannelRankProvenance],
        routeSnapshotID: String
    ) {
        self.memory = memory
        self.rrfScore = rrfScore
        self.provenance = provenance
        self.routeSnapshotID = routeSnapshotID
    }

    /// 手写 nonisolated 相等性：按 memoryId 身份、分数与溯源比较，
    /// 避免 Memory 的 MainActor 隔离 Equatable 泄漏到非隔离上下文。
    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.memory.memoryId == rhs.memory.memoryId
            && lhs.rrfScore == rhs.rrfScore
            && lhs.routeSnapshotID == rhs.routeSnapshotID
            && lhs.provenance == rhs.provenance
    }
}

/// canonical RRF 融合器契约——输入使用数组（一个 memory 可有多通道命中），
/// 保留每个有贡献的 rank 并以 canonical UUID 确定性 tie-breaking。
public nonisolated protocol CanonicalRRFFusing: Sendable {
    func fuse(
        mappedHits: [CanonicalMappedHit],
        weights: [SearchChannel: Double],
        rrfK: Double,
        limit: Int,
        routeSnapshotID: String
    ) -> [(memoryID: UUID, score: Double, provenance: [ChannelRankProvenance])]
}

// MARK: - DefaultCanonicalRRFFuser（WP4 步骤 4b/4d/4f）

/// canonical RRF 融合器默认实现——
/// 按 memoryID 聚合多通道命中，score = Σ w_c/(rrfK+rank)，
/// 以 canonical UUID 升序做确定性 tie-breaking，
/// 保留每个有贡献通道的 provenance。
public struct DefaultCanonicalRRFFuser: CanonicalRRFFusing {
    public nonisolated init() {}

    public func fuse(
        mappedHits: [CanonicalMappedHit],
        weights: [SearchChannel: Double],
        rrfK: Double,
        limit: Int,
        routeSnapshotID: String
    ) -> [(memoryID: UUID, score: Double, provenance: [ChannelRankProvenance])] {
        // 按 memoryID 聚合贡献
        var contributions: [UUID: (score: Double, provs: [ChannelRankProvenance])] = [:]
        var order: [UUID] = []

        for mapped in mappedHits {
            let memID = mapped.binding.memoryID
            let ch = mapped.hit.channel
            let rank = max(1, mapped.hit.rank)
            let weight = weights[ch] ?? 1.0
            let contribution = weight / (rrfK + Double(rank))

            if contributions[memID] == nil {
                order.append(memID)
                contributions[memID] = (0, [])
            }
            contributions[memID]!.score += contribution
            contributions[memID]!.provs.append(ChannelRankProvenance(
                channel: ch,
                rank: mapped.hit.rank,
                generationID: mapped.hit.generationID,
                vectorID: mapped.hit.vectorID,
                nativeScore: mapped.hit.nativeScore
            ))
        }

        // 按分数降序；分数相同按 UUID 升序确定性 tie-break
        let ranked = order.sorted { a, b in
            let sa = contributions[a]!.score
            let sb = contributions[b]!.score
            if sa != sb { return sa > sb }
            return a.uuidString < b.uuidString
        }.prefix(limit)

        return ranked.map { memID in
            (memoryID: memID, score: contributions[memID]!.score, provenance: contributions[memID]!.provs)
        }
    }
}
