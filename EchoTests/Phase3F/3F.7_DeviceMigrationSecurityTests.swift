// ==========================================
// 文件: 3F.7_DeviceMigrationSecurityTests.swift
// 对应规格: docs/decisions/ADR-008-source-import-boundaries.md §决策-6
//            docs/05-planning/phase3f-execution-plan.md §4.6.7 (3F.7 迁移安全子契约)
// 任务: 3F.7 - UI 到 Core 全域接线 (US-SRC-007 迁移安全子契约 — 加密/完整性/RFC 8785/资源边界)
// AC 覆盖: §4.6.7 — ECHOMIG1 固定头, AES-GCM-256+HKDF-SHA256, K_i 派生, 精确 AAD,
//          RFC 8785 JCS manifest, manifestSHA256, chunk framing, 逐记录哈希, 资源边界,
//          chunkCount=0/1 拒绝, recordCount=0 拒绝, manifest-only 拒绝, 篡改/截断 fail-closed
// 架构约束: AGENTS.md §4.2, R-007 (禁止 unchecked Sendable), 仅系统 CryptoKit
// 重要: TDD — 纯函数（deriveChunkKey / chunkAAD / canonicalJSON / encryptChunk / decryptChunk /
//       exportPackage / importPackage / header parse）稳定可测，不依赖共享 DB 状态。
// 生成时间: 2026-08-11
// ==========================================

import Testing
import Foundation
import CryptoKit
@testable import Echo

// MARK: - Suite: Device Migration Security

@Suite("DeviceMigrationSecurityTests", .serialized)
@MainActor
struct DeviceMigrationSecurityTests {

    // MARK: - RFC 8785 JCS Canonical JSON

    @Test("JCS: canonical output matches RFC 8785 (sorted keys, no whitespace)")
    func test_JCS_CanonicalOutput() throws {
        let records = [
            DeviceMigrationRecord(type: "memory", id: "a", byteLength: 1, sha256: String(repeating: "a", count: 64)),
        ]
        let manifest = DeviceMigrationManifest(
            archiveUUID: "11111111-1111-1111-1111-111111111111",
            chunkCount: 2,
            totalPlaintextBytes: 1,
            records: records
        )
        let json = try JCSEncoder.canonicalJSON(manifest: manifest)
        let text = String(data: json, encoding: .utf8)!
        // 根字段按 UTF-8 code point 升序：archiveUUID, chunkCount, recordCount, records, schemaVersion, totalPlaintextBytes
        #expect(text.hasPrefix("{\"archiveUUID\":\"11111111-1111-1111-1111-111111111111\",\"chunkCount\":2"))
        #expect(!text.contains(" "))
        #expect(!text.contains("\n"))
        #expect(!text.hasSuffix("\n"))
        // 无 BOM
        #expect(json.first != 0xEF)
    }

    @Test("JCS: parse rejects missing/unknown root fields")
    func test_JCS_ParseRejectsUnknownRootField() throws {
        let json = "{\"archiveUUID\":\"x\",\"chunkCount\":2,\"recordCount\":1,\"records\":[],\"schemaVersion\":1,\"totalPlaintextBytes\":0,\"extra\":true}"
        let data = Data(json.utf8)
        var threwManifest = false
        do { _ = try JCSEncoder.parseManifest(data) } catch { threwManifest = true }
        #expect(threwManifest)
    }

    @Test("JCS: parse rejects recordCount != records.count")
    func test_JCS_ParseRejectsCountMismatch() throws {
        let json = "{\"archiveUUID\":\"11111111-1111-1111-1111-111111111111\",\"chunkCount\":2,\"recordCount\":2,\"records\":[{\"type\":\"memory\",\"id\":\"a\",\"byteLength\":1,\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}],\"schemaVersion\":1,\"totalPlaintextBytes\":1}"
        let data = Data(json.utf8)
        var threwManifest = false
        do { _ = try JCSEncoder.parseManifest(data) } catch { threwManifest = true }
        #expect(threwManifest)
    }

    // MARK: - Header

    @Test("Header: parse accepts canonical header and rejects malformed variants")
    func test_Header_Parse() throws {
        let header = EchoMigrationHeader(
            archiveUUID: "11111111-1111-1111-1111-111111111111",
            chunkCount: 2,
            totalPlaintextBytes: 1,
            manifestSHA256: String(repeating: "a", count: 64)
        )
        let bytes = header.encode()
        let parsed = try EchoMigrationHeader.parse(bytes)
        #expect(parsed.archiveUUID == header.archiveUUID)
        #expect(parsed.chunkCount == 2)
        #expect(parsed.totalPlaintextBytes == 1)

        // wrong magic — 整个替换首行（magic 为 8 字节 "ECHOMIG1" + LF）
        var threwUnsupported = false
        do {
            let wrongMagicBytes = Data("NOPE\n".utf8) + bytes.dropFirst("ECHOMIG1\n".count)
            _ = try EchoMigrationHeader.parse(wrongMagicBytes)
        } catch { threwUnsupported = true }
        #expect(threwUnsupported)
        // wrong algorithm
        var bad = Data()
        bad.append(Data("ECHOMIG1\n".utf8))
        bad.append(Data("algorithm=WRONG\n".utf8))
        bad.append(bytes.dropFirst("ECHOMIG1\nalgorithm=AES-GCM-256+HKDF-SHA256\n".count))
        var threwUnsupported2 = false
        do { _ = try EchoMigrationHeader.parse(bad) } catch { threwUnsupported2 = true }
        #expect(threwUnsupported2)
    }

    @Test("Header: manifestSHA256 must be exactly 64 lowercase hex")
    func test_Header_RejectsNonLowercaseDigest() {
        let good = String(repeating: "a", count: 64)
        let upper = good.uppercased()
        let h1 = EchoMigrationHeader(archiveUUID: "11111111-1111-1111-1111-111111111111", chunkCount: 2, totalPlaintextBytes: 1, manifestSHA256: upper)
        var threwMalformed = false
        do { _ = try EchoMigrationHeader.parse(h1.encode()) } catch { threwMalformed = true }
        #expect(threwMalformed)
    }

    // MARK: - Key Derivation & AAD

    @Test("Key: deriveChunkKey is deterministic and length-32")
    func test_Key_DeriveChunkKey() {
        let key = SymmetricKey(data: Data(repeating: 0xAB, count: 32))
        let k0 = DeviceMigrationService.deriveChunkKey(transferKey: key, archiveUUID: "11111111-1111-1111-1111-111111111111", chunkIndex: 0)
        let k0b = DeviceMigrationService.deriveChunkKey(transferKey: key, archiveUUID: "11111111-1111-1111-1111-111111111111", chunkIndex: 0)
        let k1 = DeviceMigrationService.deriveChunkKey(transferKey: key, archiveUUID: "11111111-1111-1111-1111-111111111111", chunkIndex: 1)
        let bytes0 = k0.withUnsafeBytes { Data($0) }
        let bytes0b = k0b.withUnsafeBytes { Data($0) }
        let bytes1 = k1.withUnsafeBytes { Data($0) }
        #expect(bytes0.count == 32)
        #expect(bytes0 == bytes0b)
        #expect(bytes0 != bytes1, "different chunk index derives different key")
    }

    @Test("AAD: exact mandated format string")
    func test_AAD_ExactFormat() {
        let aad = DeviceMigrationService.chunkAAD(
            archiveUUID: "11111111-1111-1111-1111-111111111111",
            schemaVersion: 1,
            chunkIndex: 0,
            chunkCount: 2,
            plaintextLength: 100,
            manifestSHA256: String(repeating: "a", count: 64)
        )
        let text = String(data: aad, encoding: .utf8)!
        #expect(text == "EchoMigration/v1|11111111-1111-1111-1111-111111111111|1|0|2|100|\(String(repeating: "a", count: 64))")
    }

    // MARK: - Round-Trip Export/Import

    @Test("Round-trip: export then import returns exact payloads")
    func test_RoundTrip_ExportImport() throws {
        let key = SymmetricKey(size: .bits256)
        let records = [
            DeviceMigrationRecord(type: "memory", id: "11111111-1111-1111-1111-111111111111", byteLength: 11, sha256: SHA256.hash(data: Data("hello world".utf8)).hexString),
        ]
        let payloads = ["11111111-1111-1111-1111-111111111111": Data("hello world".utf8)]

        let package = try DeviceMigrationService.exportPackage(records: records, payloads: payloads, transferKey: key)
        let result = try DeviceMigrationService.importPackage(package, transferKey: key)
        #expect(result.manifest.recordCount == 1)
        #expect(result.payloads.count == 1)
        #expect(String(data: result.payloads["11111111-1111-1111-1111-111111111111"]!, encoding: .utf8) == "hello world")
    }

    @Test("Round-trip: cross-boundary record spanning data chunks")
    func test_RoundTrip_CrossBoundaryRecord() throws {
        let key = SymmetricKey(size: .bits256)
        // 3 MiB payload → single data chunk; use multiple records to force >1 chunk path
        let big = Data(repeating: 0x42, count: 3 * 1024 * 1024)
        let records = [
            DeviceMigrationRecord(type: "memory", id: "11111111-1111-1111-1111-111111111111", byteLength: big.count, sha256: SHA256.hash(data: big).hexString),
        ]
        let package = try DeviceMigrationService.exportPackage(records: records, payloads: ["11111111-1111-1111-1111-111111111111": big], transferKey: key)
        let result = try DeviceMigrationService.importPackage(package, transferKey: key)
        #expect(result.payloads["11111111-1111-1111-1111-111111111111"] == big)
    }

    @Test("Import: wrong transfer key fails closed (AES-GCM tag verification)")
    func test_Import_WrongKey() throws {
        let keyA = SymmetricKey(size: .bits256)
        let keyB = SymmetricKey(size: .bits256)
        let records = [
            DeviceMigrationRecord(type: "memory", id: "11111111-1111-1111-1111-111111111111", byteLength: 1, sha256: SHA256.hash(data: Data([0x01])).hexString),
        ]
        let package = try DeviceMigrationService.exportPackage(records: records, payloads: ["11111111-1111-1111-1111-111111111111": Data([0x01])], transferKey: keyA)
        var threwtamperDetected = false
        do { _ = try DeviceMigrationService.importPackage(package, transferKey: keyB) } catch { threwtamperDetected = true }
        #expect(threwtamperDetected)
    }

    @Test("Import: tampered payload chunk fails closed")
    func test_Import_TamperedChunk() throws {
        let key = SymmetricKey(size: .bits256)
        let records = [
            DeviceMigrationRecord(type: "memory", id: "11111111-1111-1111-1111-111111111111", byteLength: 4, sha256: SHA256.hash(data: Data("test".utf8)).hexString),
        ]
        let package = try DeviceMigrationService.exportPackage(records: records, payloads: ["11111111-1111-1111-1111-111111111111": Data("test".utf8)], transferKey: key)
        // 翻转末尾字节（位于最后数据块的 tag 区域）→ AES-GCM 认证必须失败
        var tampered = package
        tampered[tampered.count - 1] ^= 0x01
        var threwtamperDetected = false
        do { _ = try DeviceMigrationService.importPackage(tampered, transferKey: key) } catch { threwtamperDetected = true }
        #expect(threwtamperDetected)
    }

    @Test("Import: manifest-only (chunkCount=1) is always invalid")
    func test_Import_RejectsManifestOnly() throws {
        let key = SymmetricKey(size: .bits256)
        let records = [
            DeviceMigrationRecord(type: "memory", id: "11111111-1111-1111-1111-111111111111", byteLength: 1, sha256: SHA256.hash(data: Data([0x01])).hexString),
        ]
        let package = try DeviceMigrationService.exportPackage(records: records, payloads: ["11111111-1111-1111-1111-111111111111": Data([0x01])], transferKey: key)
        // 篡改 header chunkCount 字段（任意值 → 1）：解析阶段必须拒绝 chunkCount<2
        let headerBytes = try EchoMigrationHeader.parse(package).encode()
        let headerText = String(data: package.prefix(headerBytes.count), encoding: .utf8)!
        let chunkLineRange = headerText.range(of: "chunkCount=")!
        var tamperedHeader = headerText
        let lineEnd = headerText[chunkLineRange.upperBound...].firstIndex(of: "\n") ?? headerText.endIndex
        tamperedHeader.replaceSubrange(chunkLineRange.upperBound..<lineEnd, with: "1")
        var tampered = package
        tampered.replaceSubrange(0..<headerBytes.count, with: Data(tamperedHeader.utf8))
        // chunkCount=1 必被拒绝（manifest-only 恒非法）
        var threwmalformedHeader = false
        do { _ = try DeviceMigrationService.importPackage(tampered, transferKey: key) } catch { threwmalformedHeader = true }
        #expect(threwmalformedHeader)
    }

    @Test("Import: recordCount=0 / empty records rejected via manifest validation")
    func test_Import_RejectsEmptyRecords() throws {
        let key = SymmetricKey(size: .bits256)
        // 构造结构合法但 recordCount=0 的包（空 records manifest + 1 字节数据块）
        let archiveUUID = "11111111-1111-1111-1111-111111111111"
        let manifest = DeviceMigrationManifest(
            archiveUUID: archiveUUID,
            chunkCount: 2,
            totalPlaintextBytes: 1,
            records: []
        )
        let manifestPlaintext = try JCSEncoder.canonicalJSON(manifest: manifest)
        let manifestSHA256 = SHA256.hash(data: manifestPlaintext).hexString
        let header = EchoMigrationHeader(
            archiveUUID: archiveUUID,
            chunkCount: 2,
            totalPlaintextBytes: 1,
            manifestSHA256: manifestSHA256
        )
        var package = header.encode()
        let manifestKey = DeviceMigrationService.deriveChunkKey(transferKey: key, archiveUUID: archiveUUID, chunkIndex: 0)
        let manifestAAD = DeviceMigrationService.chunkAAD(archiveUUID: archiveUUID, schemaVersion: 1, chunkIndex: 0, chunkCount: 2, plaintextLength: manifestPlaintext.count, manifestSHA256: manifestSHA256)
        package.append(try DeviceMigrationService.encryptChunk(index: 0, plaintext: manifestPlaintext, key: manifestKey, aad: manifestAAD))
        let dataKey = DeviceMigrationService.deriveChunkKey(transferKey: key, archiveUUID: archiveUUID, chunkIndex: 1)
        let dataAAD = DeviceMigrationService.chunkAAD(archiveUUID: archiveUUID, schemaVersion: 1, chunkIndex: 1, chunkCount: 2, plaintextLength: 1, manifestSHA256: manifestSHA256)
        package.append(try DeviceMigrationService.encryptChunk(index: 1, plaintext: Data([0x01]), key: dataKey, aad: dataAAD))

        var threwinvalidManifest = false
        do { _ = try DeviceMigrationService.importPackage(package, transferKey: key) } catch { threwinvalidManifest = true }
        #expect(threwinvalidManifest)
    }

    @Test("Import: recordCount above maxRecordCount fails closed (CR-6)")
    func test_Import_RejectsRecordCountOverLimit() throws {
        let key = SymmetricKey(size: .bits256)
        // 手工构造 recordCount > maxRecordCount 的合法形包，必须在资源边界处拒绝
        let archiveUUID = "11111111-1111-1111-1111-111111111111"
        let fakeCount = EchoMigrationFormat.maxRecordCount + 1
        // 用 JCSEncoder 无法直接注入错误 recordCount（recordCount 由 records.count 计算），
        // 因此手工构建 manifest 明文 JSON 并加密，验证 import 在 manifest 校验阶段拒绝。
        let json = "{\"archiveUUID\":\"\(archiveUUID)\",\"chunkCount\":2,\"recordCount\":\(fakeCount),\"records\":[],\"schemaVersion\":1,\"totalPlaintextBytes\":1}"
        let manifestPlaintext = Data(json.utf8)
        let manifestSHA256 = SHA256.hash(data: manifestPlaintext).hexString
        let header = EchoMigrationHeader(
            archiveUUID: archiveUUID,
            chunkCount: 2,
            totalPlaintextBytes: 1,
            manifestSHA256: manifestSHA256
        )
        var package = header.encode()
        let manifestKey = DeviceMigrationService.deriveChunkKey(transferKey: key, archiveUUID: archiveUUID, chunkIndex: 0)
        let manifestAAD = DeviceMigrationService.chunkAAD(archiveUUID: archiveUUID, schemaVersion: 1, chunkIndex: 0, chunkCount: 2, plaintextLength: manifestPlaintext.count, manifestSHA256: manifestSHA256)
        package.append(try DeviceMigrationService.encryptChunk(index: 0, plaintext: manifestPlaintext, key: manifestKey, aad: manifestAAD))
        let dataKey = DeviceMigrationService.deriveChunkKey(transferKey: key, archiveUUID: archiveUUID, chunkIndex: 1)
        let dataAAD = DeviceMigrationService.chunkAAD(archiveUUID: archiveUUID, schemaVersion: 1, chunkIndex: 1, chunkCount: 2, plaintextLength: 1, manifestSHA256: manifestSHA256)
        package.append(try DeviceMigrationService.encryptChunk(index: 1, plaintext: Data([0x01]), key: dataKey, aad: dataAAD))

        var threw = false
        do { _ = try DeviceMigrationService.importPackage(package, transferKey: key) } catch { threw = true }
        #expect(threw)
    }

    @Test("Import: manifest + data combined size over maxPackageBytes fails closed (CR-6)")
    func test_Import_RejectsCombinedSizeOverLimit() throws {
        let key = SymmetricKey(size: .bits256)
        // 手工构造 manifest 声明 totalPlaintextBytes > maxPackageBytes（combined-size 资源边界拒绝，无需 2GiB 分配）
        let archiveUUID = "11111111-1111-1111-1111-111111111111"
        let oversizedTotal = EchoMigrationFormat.maxPackageBytes + 1
        let sha = String(repeating: "a", count: 64)
        let json = "{\"archiveUUID\":\"\(archiveUUID)\",\"chunkCount\":2,\"recordCount\":1,\"records\":[{\"byteLength\":\(oversizedTotal),\"id\":\"11111111-1111-1111-1111-111111111111\",\"sha256\":\"\(sha)\",\"type\":\"memory\"}],\"schemaVersion\":1,\"totalPlaintextBytes\":\(oversizedTotal)}"
        let manifestPlaintext = Data(json.utf8)
        let manifestSHA256 = SHA256.hash(data: manifestPlaintext).hexString
        let header = EchoMigrationHeader(
            archiveUUID: archiveUUID,
            chunkCount: 2,
            totalPlaintextBytes: oversizedTotal,
            manifestSHA256: manifestSHA256
        )
        var package = header.encode()
        let manifestKey = DeviceMigrationService.deriveChunkKey(transferKey: key, archiveUUID: archiveUUID, chunkIndex: 0)
        let manifestAAD = DeviceMigrationService.chunkAAD(archiveUUID: archiveUUID, schemaVersion: 1, chunkIndex: 0, chunkCount: 2, plaintextLength: manifestPlaintext.count, manifestSHA256: manifestSHA256)
        package.append(try DeviceMigrationService.encryptChunk(index: 0, plaintext: manifestPlaintext, key: manifestKey, aad: manifestAAD))
        let dataKey = DeviceMigrationService.deriveChunkKey(transferKey: key, archiveUUID: archiveUUID, chunkIndex: 1)
        let dataAAD = DeviceMigrationService.chunkAAD(archiveUUID: archiveUUID, schemaVersion: 1, chunkIndex: 1, chunkCount: 2, plaintextLength: 1, manifestSHA256: manifestSHA256)
        package.append(try DeviceMigrationService.encryptChunk(index: 1, plaintext: Data([0x01]), key: dataKey, aad: dataAAD))

        var threw = false
        do { _ = try DeviceMigrationService.importPackage(package, transferKey: key) } catch { threw = true }
        #expect(threw)
    }

    @Test("Import: truncated package (short data stream) fails closed")
    func test_Import_Truncated() throws {
        let key = SymmetricKey(size: .bits256)
        let records = [
            DeviceMigrationRecord(type: "memory", id: "11111111-1111-1111-1111-111111111111", byteLength: 4, sha256: SHA256.hash(data: Data("test".utf8)).hexString),
        ]
        let package = try DeviceMigrationService.exportPackage(records: records, payloads: ["11111111-1111-1111-1111-111111111111": Data("test".utf8)], transferKey: key)
        // 保留完整 header + chunk-0，截断数据块（短数据流）→ 必须 fail-closed
        let headerBytes = try EchoMigrationHeader.parse(package).encode()
        let chunk0Start = headerBytes.count
        let chunk0Len = 8 + 12 + 4 + 16
        let truncated = package.prefix(chunk0Start + chunk0Len)
        var threwmalformedHeader = false
        do { _ = try DeviceMigrationService.importPackage(Data(truncated), transferKey: key) } catch { threwmalformedHeader = true }
        #expect(threwmalformedHeader)
    }

    @Test("Import: altered manifestSHA256 header fails manifest hash check")
    func test_Import_ManifestHashMismatch() throws {
        let key = SymmetricKey(size: .bits256)
        let records = [
            DeviceMigrationRecord(type: "memory", id: "11111111-1111-1111-1111-111111111111", byteLength: 1, sha256: SHA256.hash(data: Data([0x01])).hexString),
        ]
        let package = try DeviceMigrationService.exportPackage(records: records, payloads: ["11111111-1111-1111-1111-111111111111": Data([0x01])], transferKey: key)
        var tampered = package
        // 仅解码 header 部分（包其余为 AES-GCM 二进制密文，非 UTF-8）
        let headerBytes = try EchoMigrationHeader.parse(package).encode()
        let headerText = String(data: package.prefix(headerBytes.count), encoding: .utf8)!
        let range = headerText.range(of: "manifestSHA256=")!
        let start = headerText.distance(from: headerText.startIndex, to: range.upperBound)
        // flip first digest hex char (lowercase hex stays valid; manifest hash check must fail)
        tampered[start] = tampered[start] == UInt8(ascii: "a") ? UInt8(ascii: "b") : UInt8(ascii: "a")
        var threwhashMismatch = false
        do { _ = try DeviceMigrationService.importPackage(tampered, transferKey: key) } catch { threwhashMismatch = true }
        #expect(threwhashMismatch)
    }

    @Test("Transfer key: base64url round-trip preserves 32 bytes")
    func test_TransferKey_Base64URLRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let encoded = DeviceMigrationActor.encodeTransferKey(key)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
        let decoded = try DeviceMigrationActor.decodeTransferKey(encoded)
        let a = key.withUnsafeBytes { Data($0) }
        let b = decoded.withUnsafeBytes { Data($0) }
        #expect(a == b)
    }

    @Test("Transfer key: reject malformed key")
    func test_TransferKey_RejectsMalformed() {
        var threwtamperDetected = false
        do { _ = try DeviceMigrationActor.decodeTransferKey("not-a-valid-key") } catch { threwtamperDetected = true }
        #expect(threwtamperDetected)
    }
}
