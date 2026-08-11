// ==========================================
// 文件: DeviceMigrationService.swift
// 对应规格: docs/decisions/ADR-008-source-import-boundaries.md §决策-6 (ECHOMIG1 加密迁移包边界)
//            docs/05-planning/phase3f-execution-plan.md §4.6.7 (3F.7 迁移安全子契约)
// 任务: 3F.7 - UI 到 Core 全域接线 (US-SRC-007 迁移安全子契约)
// AC 覆盖: ECHOMIG1 固定头 / K_i 派生 / AES-GCM-256 逐块加密 / RFC 8785 JCS manifest /
//          manifestSHA256 校验 / 精确 AAD / chunk framing / 逐记录哈希 / staging 原子发布
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §5.4 (hash-only), R-007 (禁止 unchecked Sendable),
//           仅系统 CryptoKit; 禁止网络/云服务 (R-001/R-005, US-SRC-007 AC-1)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-11
// ==========================================

import Foundation
import CryptoKit

// MARK: - Migration Package Header

/// ECHOMIG1 包固定头（UTF-8，LF 行尾，无 BOM，末尾一个空行）。
public struct EchoMigrationHeader: Sendable, Equatable {
    public nonisolated let archiveUUID: String
    public nonisolated let schemaVersion: Int
    public nonisolated let chunkCount: Int
    public nonisolated let totalPlaintextBytes: Int
    public nonisolated let manifestSHA256: String

    public nonisolated init(
        archiveUUID: String,
        schemaVersion: Int = EchoMigrationFormat.schemaVersion,
        chunkCount: Int,
        totalPlaintextBytes: Int,
        manifestSHA256: String
    ) {
        self.archiveUUID = archiveUUID
        self.schemaVersion = schemaVersion
        self.chunkCount = chunkCount
        self.totalPlaintextBytes = totalPlaintextBytes
        self.manifestSHA256 = manifestSHA256
    }

    /// 序列化为规范头字节（每字段一行，末尾一个空行 = 两个 LF，规格 §4.6.7）。
    public nonisolated func encode() -> Data {
        var lines: [String] = [
            EchoMigrationFormat.magic,
            "algorithm=\(EchoMigrationFormat.algorithm)",
            "archiveUUID=\(archiveUUID)",
            "schemaVersion=\(schemaVersion)",
            "chunkCount=\(chunkCount)",
            "totalPlaintextBytes=\(totalPlaintextBytes)",
            "manifestSHA256=\(manifestSHA256)",
        ]
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// 解析头字节（严格校验字段与格式）。
    ///
    /// 仅解析固定头区（首个空行之前）；包其余部分为 AES-GCM 二进制密文，不能整体 UTF-8 解码。
    public nonisolated static func parse(_ data: Data) throws -> EchoMigrationHeader {
        // 定位 header 结尾：第一个空行（两个连续 LF）。Header 始终以空行结束。
        guard let blankRange = findBlankLine(in: data) else {
            throw DeviceMigrationError.malformedHeader("header terminator not found")
        }
        let headerData = data.prefix(blankRange.lowerBound)
        guard let text = String(data: headerData, encoding: .utf8) else {
            throw DeviceMigrationError.malformedHeader("not UTF-8")
        }
        // 必须 LF 行尾；拒绝 CRLF（\r 存在即 malformed）
        guard !text.contains("\r") else {
            throw DeviceMigrationError.malformedHeader("CR found")
        }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count == 7 else {
            throw DeviceMigrationError.malformedHeader("expected 7 header lines, got \(lines.count)")
        }
        guard lines[0] == EchoMigrationFormat.magic else {
            throw DeviceMigrationError.unsupportedFormat(lines[0])
        }
        guard lines[1] == "algorithm=\(EchoMigrationFormat.algorithm)" else {
            throw DeviceMigrationError.unsupportedFormat(lines[1])
        }
        func value(_ line: String, _ key: String) -> String? {
            let prefix = "\(key)="
            return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
        }
        guard let uuid = value(lines[2], "archiveUUID"), isValidUUID(uuid) else {
            throw DeviceMigrationError.malformedHeader("invalid archiveUUID")
        }
        guard let svStr = value(lines[3], "schemaVersion"),
              let sv = parseUnsignedDecimal(svStr), sv == EchoMigrationFormat.schemaVersion else {
            throw DeviceMigrationError.malformedHeader("invalid schemaVersion")
        }
        guard let ccStr = value(lines[4], "chunkCount"),
              let cc = parseUnsignedDecimal(ccStr), cc >= 2 else {
            throw DeviceMigrationError.malformedHeader("invalid chunkCount (must be >= 2)")
        }
        guard let tpStr = value(lines[5], "totalPlaintextBytes"),
              let tp = parseUnsignedDecimal(tpStr) else {
            throw DeviceMigrationError.malformedHeader("invalid totalPlaintextBytes")
        }
        guard let mh = value(lines[6], "manifestSHA256"),
              mh.count == 64, mh.allSatisfy({ $0.isHexDigit }), mh == mh.lowercased() else {
            throw DeviceMigrationError.malformedHeader("invalid manifestSHA256")
        }
        return EchoMigrationHeader(
            archiveUUID: uuid,
            schemaVersion: sv,
            chunkCount: cc,
            totalPlaintextBytes: tp,
            manifestSHA256: mh
        )
    }

    /// 定位 header 结束空行：字节序列 `\n\n`（LF, LF）。返回空行的第一个 LF 位置。
    nonisolated private static func findBlankLine(in data: Data) -> Range<Int>? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        for i in 0..<(bytes.count - 1) where bytes[i] == 0x0A && bytes[i + 1] == 0x0A {
            return i..<(i + 2)
        }
        return nil
    }

    /// 无符号十进制解析：无符号、无前导零（"0" 除外）。
    nonisolated private static func parseUnsignedDecimal(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        guard s.allSatisfy(\.isNumber) else { return nil }
        if s.count > 1 && s.hasPrefix("0") { return nil }
        return Int(s)
    }

    nonisolated private static func isValidUUID(_ s: String) -> Bool {
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count)) != nil
    }
}

// MARK: - Device Migration Service

/// 设备迁移服务 — ECHOMIG1 加密包的导出/导入（US-SRC-007 + §4.6.7 安全子契约）。
///
/// ## 边界（ADR-008 §决策-6）
/// - 仅本地 AirDrop / 系统分享；无 CloudKit、无网络、无密钥服务器
/// - K_transfer 一次性传输密钥：导出时生成并单独返回，绝不嵌入包内
/// - 导入校验顺序：头 → chunk 形状 → K_0 解密 manifest → JCS 校验 → 资源边界 → 全数据块 → 逐记录哈希 → 原子发布
public struct DeviceMigrationService {

    // MARK: - Key Derivation (HKDF-SHA256)

    /// 派生第 i 块的加密密钥 K_i（§4.6.7 精确协议）。
    ///
    /// K_i = HKDF-SHA256(inputKeyMaterial: K_transfer, salt: UTF8(小写archiveUUID),
    ///                    info: UTF8("EchoMigration/v1/chunk/" + decimal(i)), outputByteCount: 32)
    public nonisolated static func deriveChunkKey(
        transferKey: SymmetricKey,
        archiveUUID: String,
        chunkIndex: Int
    ) -> SymmetricKey {
        let salt = Data(archiveUUID.lowercased().utf8)
        let info = Data("EchoMigration/v1/chunk/\(chunkIndex)".utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: transferKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return derived
    }

    /// 精确 AAD（§4.6.7）：`EchoMigration/v1|<uuid>|<schema>|<chunk>|<chunkCount>|<plaintextLength>|<manifestSHA256>`。
    public nonisolated static func chunkAAD(
        archiveUUID: String,
        schemaVersion: Int,
        chunkIndex: Int,
        chunkCount: Int,
        plaintextLength: Int,
        manifestSHA256: String
    ) -> Data {
        let s = "EchoMigration/v1|\(archiveUUID.lowercased())|\(schemaVersion)|\(chunkIndex)|\(chunkCount)|\(plaintextLength)|\(manifestSHA256)"
        return Data(s.utf8)
    }

    // MARK: - Chunk Encryption

    /// 加密单个 chunk：随机 96-bit nonce + AES-GCM，输出 4-byte index + 4-byte length + nonce + ciphertext + 16-byte tag。
    public nonisolated static func encryptChunk(
        index: Int,
        plaintext: Data,
        key: SymmetricKey,
        aad: Data
    ) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        var out = Data()
        out.append(UInt32(index).bigEndianBytes)
        out.append(UInt32(plaintext.count).bigEndianBytes)
        out.append(nonce.withUnsafeBytes { Data($0) })
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// 解密单个 chunk（AAD 认证 + tag 校验）。
    public nonisolated static func decryptChunk(
        _ data: Data,
        key: SymmetricKey,
        aad: Data
    ) throws -> (index: Int, plaintext: Data) {
        guard data.count >= 4 + 4 + 12 + 16 else {
            throw DeviceMigrationError.tamperDetected("chunk too short")
        }
        let index = Int(UInt32(data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian))
        let length = Int(UInt32(data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian))
        let nonce = try AES.GCM.Nonce(data: data.subdata(in: 8..<20))
        let expectedCipher = 4 + 4 + 12 + length + 16
        guard data.count == expectedCipher else {
            throw DeviceMigrationError.tamperDetected("chunk length mismatch")
        }
        let cipherAndTag = data.subdata(in: 20..<data.count)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherAndTag.prefix(length), tag: cipherAndTag.suffix(16))
        do {
            let plain = try AES.GCM.open(sealed, using: key, authenticating: aad)
            return (index, plain)
        } catch {
            throw DeviceMigrationError.tamperDetected("AES-GCM tag verification failed")
        }
    }

    // MARK: - Export

    /// 导出 ECHOMIG1 加密包。
    ///
    /// - Parameters:
    ///   - records: 迁移记录（type/id/sha256 + 载荷映射）
    ///   - payloads: record.id → 载荷数据（仅最小字段，ADR-008 §决策-7）
    ///   - transferKey: 一次性传输密钥（新随机生成，由调用方单独展示，不落盘）
    /// - Returns: 完整包字节（头 + 全部 chunk）
    public nonisolated static func exportPackage(
        records: [DeviceMigrationRecord],
        payloads: [String: Data],
        transferKey: SymmetricKey,
        archiveUUID: String = UUID().uuidString.lowercased()
    ) throws -> Data {
        // 校验：每条记录载荷存在且 byteLength 一致
        var total = 0
        for record in records {
            guard let payload = payloads[record.id] else {
                throw DeviceMigrationError.publicationFailed("missing payload for \(record.id)")
            }
            guard payload.count == record.byteLength else {
                throw DeviceMigrationError.publicationFailed("payload length mismatch for \(record.id)")
            }
            total += record.byteLength
        }
        guard total <= EchoMigrationFormat.maxTotalPlaintextBytes else {
            throw DeviceMigrationError.resourceBoundExceeded("totalPlaintextBytes exceeds 4 GiB")
        }

        // manifest（chunk 0 明文）
        let manifestPlaintext = try JCSEncoder.canonicalJSON(
            manifest: DeviceMigrationManifest(
                archiveUUID: archiveUUID,
                chunkCount: 0, // 占位，先计算数据块数再回填
                totalPlaintextBytes: total,
                records: records
            )
        )
        // 数据块切分（4 MiB 非末块 + 1..4MiB 末块）
        let dataChunks = try sliceDataStream(payloads: payloads, records: records)
        let chunkCount = 1 + dataChunks.count

        // 重新序列化 manifest（chunkCount 已知）
        let finalManifestPlaintext = try JCSEncoder.canonicalJSON(
            manifest: DeviceMigrationManifest(
                archiveUUID: archiveUUID,
                chunkCount: chunkCount,
                totalPlaintextBytes: total,
                records: records
            )
        )
        let manifestSHA256 = SHA256.hash(data: finalManifestPlaintext).hexString

        let header = EchoMigrationHeader(
            archiveUUID: archiveUUID,
            chunkCount: chunkCount,
            totalPlaintextBytes: total,
            manifestSHA256: manifestSHA256
        )

        var package = header.encode()

        // chunk 0: manifest
        let manifestKey = deriveChunkKey(transferKey: transferKey, archiveUUID: archiveUUID, chunkIndex: 0)
        let manifestAAD = chunkAAD(
            archiveUUID: archiveUUID,
            schemaVersion: header.schemaVersion,
            chunkIndex: 0,
            chunkCount: chunkCount,
            plaintextLength: finalManifestPlaintext.count,
            manifestSHA256: manifestSHA256
        )
        package.append(try encryptChunk(index: 0, plaintext: finalManifestPlaintext, key: manifestKey, aad: manifestAAD))

        // 数据块
        for (i, chunk) in dataChunks.enumerated() {
            let index = i + 1
            let key = deriveChunkKey(transferKey: transferKey, archiveUUID: archiveUUID, chunkIndex: index)
            let aad = chunkAAD(
                archiveUUID: archiveUUID,
                schemaVersion: header.schemaVersion,
                chunkIndex: index,
                chunkCount: chunkCount,
                plaintextLength: chunk.count,
                manifestSHA256: manifestSHA256
            )
            package.append(try encryptChunk(index: index, plaintext: chunk, key: key, aad: aad))
        }

        return package
    }

    /// 将记录载荷按 canonical 记录顺序拼接为数据流并按 4 MiB 切块。
    private nonisolated static func sliceDataStream(
        payloads: [String: Data],
        records: [DeviceMigrationRecord]
    ) throws -> [Data] {
        var stream = Data()
        for record in records {
            guard let payload = payloads[record.id] else {
                throw DeviceMigrationError.publicationFailed("missing payload for \(record.id)")
            }
            stream.append(payload)
        }
        guard stream.count > 0 else {
            throw DeviceMigrationError.publicationFailed("empty data stream")
        }
        var chunks: [Data] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + EchoMigrationFormat.dataChunkSize, stream.count)
            chunks.append(stream.subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }

    // MARK: - Import

    /// 导入并校验 ECHOMIG1 加密包（全部校验通过才返回解密载荷，发布由调用方原子执行）。
    ///
    /// - Parameters:
    ///   - package: 包字节
    ///   - transferKey: 用户输入的传输密钥
    /// - Returns: 校验通过的记录载荷流（record.id → Data）
    public nonisolated static func importPackage(
        _ package: Data,
        transferKey: SymmetricKey
    ) throws -> [String: Data] {
        // (1) 解析固定头与 chunk 帧
        let header = try EchoMigrationHeader.parse(package)

        // (2) 资源边界：combined 上限
        guard header.totalPlaintextBytes <= EchoMigrationFormat.maxTotalPlaintextBytes else {
            throw DeviceMigrationError.resourceBoundExceeded("totalPlaintextBytes exceeds 4 GiB")
        }
        guard header.chunkCount >= 2 else {
            throw DeviceMigrationError.malformedHeader("chunkCount < 2 always invalid")
        }

        // 定位 chunk 边界
        let headerBytes = header.encode()
        var cursor = headerBytes.count
        var chunks: [(index: Int, data: Data)] = []
        var seenIndexes: [Int] = []
        for _ in 0..<header.chunkCount {
            guard cursor + 8 <= package.count else {
                throw DeviceMigrationError.malformedHeader("truncated chunk framing")
            }
            let index = Int(UInt32(package.subdata(in: cursor..<(cursor + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian))
            let length = Int(UInt32(package.subdata(in: (cursor + 4)..<(cursor + 8)).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian))
            guard length >= 1 else {
                throw DeviceMigrationError.malformedHeader("zero-length chunk at index \(index)")
            }
            let totalChunk = 8 + 12 + length + 16
            guard cursor + totalChunk <= package.count else {
                throw DeviceMigrationError.malformedHeader("truncated chunk \(index)")
            }
            let chunkData = package.subdata(in: cursor..<(cursor + totalChunk))
            chunks.append((index, chunkData))
            seenIndexes.append(index)
            cursor += totalChunk
        }
        guard cursor == package.count else {
            throw DeviceMigrationError.malformedHeader("trailing bytes after final chunk")
        }

        // chunk 索引连续 0...chunkCount-1
        let expected = Array(0..<header.chunkCount)
        guard seenIndexes == expected else {
            throw DeviceMigrationError.malformedHeader("non-contiguous chunk indexes")
        }

        // (3) 解密 chunk 0 → manifest 明文
        let manifestKey = deriveChunkKey(transferKey: transferKey, archiveUUID: header.archiveUUID, chunkIndex: 0)
        let manifestAAD = chunkAAD(
            archiveUUID: header.archiveUUID,
            schemaVersion: header.schemaVersion,
            chunkIndex: 0,
            chunkCount: header.chunkCount,
            plaintextLength: try plaintextLength(of: chunks[0].data),
            manifestSHA256: header.manifestSHA256
        )
        let (_, manifestPlaintext) = try decryptChunk(chunks[0].data, key: manifestKey, aad: manifestAAD)
        guard manifestPlaintext.count <= EchoMigrationFormat.maxManifestPlaintextBytes else {
            throw DeviceMigrationError.resourceBoundExceeded("manifest plaintext exceeds 4 MiB")
        }

        // (4) JCS 校验 + manifestSHA256 一致性
        let canonicalBytes = try JCSEncoder.canonicalJSON(manifest: try JCSEncoder.parseManifest(manifestPlaintext))
        guard canonicalBytes == manifestPlaintext else {
            throw DeviceMigrationError.invalidManifest("manifest is not canonical JCS")
        }
        let recomputed = SHA256.hash(data: manifestPlaintext).hexString
        guard recomputed == header.manifestSHA256 else {
            throw DeviceMigrationError.hashMismatch("manifestSHA256 mismatch")
        }

        // (5) schema/字段一致性
        let manifest = try JCSEncoder.parseManifest(manifestPlaintext)
        guard manifest.archiveUUID.lowercased() == header.archiveUUID.lowercased() else {
            throw DeviceMigrationError.invalidManifest("archiveUUID mismatch")
        }
        guard manifest.schemaVersion == header.schemaVersion else {
            throw DeviceMigrationError.invalidManifest("schemaVersion mismatch")
        }
        guard manifest.chunkCount == header.chunkCount else {
            throw DeviceMigrationError.invalidManifest("chunkCount mismatch")
        }
        guard manifest.totalPlaintextBytes == header.totalPlaintextBytes else {
            throw DeviceMigrationError.invalidManifest("totalPlaintextBytes mismatch")
        }
        guard manifest.recordCount >= 1 else {
            throw DeviceMigrationError.invalidManifest("recordCount must be >= 1")
        }
        for record in manifest.records where record.byteLength < 1 {
            throw DeviceMigrationError.invalidManifest("record byteLength must be >= 1")
        }
        // overflow-safe sum
        let sum = try manifest.records.reduce(0) { partial, record in
            let (result, overflow) = partial.addingReportingOverflow(record.byteLength)
            guard !overflow else { throw DeviceMigrationError.invalidManifest("byteLength sum overflow") }
            return result
        }
        guard sum == manifest.totalPlaintextBytes else {
            throw DeviceMigrationError.invalidManifest("sum(byteLength) != totalPlaintextBytes")
        }

        // (6) 解密全部数据块，重建拼接流
        var dataStream = Data()
        for (i, chunk) in chunks.dropFirst().enumerated() {
            let index = i + 1
            let key = deriveChunkKey(transferKey: transferKey, archiveUUID: header.archiveUUID, chunkIndex: index)
            let aad = chunkAAD(
                archiveUUID: header.archiveUUID,
                schemaVersion: header.schemaVersion,
                chunkIndex: index,
                chunkCount: header.chunkCount,
                plaintextLength: try plaintextLength(of: chunk.data),
                manifestSHA256: header.manifestSHA256
            )
            let (_, plain) = try decryptChunk(chunk.data, key: key, aad: aad)
            dataStream.append(plain)
        }
        guard dataStream.count == header.totalPlaintextBytes else {
            throw DeviceMigrationError.hashMismatch("decrypted stream length != totalPlaintextBytes")
        }

        // (7) 逐记录切片 + SHA-256 校验
        var result: [String: Data] = [:]
        var offset = 0
        for record in manifest.records {
            let start = offset
            let end = start + record.byteLength
            guard end <= dataStream.count else {
                throw DeviceMigrationError.hashMismatch("stream too short for record \(record.id)")
            }
            let slice = dataStream.subdata(in: start..<end)
            let digest = SHA256.hash(data: slice).hexString
            guard digest == record.sha256 else {
                throw DeviceMigrationError.hashMismatch("record hash mismatch for \(record.id)")
            }
            result[record.id] = slice
            offset = end
        }
        return result
    }

    /// 从 chunk 帧中读取明文长度（index 之后的 4 字节）。
    private nonisolated static func plaintextLength(of chunk: Data) throws -> Int {
        guard chunk.count >= 8 else {
            throw DeviceMigrationError.malformedHeader("chunk too short for length")
        }
        return Int(UInt32(chunk.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian))
    }
}

// MARK: - Helpers

private extension UInt32 {
    nonisolated var bigEndianBytes: Data {
        var value = bigEndian
        return Data(bytes: &value, count: 4)
    }
}

public extension Digest {
    /// 十六进制小写摘要。
    nonisolated var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
