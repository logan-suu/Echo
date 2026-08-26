// ==========================================
// 文件: SearchRouteSnapshot.swift
// 对应规格: 自然语言照片检索交接计划 §7.7（完整路由快照）
// 任务: WP3 - 规范身份、删除、补偿与路由回滚（步骤 0b/2 系列）
// 架构约束: SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor 下值契约显式 nonisolated；
//           持久化/digest 输入仅使用排序数组，拒绝重复 channel；
//           dictionary 仅可作为解码后的运行时派生 lookup。
// 生成时间: 2026-08-25
// ==========================================

import CryptoKit
import Foundation

// MARK: - SearchChannel（WP4 时如需可迁至 PhotoSearchContracts.swift）

/// 四通道标识（交接计划 §7.3）。rawValue 即持久化与 digest 排序键。
public nonisolated enum SearchChannel: String, Sendable, Codable, Hashable, CaseIterable {
    case textDense = "text_dense"
    case visionDense = "vision_dense"
    case ocrText = "ocr_text"
    case lexical = "lexical"
}

// MARK: - Contract Errors

public nonisolated enum SearchRouteContractError: Error, Sendable, Equatable {
    case duplicateChannel(SearchChannel)
    case duplicateWeight(SearchChannel)
    case missingRequiredChannel(SearchChannel)
    case digestMismatch(expected: String, actual: String)
    case malformedCanonicalData
}

// MARK: - ChannelRoute

public nonisolated struct ChannelRoute: Sendable, Codable, Equatable {
    public nonisolated let channel: SearchChannel
    public nonisolated let generationID: String
    public nonisolated let indexManifestID: String?
    public nonisolated let queryModelManifestID: String?
    public nonisolated let dimension: Int?
    public nonisolated let alignmentSpaceID: String?
    public nonisolated let required: Bool

    public nonisolated init(
        channel: SearchChannel,
        generationID: String,
        indexManifestID: String?,
        queryModelManifestID: String?,
        dimension: Int?,
        alignmentSpaceID: String?,
        required: Bool
    ) {
        self.channel = channel
        self.generationID = generationID
        self.indexManifestID = indexManifestID
        self.queryModelManifestID = queryModelManifestID
        self.dimension = dimension
        self.alignmentSpaceID = alignmentSpaceID
        self.required = required
    }
}

// MARK: - ChannelWeight

public nonisolated struct ChannelWeight: Sendable, Codable, Equatable {
    public nonisolated let channel: SearchChannel
    public nonisolated let weight: Double

    public nonisolated init(channel: SearchChannel, weight: Double) {
        self.channel = channel
        self.weight = weight
    }
}

// MARK: - FusionPolicySnapshot

/// 融合策略快照——init 按 rawValue 排序并拒绝重复 channel。
public nonisolated struct FusionPolicySnapshot: Sendable, Codable, Equatable {
    public nonisolated let policyID: String
    public nonisolated let weights: [ChannelWeight]
    public nonisolated let rrfK: Double

    /// 排序 + 去重（交接计划 §7.7：拒绝重复 channel，权重数组按 rawValue 排序）
    public nonisolated init(
        policyID: String,
        weights: [ChannelWeight],
        rrfK: Double
    ) throws {
        var seen = Set<SearchChannel>()
        for w in weights {
            guard seen.insert(w.channel).inserted else {
                throw SearchRouteContractError.duplicateWeight(w.channel)
            }
        }
        self.policyID = policyID
        self.weights = weights.sorted { $0.channel.rawValue < $1.channel.rawValue }
        self.rrfK = rrfK
    }

    /// 解码后的运行时派生 lookup——不得进入持久化字节或 digest 输入。
    public nonisolated func weightsByChannel() -> [SearchChannel: Double] {
        Dictionary(uniqueKeysWithValues: weights.map { ($0.channel, $0.weight) })
    }
}

// MARK: - SearchRouteSnapshot

/// 完整路由快照——原子发布单元；channels 按 rawValue 排序并拒绝重复。
public nonisolated struct SearchRouteSnapshot: Sendable, Codable, Equatable {
    public nonisolated let snapshotID: String
    public nonisolated let schemaVersion: Int
    public nonisolated let routeVersion: Int
    public nonisolated let channels: [ChannelRoute]
    public nonisolated let fusion: FusionPolicySnapshot
    public nonisolated let previousSnapshotID: String?
    public nonisolated let publishedAtEpochMilliseconds: Int64
    public nonisolated let validationDigest: String

    /// 排序 + 去重（与 FusionPolicySnapshot 同规）。
    public nonisolated init(
        snapshotID: String,
        schemaVersion: Int,
        routeVersion: Int,
        channels: [ChannelRoute],
        fusion: FusionPolicySnapshot,
        previousSnapshotID: String?,
        publishedAtEpochMilliseconds: Int64,
        validationDigest: String
    ) throws {
        var seen = Set<SearchChannel>()
        for c in channels {
            guard seen.insert(c.channel).inserted else {
                throw SearchRouteContractError.duplicateChannel(c.channel)
            }
        }
        self.snapshotID = snapshotID
        self.schemaVersion = schemaVersion
        self.routeVersion = routeVersion
        self.channels = channels.sorted { $0.channel.rawValue < $1.channel.rawValue }
        self.fusion = fusion
        self.previousSnapshotID = previousSnapshotID
        self.publishedAtEpochMilliseconds = publishedAtEpochMilliseconds
        self.validationDigest = validationDigest
    }

    /// 解码后的运行时派生 lookup。
    public nonisolated func channelsByKind() -> [SearchChannel: ChannelRoute] {
        Dictionary(uniqueKeysWithValues: channels.map { ($0.channel, $0) })
    }

    /// canonical bytes（确定性编码；排除 validationDigest 递归字段）。
    public nonisolated func canonicalData() throws -> Data {
        try SearchRouteCanonicalEncoder.encode(self)
    }

    /// SHA-256 over canonicalData。
    public nonisolated func computedDigest() throws -> String {
        Self.sha256Hex(try canonicalData())
    }

    private nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Canonical Encoder

/// 确定性二进制编码器：固定版本前缀 + UTF-8 长度前缀字符串 +
/// big-endian 固定宽度整数 + Double.bitPattern + 显式 nil marker；
/// 排除递归字段 validationDigest。
public nonisolated enum SearchRouteCanonicalEncoder {
    private static let versionPrefix: UInt8 = 1

    public nonisolated static func encode(_ route: SearchRouteSnapshot) throws -> Data {
        var d = Data()
        d.append(versionPrefix)

        appendString(&d, route.snapshotID)
        appendInt64(&d, Int64(route.schemaVersion))
        appendInt64(&d, Int64(route.routeVersion))

        appendInt64(&d, Int64(route.channels.count))
        for c in route.channels {
            appendString(&d, c.channel.rawValue)
            appendString(&d, c.generationID)
            appendOptionalString(&d, c.indexManifestID)
            appendOptionalString(&d, c.queryModelManifestID)
            if let dim = c.dimension {
                d.append(1)
                appendInt64(&d, Int64(dim))
            } else {
                d.append(0)
            }
            appendOptionalString(&d, c.alignmentSpaceID)
            d.append(c.required ? 1 : 0)
        }

        appendString(&d, route.fusion.policyID)
        appendInt64(&d, Int64(route.fusion.weights.count))
        for w in route.fusion.weights {
            appendString(&d, w.channel.rawValue)
            appendUInt64(&d, w.weight.bitPattern)
        }
        appendUInt64(&d, route.fusion.rrfK.bitPattern)

        appendOptionalString(&d, route.previousSnapshotID)
        appendInt64(&d, route.publishedAtEpochMilliseconds)
        // validationDigest 刻意排除（防递归）

        return d
    }

    /// canonical bytes 解码（与 encode 完全对称；WP6 步骤 5b 重启校验）。
    /// 解码不携带 validationDigest（encode 刻意排除）；快照 init 的排序/去重会重建契约。
    public nonisolated static func decode(_ data: Data) throws -> SearchRouteSnapshot {
        var d = data
        guard d.popFirst() == versionPrefix else {
            throw SearchRouteContractError.malformedCanonicalData
        }
        let snapshotID = try readString(&d)
        let schemaVersion = Int(try readInt64(&d))
        let routeVersion = Int(try readInt64(&d))

        let channelCount = Int(try readInt64(&d))
        var channels: [ChannelRoute] = []
        for _ in 0..<channelCount {
            guard let channel = SearchChannel(rawValue: try readString(&d)) else {
                throw SearchRouteContractError.malformedCanonicalData
            }
            let generationID = try readString(&d)
            let indexManifestID = try readOptionalString(&d)
            let queryModelManifestID = try readOptionalString(&d)
            let hasDim = d.popFirst() == 1
            let dim = hasDim ? Int(try readInt64(&d)) : nil
            let alignmentSpaceID = try readOptionalString(&d)
            let required = d.popFirst() == 1
            channels.append(ChannelRoute(
                channel: channel,
                generationID: generationID,
                indexManifestID: indexManifestID,
                queryModelManifestID: queryModelManifestID,
                dimension: dim,
                alignmentSpaceID: alignmentSpaceID,
                required: required
            ))
        }

        let policyID = try readString(&d)
        let weightCount = Int(try readInt64(&d))
        var weights: [ChannelWeight] = []
        for _ in 0..<weightCount {
            guard let channel = SearchChannel(rawValue: try readString(&d)) else {
                throw SearchRouteContractError.malformedCanonicalData
            }
            let weight = Double(bitPattern: try readUInt64(&d))
            weights.append(ChannelWeight(channel: channel, weight: weight))
        }
        let rrfK = Double(bitPattern: try readUInt64(&d))

        let previousSnapshotID = try readOptionalString(&d)
        let publishedAt = try readInt64(&d)

        return try SearchRouteSnapshot(
            snapshotID: snapshotID,
            schemaVersion: schemaVersion,
            routeVersion: routeVersion,
            channels: channels,
            fusion: FusionPolicySnapshot(policyID: policyID, weights: weights, rrfK: rrfK),
            previousSnapshotID: previousSnapshotID,
            publishedAtEpochMilliseconds: publishedAt,
            validationDigest: ""
        )
    }

    private static func readString(_ data: inout Data) throws -> String {
        let count = Int(try readUInt64(&data))
        guard count >= 0, data.count >= count else {
            throw SearchRouteContractError.malformedCanonicalData
        }
        let utf8 = data.prefix(count)
        data.removeFirst(count)
        guard let value = String(data: Data(utf8), encoding: .utf8) else {
            throw SearchRouteContractError.malformedCanonicalData
        }
        return value
    }

    private static func readOptionalString(_ data: inout Data) throws -> String? {
        guard let flag = data.popFirst() else {
            throw SearchRouteContractError.malformedCanonicalData
        }
        return flag == 1 ? try readString(&data) : nil
    }

    private static func readInt64(_ data: inout Data) throws -> Int64 {
        Int64(bitPattern: try readUInt64(&data))
    }

    private static func readUInt64(_ data: inout Data) throws -> UInt64 {
        guard data.count >= 8 else {
            throw SearchRouteContractError.malformedCanonicalData
        }
        let bytes = data.prefix(8)
        data.removeFirst(8)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
    }

    private static func appendString(_ data: inout Data, _ value: String) {
        let utf8 = Data(value.utf8)
        appendUInt64(&data, UInt64(utf8.count))
        data.append(utf8)
    }

    private static func appendOptionalString(_ data: inout Data, _ value: String?) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        appendString(&data, value)
    }

    private static func appendInt64(_ data: inout Data, _ value: Int64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64(_ data: inout Data, _ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

// MARK: - RouteValidationReport

public nonisolated struct RouteValidationReport: Sendable, Equatable {
    public nonisolated let isValid: Bool
    public nonisolated let errors: [String]
    public nonisolated let checkedGenerationIDs: [String]
    public nonisolated let mappingDigest: String
    public nonisolated let canonicalRouteDigest: String

    public nonisolated init(
        isValid: Bool,
        errors: [String],
        checkedGenerationIDs: [String],
        mappingDigest: String,
        canonicalRouteDigest: String
    ) {
        self.isValid = isValid
        self.errors = errors
        self.checkedGenerationIDs = checkedGenerationIDs
        self.mappingDigest = mappingDigest
        self.canonicalRouteDigest = canonicalRouteDigest
    }
}

// MARK: - SearchRouteRegistry（WP6 实现；此处先行锁定契约形状）

/// 路由注册表契约——发布/校验/回滚/加载的原子操作面。
public nonisolated protocol SearchRouteRegistry: Sendable {
    func loadActiveSearchRoute() async throws -> SearchRouteSnapshot
    func validateSearchRoute(_ route: SearchRouteSnapshot) async throws -> RouteValidationReport
    func publishSearchRoute(_ route: SearchRouteSnapshot, traceID: String) async throws
    func rollbackSearchRoute(traceID: String) async throws -> SearchRouteSnapshot
}
