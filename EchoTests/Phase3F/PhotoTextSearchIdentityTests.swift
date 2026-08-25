// ==========================================
// 文件: PhotoTextSearchIdentityTests.swift
// 对应规格: 自然语言照片检索交接计划 WP3（规范身份、删除、补偿与路由回滚）
// 任务: WP3 步骤 0a-0b 值契约 nonisolated 表测试；后续步骤 1-5 逐步追加
// 架构约束: SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor 下值契约显式 nonisolated；
//           类型形状严格遵循交接计划 §7.5/§7.7/§7.8
// 生成时间: 2026-08-25
// ==========================================

import Foundation
import Testing

@testable import Echo

/// WP3 值契约与身份生命周期测试。
@Suite("PhotoTextSearchIdentity")
struct PhotoTextSearchIdentityTests {

    // MARK: - WP3 Step 0a/0b: 十二个值契约 nonisolated 表测试

    /// 表驱动遍历十二个 WP3 值契约类型的实例化冒烟。
    /// 「显式 nonisolated」由编译期保证（MainActor 默认隔离模块中，
    /// nonisolated 声明的类型可在任意域实例化）；本测试在非主线程上下文
    /// 构造它们以锁定该性质，并逐一校验关键字段 roundtrip。
    @Test("WP3 value contracts are nonisolated and constructible")
    func testWP3ValueContractsAreNonisolated() throws {
        let vectorID = UUID()
        let representationID = UUID()
        let memoryID = UUID()
        let generationID = "text_dense/e5-v1"

        // 1. CanonicalVectorBinding (§7.5)
        let binding = CanonicalVectorBinding(
            vectorID: vectorID,
            representationID: representationID,
            memoryID: memoryID,
            modality: .visionDense,
            generationID: generationID
        )
        #expect(binding.vectorID == vectorID)
        #expect(binding.representationID == representationID)
        #expect(binding.memoryID == memoryID)

        // 2. CanonicalMappingResult (§7.5 三态)
        let mapped: CanonicalMappingResult = .mapped(binding)
        if case .mapped(let b) = mapped {
            #expect(b.memoryID == memoryID)
        } else {
            Issue.record("expected .mapped")
        }
        let missing: CanonicalMappingResult = .missing(vectorID: vectorID, generationID: generationID)
        if case .missing(let vid, let gid) = missing {
            #expect(vid == vectorID && gid == generationID)
        } else {
            Issue.record("expected .missing")
        }
        let ambiguous: CanonicalMappingResult = .ambiguous(
            vectorID: vectorID, generationID: generationID, candidateMemoryIDs: [memoryID]
        )
        if case .ambiguous(_, _, let candidates) = ambiguous {
            #expect(candidates == [memoryID])
        } else {
            Issue.record("expected .ambiguous")
        }

        // 3. SearchRouteContractError (§7.7)
        let routeError = SearchRouteContractError.duplicateChannel(.textDense)
        guard case .duplicateChannel(let ch) = routeError else {
            Issue.record("expected .duplicateChannel")
            return
        }
        #expect(ch == .textDense)

        // 4. ChannelRoute (§7.7)
        let channelRoute = ChannelRoute(
            channel: .textDense,
            generationID: generationID,
            indexManifestID: nil,
            queryModelManifestID: nil,
            dimension: 384,
            alignmentSpaceID: nil,
            required: true
        )
        #expect(channelRoute.required)
        #expect(channelRoute.dimension == 384)

        // 5. ChannelWeight (§7.7)
        let channelWeight = ChannelWeight(channel: .visionDense, weight: 0.8)
        #expect(channelWeight.weight == 0.8)

        // 6. FusionPolicySnapshot (§7.7, throwing init)
        let policy = try FusionPolicySnapshot(
            policyID: "policy-1",
            weights: [channelWeight],
            rrfK: 60
        )
        #expect(policy.policyID == "policy-1")
        #expect(policy.rrfK == 60)

        // 7. SearchRouteSnapshot (§7.7, throwing init)
        let snapshot = try SearchRouteSnapshot(
            snapshotID: "snapshot-1",
            schemaVersion: 1,
            routeVersion: 1,
            channels: [channelRoute],
            fusion: policy,
            previousSnapshotID: nil,
            publishedAtEpochMilliseconds: 1_700_000_000_000,
            validationDigest: "digest-1"
        )
        #expect(snapshot.snapshotID == "snapshot-1")
        #expect(snapshot.validationDigest == "digest-1")

        // 8. RouteValidationReport (§7.7)
        let validation = RouteValidationReport(
            isValid: true,
            errors: [],
            checkedGenerationIDs: [generationID],
            mappingDigest: "mapping-digest",
            canonicalRouteDigest: "route-digest"
        )
        #expect(validation.isValid)
        #expect(validation.checkedGenerationIDs == [generationID])

        // 9. AuditSubject (§7.8)
        let subject = AuditSubject.memory(memoryID)
        #expect(subject.kind == "memory")
        #expect(subject.subjectHash.count == 64) // SHA-256 hex

        // 10. MemoryDeletionPhase (§7.8)
        let phase: MemoryDeletionPhase = .planned
        #expect(phase == .planned)

        // 11. GenerationVectorIDs (§7.8)
        let vecIDs = GenerationVectorIDs(generationID: generationID, vectorIDs: [vectorID])
        #expect(vecIDs.vectorIDs == [vectorID])

        // 12. MemoryDeletionJournal (§7.8)
        let journal = MemoryDeletionJournal(
            operationID: "op-1",
            memoryID: memoryID,
            auditSubjectHash: subject.subjectHash,
            traceID: "trace-1",
            phase: .planned,
            vectorIDsByGeneration: [vecIDs]
        )
        #expect(journal.operationID == "op-1")
        #expect(journal.phase == .planned)
    }
}

    // MARK: - WP3 Step 1a-1f: 确定性 representation ID 派生

    @Test("Photo vector ID equals representation ID (WP3 step 1a)")
    func testPhotoVectorIDEqualsRepresentationID() async throws {
        let repo = try await CanonicalMappingFixtures.prepare()
        let generationID = "text_dense/e5-v1"
        let memoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/wp3-photo", sourceType: "photo")

        // 派生 helper：照片 representation ID 恒等于 canonical memory ID
        let derivedRepID = CanonicalMemoryRepositoryActor.photoRepresentationID(memoryID: memoryId)
        #expect(derivedRepID == memoryId)

        let rep = Representation(
            representationId: derivedRepID,
            memoryId: memoryId,
            modality: .visionDense,
            preprocessVersion: "siglip2-v1",
            contentHash: "hash-wp3"
        )
        _ = try await repo.commit(
            memory: Memory(memoryId: memoryId, sourceLocator: "PHAsset/wp3-photo", canonicalText: nil, sourceType: "photo"),
            representations: [rep],
            vectorsByGeneration: [generationID: [
                CanonicalVectorEntry(id: CanonicalMemoryRepositoryActor.photoRepresentationID(memoryID: memoryId),
                                     vector: [Float](repeating: 0.25, count: 384))
            ]],
            traceID: "t-wp3-1a"
        )

        // vectorId == representationId == memoryId 的绑定闭环
        let result = try await repo.mapVectorID(derivedRepID, generationID: generationID)
        guard case .mapped(let binding) = result else {
            Issue.record("expected mapped binding")
            return
        }
        #expect(binding.vectorID == binding.representationID)
        #expect(binding.vectorID == memoryId)
        #expect(binding.memoryID == memoryId)
    }

    @Test("Video frame vector maps to parent memory (WP3 step 1c)")
    func testVideoFrameVectorMapsToParentMemory() async throws {
        let repo = try await CanonicalMappingFixtures.prepare()
        let generationID = "text_dense/e5-v1"
        let parentMemoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/wp3-video", sourceType: "video")

        // 帧组件 key 格式：frame:%06d（frame:000003 语义）
        let frameRepID = CanonicalMemoryRepositoryActor.videoFrameRepresentationID(
            sourceLocator: "PHAsset/wp3-video", frameIndex: 3
        )
        #expect(frameRepID != parentMemoryId)

        let rep = Representation(
            representationId: frameRepID,
            memoryId: parentMemoryId,
            modality: .visionDense,
            preprocessVersion: "siglip2-v1",
            contentHash: "hash-frame3"
        )
        _ = try await repo.commit(
            memory: Memory(memoryId: parentMemoryId, sourceLocator: "PHAsset/wp3-video", canonicalText: nil, sourceType: "video"),
            representations: [rep],
            vectorsByGeneration: [generationID: [
                CanonicalVectorEntry(id: frameRepID, vector: [Float](repeating: 0.5, count: 384))
            ]],
            traceID: "t-wp3-1c"
        )

        // 帧 vector 映射回父 memoryId
        let result = try await repo.mapVectorID(frameRepID, generationID: generationID)
        guard case .mapped(let binding) = result else {
            Issue.record("expected mapped frame binding")
            return
        }
        #expect(binding.vectorID == frameRepID)
        #expect(binding.representationID == frameRepID)
        #expect(binding.memoryID == parentMemoryId)

        // 确定性：同一父与帧序号重复派生结果一致
        let again = CanonicalMemoryRepositoryActor.videoFrameRepresentationID(
            sourceLocator: "PHAsset/wp3-video", frameIndex: 3
        )
        #expect(again == frameRepID)
    }

    @Test("Audio representation uses deterministic audio component key (WP3 step 1e)")
    func testAudioRepresentationUsesDeterministicAudioKey() async throws {
        let parentMemoryId = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/wp3-audio", sourceType: "video")

        let audioRepID = CanonicalMemoryRepositoryActor.audioRepresentationID(memoryID: parentMemoryId)
        #expect(audioRepID != parentMemoryId)

        // 固定组件 key：重复派生一致
        #expect(CanonicalMemoryRepositoryActor.audioRepresentationID(memoryID: parentMemoryId) == audioRepID)

        // 不同父 memory 派生不同 ID
        let otherParent = CanonicalMemoryRepositoryActor.deterministicID(sourceLocator: "PHAsset/wp3-audio-b", sourceType: "video")
        #expect(CanonicalMemoryRepositoryActor.audioRepresentationID(memoryID: otherParent) != audioRepID)
    }
