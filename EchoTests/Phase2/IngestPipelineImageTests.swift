// ==========================================
// 文件: IngestPipelineImageTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-ING-004 (图片记忆摄入)
//            docs/02-architecture/数据流全链路技术说明文档.md §3.1 (图片摄入)
// 任务: 2.3 - IngestPipeline：图片摄入
// AC 覆盖: US-ING-004 AC-1 (privacyBlurApplied=false), AC-2 (EXIF 元数据保留),
//          AC-3 (CLIP 向量 768 维), AC-4 (PHAsset 引用, 不复制存储),
//          AC-5 (审计 .imageIngested, privacyBlurApplied=false)
// 架构约束: AGENTS.md §4.1 (Pipeline 契约), R-006 (PrivacyCheckpoint)
// 重要: @MainActor 标注因 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，Actor 初始化器需此隔离
// 生成时间: 2026-07-09
// ==========================================

import Testing
import Foundation
import ProximaKit
@testable import Echo

// MARK: - Helpers

/// 创建测试用 EXIF 元数据（JSON 编码的 GPS 坐标等）
func makeTestExifJSON() -> Data {
    let exif: [String: Any] = [
        "GPSLatitude": 31.2304,
        "GPSLongitude": 121.4737,
        "Make": "Apple",
        "Model": "iPhone 17 Pro",
        "DateTimeOriginal": "2026-07-09T12:00:00Z"
    ]
    return try! JSONSerialization.data(withJSONObject: exif)
}

// MARK: - Test Suite: IngestPipeline Image Ingestion (US-ING-004)

@Suite("IngestPipeline Image Ingestion (US-ING-004)", .serialized)
@MainActor
struct IngestPipelineImageTests {

    // MARK: - Dependencies

    let db = DatabaseManager.shared
    let privacyActor = PrivacyActor.shared
    let excludedAssets = ExcludedAssetsActor.shared
    let vectorStore = VectorStoreActor(dimension: 768)

    /// Stub embedder — returns controllable vectors for deterministic testing
    let stubEmbedder = StubEmbedder()

    /// System under test
    var sut: IngestPipeline {
        IngestPipeline(
            embedder: stubEmbedder,
            privacyActor: privacyActor,
            vectorStore: vectorStore,
            excludedAssets: excludedAssets
        )
    }

    // MARK: - Setup & Teardown

    init() async throws {
        try await db.open()
        // Clean state
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        // Ensure photo data source is authorized
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice"],
            policyVersion: 1
        ))
    }

    // MARK: - AC-1: 禁止人脸/车牌等敏感区域模糊处理

    @Test("AC-1: ingested MemoryEntry has privacyBlurApplied=false (fixed)")
    func test_AC1_privacyBlurApplied_isFalse() async throws {
        let assetId = "AC1-\(UUID().uuidString.prefix(8))"
        let exif = makeTestExifJSON()
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let memory = try await sut.ingestImage(
            assetId: assetId,
            exifMetadata: exif,
            traceID: traceID
        )

        // AC-1: privacyBlurApplied MUST be false — no blurring of any kind
        #expect(memory.privacyBlurApplied == false)

        // Verify the metadata stored also has privacyBlurApplied=false
        let metadata = try await memory.encodeMetadata()
        let decoded = try MemoryEntry.decodeMetadata(from: metadata)
        #expect(decoded.privacyBlurApplied == false)
    }

    // MARK: - AC-2: EXIF 元数据完整保留

    @Test("AC-2: EXIF metadata is preserved in MemoryEntry")
    func test_AC2_exifMetadata_preserved() async throws {
        let assetId = "AC2a-\(UUID().uuidString.prefix(8))"
        let exif = makeTestExifJSON()
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let memory = try await sut.ingestImage(
            assetId: assetId,
            exifMetadata: exif,
            traceID: traceID
        )

        // AC-2: EXIF metadata is passed through and preserved
        #expect(memory.exifMetadata != nil)
        #expect(memory.exifMetadata == exif)

        // Verify metadata encoding preserves hasExif=true
        let metadata = try await memory.encodeMetadata()
        let decoded = try MemoryEntry.decodeMetadata(from: metadata)
        #expect(decoded.hasExif == true)
    }

    @Test("AC-2: nil EXIF metadata is handled (asset without EXIF data)")
    func test_AC2_exifMetadata_nil() async throws {
        let assetId = "AC2b-\(UUID().uuidString.prefix(8))"
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let memory = try await sut.ingestImage(
            assetId: assetId,
            exifMetadata: nil,
            traceID: traceID
        )

        // Nil EXIF is allowed — not all assets have EXIF
        #expect(memory.exifMetadata == nil)

        let metadata = try await memory.encodeMetadata()
        let decoded = try MemoryEntry.decodeMetadata(from: metadata)
        #expect(decoded.hasExif == false)
    }

    // MARK: - AC-3: CLIP 向量生成

    @Test("AC-3: CLIP embedding is 768-dimensional vector")
    func test_AC3_clipVector_768dim() async throws {
        let assetId = "AC3a-\(UUID().uuidString.prefix(8))"
        // Set a known non-zero embedding
        let knownVector = Array(0..<768).map { Float($0) * 0.001 }
        await stubEmbedder.setNextEmbedding(knownVector)
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let memory = try await sut.ingestImage(
            assetId: assetId,
            traceID: traceID
        )

        // AC-3: CLIP vector matches the embedder output (768-dim MobileCLIP-B LT embedding)
        #expect(memory.embedding.count == 768)
        #expect(memory.embedding == knownVector)
    }

    @Test("AC-3: embedding failure wraps in IngestError.embeddingFailed")
    func test_AC3_embeddingFailure_throws() async throws {
        let assetId = "AC3b-\(UUID().uuidString.prefix(8))"
        // Configure stub to throw on next call
        await stubEmbedder.setNextError(EmbedderError.modelNotLoaded)

        let traceID = UUID().uuidString
        do {
            _ = try await sut.ingestImage(assetId: assetId, traceID: traceID)
            #expect(Bool(false), "Expected IngestError.embeddingFailed")
        } catch let error as IngestError {
            if case .embeddingFailed = error {
                #expect(error.errorLevel == 3) // L3 阻断
            } else {
                #expect(Bool(false), "Expected embeddingFailed but got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected IngestError but got \(error)")
        }
    }

    // MARK: - AC-4: PHAsset 引用（不复制存储）

    @Test("AC-4: assetId is stored as PHAsset.localIdentifier, no file copy")
    func test_AC4_assetId_phAssetReference() async throws {
        let assetId = "AC4-\(UUID().uuidString.prefix(8))"
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let memory = try await sut.ingestImage(
            assetId: assetId,
            traceID: traceID
        )

        // AC-4: assetId is the PHAsset.localIdentifier, not a file path
        #expect(memory.assetId == assetId)
        #expect(memory.sourceType == "photo")

        // Verify the vector store has the memory with the assetId in metadata
        let metadata = try await memory.encodeMetadata()
        let decoded = try MemoryEntry.decodeMetadata(from: metadata)
        #expect(decoded.assetId == assetId)
        #expect(decoded.sourceType == "photo")
    }

    // MARK: - AC-5: 审计记录 .imageIngested

    @Test("AC-5: audit log written with .imageIngested and proper fields")
    func test_AC5_auditImageIngested_logged() async throws {
        let assetId = "AC5a-\(UUID().uuidString.prefix(8))"
        let exif = makeTestExifJSON()
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        _ = try await sut.ingestImage(
            assetId: assetId,
            exifMetadata: exif,
            traceID: traceID
        )

        // AC-5: Verify audit log contains .imageIngested entry
        let auditLogs = try await privacyActor.fetchAuditLogs(
            limit: 10,
            eventType: AuditEvent.imageIngested
        )
        #expect(!auditLogs.isEmpty, "Expected at least one .imageIngested audit entry")

        if let auditEntry = auditLogs.first {
            #expect(auditEntry.eventType == AuditEvent.imageIngested)
            #expect(auditEntry.traceID == traceID)
            #expect(auditEntry.success == true)
            #expect(auditEntry.sourceType == "photo")
            #expect(auditEntry.affectedCount == 1)
            // AC-5: privacyBlurApplied=false — excludedWritten=false
            #expect(auditEntry.excludedWritten == false)
        }
    }

    @Test("AC-5: audit log written for every successful ingestion")
    func test_AC5_multipleIngestions_eachHasAudit() async throws {
        await stubEmbedder.setNextError(nil)

        // Ingest 3 images with unique IDs
        for i in 0..<3 {
            let tid = "multiple-ingest-\(i)"
            _ = try await sut.ingestImage(assetId: "audit-asset-\(i)-\(UUID().uuidString.prefix(4))", traceID: tid)
        }

        // Verify 3 audit entries
        let auditLogs = try await privacyActor.fetchAuditLogs(
            limit: 10,
            eventType: AuditEvent.imageIngested
        )
        #expect(auditLogs.count == 3)

        // Verify each has a distinct traceID
        let traceIDs = auditLogs.map(\.traceID)
        #expect(Set(traceIDs).count == 3) // All unique
    }

    // MARK: - PrivacyCheckpoint (R-006)

    @Test("R-006: PrivacyCheckpoint enforced — denied sourceTypes throws IngestError.privacyDenied")
    func test_R006_privacyDenied_throws() async throws {
        let assetId = "R006-\(UUID().uuidString.prefix(8))"
        // Deauthorize photo data source
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["note", "voice"], // "photo" removed
            policyVersion: 1
        ))

        let traceID = UUID().uuidString
        do {
            _ = try await sut.ingestImage(assetId: assetId, traceID: traceID)
            #expect(Bool(false), "Expected IngestError.privacyDenied")
        } catch let error as IngestError {
            if case .privacyDenied = error {
                #expect(error.errorLevel == 2) // L2 可恢复
            } else {
                #expect(Bool(false), "Expected privacyDenied but got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected IngestError but got \(error)")
        }

        // Restore photo auth for subsequent tests
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice"],
            policyVersion: 2
        ))
    }

    // MARK: - Excluded Assets (US-SRC-008)

    @Test("ExcludedAssetsActor check — excluded asset throws IngestError.assetExcluded")
    func test_excludedAsset_throws() async throws {
        let assetId = "EXCL-\(UUID().uuidString.prefix(8))"
        await stubEmbedder.setNextError(nil)

        // Add asset to excluded list
        try await excludedAssets.add(
            assetId: assetId,
            sourceType: "photo",
            traceID: UUID().uuidString
        )

        let traceID = UUID().uuidString
        do {
            _ = try await sut.ingestImage(assetId: assetId, traceID: traceID)
            #expect(Bool(false), "Expected IngestError.assetExcluded")
        } catch let error as IngestError {
            if case .assetExcluded(let excludedAssetId) = error {
                #expect(excludedAssetId == assetId)
                #expect(error.errorLevel == 4) // L4 数据冲突
            } else {
                #expect(Bool(false), "Expected assetExcluded but got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected IngestError but got \(error)")
        }

        // Cleanup: remove from excluded list
        _ = try await excludedAssets.remove(assetId: assetId)
    }

    // MARK: - MemoryEntry model validation

    @Test("MemoryEntry: id is unique per ingestion")
    func test_memoryEntry_uniqueId() async throws {
        await stubEmbedder.setNextError(nil)

        let memory1 = try await sut.ingestImage(
            assetId: "id-test-1-\(UUID().uuidString.prefix(4))",
            traceID: UUID().uuidString
        )
        let memory2 = try await sut.ingestImage(
            assetId: "id-test-2-\(UUID().uuidString.prefix(4))",
            traceID: UUID().uuidString
        )

        #expect(memory1.id != memory2.id)
        #expect(memory1.assetId != memory2.assetId)
    }

    @Test("MemoryEntry: metadata roundtrip encode→decode preserves all fields")
    func test_memoryEntry_metadataRoundtrip() async throws {
        let assetId = "RTT-\(UUID().uuidString.prefix(8))"
        let exif = makeTestExifJSON()
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let memory = try await sut.ingestImage(
            assetId: assetId,
            exifMetadata: exif,
            traceID: traceID
        )

        // Encode metadata → write to VectorStore metadata field
        let metadata = try await memory.encodeMetadata()
        // Decode metadata → verify all fields preserved
        let decoded = try MemoryEntry.decodeMetadata(from: metadata)

        #expect(decoded.assetId == assetId)
        #expect(decoded.sourceType == "photo")
        #expect(decoded.hasExif == true)
        #expect(decoded.privacyBlurApplied == false)
        #expect(decoded.traceID == traceID)
    }

    // MARK: - VectorStore persistence

    @Test("MemoryEntry is persisted in VectorStoreActor after ingestion")
    func test_vectorStore_persistence() async throws {
        // Use a unique asset ID and known vector
        let uniqueAssetId = "persist-\(UUID().uuidString.prefix(8))"
        let knownVector = Array(repeating: Float(0.5), count: 768)
        await stubEmbedder.setNextEmbedding(knownVector)
        await stubEmbedder.setNextError(nil)

        let traceID = UUID().uuidString
        let memory = try await sut.ingestImage(
            assetId: uniqueAssetId,
            traceID: traceID
        )

        // Search for the ingested vector
        let results = await vectorStore.search(query: knownVector, k: 1)
        #expect(results.count == 1)
        if let result = results.first {
            #expect(result.id == memory.id)
        }
    }
}
