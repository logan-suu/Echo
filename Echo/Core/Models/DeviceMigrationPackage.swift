// ==========================================
// 文件: DeviceMigrationPackage.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-007 (设备迁移)
//            docs/decisions/ADR-008-source-import-boundaries.md §决策-6 (ECHOMIG1 加密迁移包边界)
//            docs/05-planning/phase3f-execution-plan.md §4.6.7 (3F.7 迁移安全子契约)
// 任务: 3F.7 - UI 到 Core 全域接线 (US-SRC-007 迁移安全子契约)
// AC 覆盖: US-SRC-007 AC-1 (仅本地传输, 无 CloudKit), AC-6 (不导出全部原始记忆),
//          迁移安全子契约: ECHOMIG1 固定头 / JCS manifest / chunk framing / 逐块哈希 / AAD / 资源边界
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §5.4 (hash-only), R-007 (禁止 unchecked Sendable),
//           仅系统 CryptoKit，无第三方加密库
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-11
// ==========================================

import Foundation

// MARK: - Canonical Constants

/// 迁移包固定格式标识（ADR-008 §决策-6：版本化固定格式包）。
public enum EchoMigrationFormat {
    /// 包头第一行标识
    public nonisolated static let magic = "ECHOMIG1"
    /// 算法标识 — 精确匹配，其他一律 fail-closed（ADR-008 §决策-6）
    public nonisolated static let algorithm = "AES-GCM-256+HKDF-SHA256"
    /// schemaVersion（v1）
    public nonisolated static let schemaVersion = 1
    /// 数据块固定大小（4 MiB）
    public nonisolated static let dataChunkSize = 4 * 1024 * 1024
    /// manifest 明文最大字节（4 MiB）
    public nonisolated static let maxManifestPlaintextBytes = 4 * 1024 * 1024
    /// 数据明文最大字节（4 GiB）
    public nonisolated static let maxTotalPlaintextBytes = 4 * 1024 * 1024 * 1024
    /// 最大记录数
    public nonisolated static let maxRecordCount = 1_000_000
    /// 最大解包体积上限（2 GiB）
    public nonisolated static let maxPackageBytes = 2 * 1024 * 1024 * 1024
    /// 膨胀率上限（100:1）
    public nonisolated static let maxExpansionRatio = 100
}

// MARK: - Migration Record

/// 迁移包记录 — manifest 中每条记忆的最小引用（ADR-008 §决策-7 最小数据边界）。
public struct DeviceMigrationRecord: Sendable, Equatable {
    /// 记录类型（如 "memory" / "excludedAsset"）
    public nonisolated let type: String
    /// 记录 ID（确定性 UUID 字符串）
    public nonisolated let id: String
    /// 载荷字节数（≥1）
    public nonisolated let byteLength: Int
    /// 载荷 SHA-256（64 位小写十六进制）
    public nonisolated let sha256: String

    public nonisolated init(type: String, id: String, byteLength: Int, sha256: String) {
        self.type = type
        self.id = id
        self.byteLength = byteLength
        self.sha256 = sha256
    }
}

// MARK: - Migration Manifest

/// 迁移包 manifest（chunk 0 明文，RFC 8785 JCS 规范 JSON）。
///
/// 恰好六个必填根字段：archiveUUID / schemaVersion / chunkCount / totalPlaintextBytes / recordCount / records。
/// manifest 不含 manifestSHA256 或自身摘要的任何副本（§4.6.7 契约）。
public struct DeviceMigrationManifest: Sendable, Equatable {
    public nonisolated let archiveUUID: String
    public nonisolated let schemaVersion: Int
    public nonisolated let chunkCount: Int
    public nonisolated let totalPlaintextBytes: Int
    public nonisolated let records: [DeviceMigrationRecord]

    public nonisolated init(
        archiveUUID: String,
        schemaVersion: Int = EchoMigrationFormat.schemaVersion,
        chunkCount: Int,
        totalPlaintextBytes: Int,
        records: [DeviceMigrationRecord]
    ) {
        self.archiveUUID = archiveUUID
        self.schemaVersion = schemaVersion
        self.chunkCount = chunkCount
        self.totalPlaintextBytes = totalPlaintextBytes
        self.records = records
    }

    public nonisolated var recordCount: Int { records.count }
}

// MARK: - RFC 8785 (JCS) Canonical JSON

/// RFC 8785 JSON Canonicalization Scheme — 按 §4.6.7 契约实现规范序列化。
///
/// 规则：
/// - 对象成员按键的 UTF-8 字节序（code point）升序排列，重复键拒绝
/// - 字符串按 JSON 规则转义（NFC 规范化由调用方先完成）
/// - 数字仅整数（0...2^53-1），无前导零、无浮点、无指数
/// - 无空白、无 BOM、无尾随换行
public enum JCSEncoder {

    /// 将根对象序列化为 JCS 规范 JSON（UTF-8，无 BOM，无尾随换行）。
    /// 根对象与 record 对象字段固定，用显式排序保证规范输出。
    public nonisolated static func canonicalJSON(manifest: DeviceMigrationManifest) throws -> Data {
        var object = JCSObject()
        object["archiveUUID"] = .string(manifest.archiveUUID)
        object["schemaVersion"] = .integer(manifest.schemaVersion)
        object["chunkCount"] = .integer(manifest.chunkCount)
        object["totalPlaintextBytes"] = .integer(manifest.totalPlaintextBytes)
        object["recordCount"] = .integer(manifest.recordCount)
        let records: [JCSValue] = manifest.records.map { record in
            var r = JCSObject()
            r["type"] = .string(record.type)
            r["id"] = .string(record.id)
            r["byteLength"] = .integer(record.byteLength)
            r["sha256"] = .string(record.sha256)
            return .object(r)
        }
        object["records"] = .array(records)
        let json = try canonicalObject(object)
        return Data(json.utf8)
    }

    /// 解析 JCS manifest JSON 字节 → DeviceMigrationManifest（校验六字段/四字段完整性）。
    public nonisolated static func parseManifest(_ data: Data) throws -> DeviceMigrationManifest {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any] else {
            throw DeviceMigrationError.invalidManifest("root must be an object")
        }
        let required = ["archiveUUID", "schemaVersion", "chunkCount", "totalPlaintextBytes", "recordCount", "records"]
        for key in required where !root.keys.contains(key) {
            throw DeviceMigrationError.invalidManifest("missing required field \(key)")
        }
        for key in root.keys where !required.contains(key) {
            throw DeviceMigrationError.invalidManifest("unknown root field \(key)")
        }
        guard let archiveUUID = root["archiveUUID"] as? String,
              let schemaVersion = root["schemaVersion"] as? NSNumber,
              let chunkCount = root["chunkCount"] as? NSNumber,
              let totalPlaintextBytes = root["totalPlaintextBytes"] as? NSNumber,
              let recordCount = root["recordCount"] as? NSNumber,
              let recordsRaw = root["records"] as? [[String: Any]] else {
            throw DeviceMigrationError.invalidManifest("field type mismatch")
        }
        guard isCanonicalInt(schemaVersion), isCanonicalInt(chunkCount),
              isCanonicalInt(totalPlaintextBytes), isCanonicalInt(recordCount) else {
            throw DeviceMigrationError.invalidManifest("non-integer numeric field")
        }
        let sv = schemaVersion.intValue
        let cc = chunkCount.intValue
        let total = totalPlaintextBytes.intValue
        let rc = recordCount.intValue
        guard rc == recordsRaw.count else {
            throw DeviceMigrationError.invalidManifest("recordCount != records.count")
        }
        let records: [DeviceMigrationRecord] = try recordsRaw.map { r in
            let req = ["type", "id", "byteLength", "sha256"]
            for key in req where !r.keys.contains(key) {
                throw DeviceMigrationError.invalidManifest("record missing field \(key)")
            }
            for key in r.keys where !req.contains(key) {
                throw DeviceMigrationError.invalidManifest("record unknown field \(key)")
            }
            guard let type = r["type"] as? String,
                  let id = r["id"] as? String,
                  let byteLength = r["byteLength"] as? NSNumber,
                  let sha256 = r["sha256"] as? String else {
                throw DeviceMigrationError.invalidManifest("record field type mismatch")
            }
            guard isCanonicalInt(byteLength) else {
                throw DeviceMigrationError.invalidManifest("byteLength not canonical integer")
            }
            return DeviceMigrationRecord(
                type: type,
                id: id,
                byteLength: byteLength.intValue,
                sha256: sha256
            )
        }
        return DeviceMigrationManifest(
            archiveUUID: archiveUUID,
            schemaVersion: sv,
            chunkCount: cc,
            totalPlaintextBytes: total,
            records: records
        )
    }

    // MARK: - JCS Value Model

    private enum JCSValue {
        case object([String: JCSValue])
        case array([JCSValue])
        case string(String)
        case integer(Int)
    }

    private typealias JCSObject = [String: JCSValue]

    /// 规范化对象：按键的 UTF-8 code point 升序序列化（RFC 8785 §3.2.3）。
    private nonisolated static func canonicalObject(_ object: JCSObject) throws -> String {
        // RFC 8785: 对象成员按键的 code point 升序排列。字典键已唯一（同键覆盖前先拒绝）。
        var seen = Set<String>()
        for key in object.keys {
            guard !seen.contains(key) else {
                throw DeviceMigrationError.invalidManifest("duplicate key \(key)")
            }
            seen.insert(key)
        }
        let sortedKeys = object.keys.sorted()
        var parts: [String] = []
        for key in sortedKeys {
            guard let value = object[key] else { continue }
            parts.append("\(escapeString(key)):\(try canonicalValue(value))")
        }
        return "{\(parts.joined(separator: ","))}"
    }

    private nonisolated static func canonicalValue(_ value: JCSValue) throws -> String {
        switch value {
        case .object(let obj): return try canonicalObject(obj)
        case .array(let items): return "[\(try items.map(canonicalValue).joined(separator: ","))]"
        case .string(let s): return escapeString(s)
        case .integer(let i):
            guard i >= 0, i <= 9007199254740991 else {
                throw DeviceMigrationError.invalidManifest("integer out of 0...2^53-1 range")
            }
            return "\(i)"
        }
    }

    /// JSON 字符串转义（RFC 8785 §3.2.2.2 — 与 JSON 规范一致）。
    private nonisolated static func escapeString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private nonisolated static func isCanonicalInt(_ number: NSNumber) -> Bool {
        // JSONSerialization 将整数解析为 NSNumber，浮点解析为 NSNumber.doubleValue。
        // 确保是整数值（拒绝 1.5、NaN、Infinity）。
        guard number.isEqual(to: NSNumber(value: number.doubleValue)) else { return false }
        let v = number.doubleValue
        guard v >= 0, v <= 9007199254740991, v.rounded() == v else { return false }
        return true
    }
}

// MARK: - Error

/// 设备迁移错误（L2 可恢复 — 迁移失败不阻断既有数据，reject 保持活动库不变）。
public enum DeviceMigrationError: Error, Equatable {
    case unsupportedFormat(String)
    case malformedHeader(String)
    case invalidManifest(String)
    case hashMismatch(String)
    case tamperDetected(String)
    case resourceBoundExceeded(String)
    case duplicateArchive(String)
    case unsupportedRecordType(String)
    case pathTraversal(String)
    case publicationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let s): return "Unsupported migration format: \(s)"
        case .malformedHeader(let s): return "Malformed migration header: \(s)"
        case .invalidManifest(let s): return "Invalid migration manifest: \(s)"
        case .hashMismatch(let s): return "Migration hash mismatch: \(s)"
        case .tamperDetected(let s): return "Migration integrity failure: \(s)"
        case .resourceBoundExceeded(let s): return "Migration resource bound exceeded: \(s)"
        case .duplicateArchive(let s): return "Duplicate migration archive: \(s)"
        case .unsupportedRecordType(let s): return "Unsupported migration record type: \(s)"
        case .pathTraversal(let s): return "Migration path traversal rejected: \(s)"
        case .publicationFailed(let s): return "Migration publication failed: \(s)"
        }
    }
}
