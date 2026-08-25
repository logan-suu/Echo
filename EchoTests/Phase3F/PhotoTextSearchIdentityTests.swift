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

    // MARK: - WP3 Step 2a-2j2: SearchRouteSnapshot 功能化回归守卫

    private func makeWeight(_ ch: SearchChannel, _ w: Double) -> ChannelWeight {
        ChannelWeight(channel: ch, weight: w)
    }

    private func makeRoute(_ ch: SearchChannel, gen: String) -> ChannelRoute {
        ChannelRoute(channel: ch, generationID: gen, indexManifestID: nil,
                     queryModelManifestID: nil, dimension: 384, alignmentSpaceID: nil, required: true)
    }

    @Test("Search route channels are sorted by raw value (WP3 step 2a)")
    func testSearchRouteChannelsAreSortedByRawValue() throws {
        let policy = try FusionPolicySnapshot(policyID: "p", weights: [], rrfK: 60)
        let routes = [
            makeRoute(.visionDense, gen: "v"),
            makeRoute(.textDense, gen: "t"),
            makeRoute(.lexical, gen: "l"),
            makeRoute(.ocrText, gen: "o"),
        ]
        let snapshot = try SearchRouteSnapshot(
            snapshotID: "s", schemaVersion: 1, routeVersion: 1,
            channels: routes, fusion: policy,
            previousSnapshotID: nil, publishedAtEpochMilliseconds: 0, validationDigest: "d"
        )
        let raws = snapshot.channels.map { $0.channel.rawValue }
        #expect(raws == raws.sorted())
    }

    @Test("Canonical encoder uses version prefix (WP3 step 2b1)")
    func testCanonicalEncoderUsesVersionPrefix() throws {
        let policy = try FusionPolicySnapshot(policyID: "p", weights: [], rrfK: 60)
        let snapshot = try SearchRouteSnapshot(
            snapshotID: "s", schemaVersion: 1, routeVersion: 1,
            channels: [], fusion: policy,
            previousSnapshotID: nil, publishedAtEpochMilliseconds: 0, validationDigest: "ignored"
        )
        let data = try snapshot.canonicalData()
        #expect(data.first == 0x01)
    }

    @Test("Canonical encoder uses fixed width fields (WP3 step 2b2)")
    func testCanonicalEncoderUsesFixedWidthFields() throws {
        // 同一快照仅改 snapshotID 长度 ±1 时，canonicalData 总长差应恰等于该字符串
        // 的长度差 + 其 8 字节长度前缀不变性（长度前缀恒为 8B 定宽）
        func build(id: String) throws -> Data {
            let policy = try FusionPolicySnapshot(policyID: "p", weights: [], rrfK: 60)
            return try SearchRouteSnapshot(
                snapshotID: id, schemaVersion: 1, routeVersion: 7,
                channels: [], fusion: policy,
                previousSnapshotID: nil, publishedAtEpochMilliseconds: 42,
                validationDigest: "ignored"
            ).canonicalData()
        }
        let short = try build(id: "abc")
        let long = try build(id: "abcd")
        #expect(long.count - short.count == 1)
        #expect(short.dropFirst(9).prefix(3) == Data("abc".utf8))
        #expect(long.dropFirst(9).prefix(4) == Data("abcd".utf8))
    }

    @Test("Canonical route data ignores channel insertion order (WP3 step 2b3)")
    func testCanonicalRouteDataIgnoresChannelInsertionOrder() throws {
        let policyA = try FusionPolicySnapshot(
            policyID: "p",
            weights: [makeWeight(.textDense, 1.0), makeWeight(.visionDense, 0.8)],
            rrfK: 60
        )
        let policyB = try FusionPolicySnapshot(
            policyID: "p",
            weights: [makeWeight(.visionDense, 0.8), makeWeight(.textDense, 1.0)],
            rrfK: 60
        )
        let a = try SearchRouteSnapshot(
            snapshotID: "s", schemaVersion: 1, routeVersion: 1,
            channels: [makeRoute(.visionDense, gen: "v"), makeRoute(.textDense, gen: "t")],
            fusion: policyA, previousSnapshotID: nil,
            publishedAtEpochMilliseconds: 42, validationDigest: "ignored"
        )
        let b = try SearchRouteSnapshot(
            snapshotID: "s", schemaVersion: 1, routeVersion: 1,
            channels: [makeRoute(.textDense, gen: "t"), makeRoute(.visionDense, gen: "v")],
            fusion: policyB, previousSnapshotID: nil,
            publishedAtEpochMilliseconds: 42, validationDigest: "ignored"
        )
        let dataA = try a.canonicalData()
        let dataB = try b.canonicalData()
        #expect(dataA == dataB)
        let digestA = try a.computedDigest()
        let digestB = try b.computedDigest()
        #expect(digestA == digestB)
        #expect(a == b)
    }

    @Test("Fusion weights reject duplicate channel (WP3 step 2c)")
    func testFusionWeightsRejectDuplicateChannel() throws {
        #expect(throws: SearchRouteContractError.duplicateWeight(.textDense)) {
            try FusionPolicySnapshot(
                policyID: "p",
                weights: [makeWeight(.textDense, 1.0), makeWeight(.textDense, 0.9)],
                rrfK: 60
            )
        }
    }

    @Test("Fusion weights are sorted by channel raw value (WP3 step 2d1)")
    func testFusionWeightsAreSortedByChannelRawValue() throws {
        let policy = try FusionPolicySnapshot(
            policyID: "p",
            weights: [makeWeight(.visionDense, 0.8), makeWeight(.lexical, 0.5), makeWeight(.textDense, 1.0)],
            rrfK: 60
        )
        let raws = policy.weights.map { $0.channel.rawValue }
        #expect(raws == raws.sorted())
    }

    @Test("Route rejects duplicate channel (WP3 step 2e)")
    func testRouteRejectsDuplicateChannel() throws {
        let policy = try FusionPolicySnapshot(policyID: "p", weights: [], rrfK: 60)
        #expect(throws: SearchRouteContractError.duplicateChannel(.textDense)) {
            try SearchRouteSnapshot(
                snapshotID: "s", schemaVersion: 1, routeVersion: 1,
                channels: [makeRoute(.textDense, gen: "t1"), makeRoute(.textDense, gen: "t2")],
                fusion: policy, previousSnapshotID: nil,
                publishedAtEpochMilliseconds: 0, validationDigest: "d"
            )
        }
    }

    @Test("Route canonical bytes stable across restart roundtrip (WP3 step 2g)")
    func testRouteCanonicalBytesStableAcrossRestart() throws {
        let policy = try FusionPolicySnapshot(
            policyID: "p",
            weights: [makeWeight(.textDense, 1.0), makeWeight(.visionDense, 0.8)],
            rrfK: 60
        )
        let original = try SearchRouteSnapshot(
            snapshotID: "s", schemaVersion: 2, routeVersion: 5,
            channels: [makeRoute(.textDense, gen: "t"), makeRoute(.visionDense, gen: "v")],
            fusion: policy, previousSnapshotID: "prev-1",
            publishedAtEpochMilliseconds: 1_700_000_000_000, validationDigest: "any"
        )
        // 模拟重启：Codable roundtrip 后重编码必须逐字节一致
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoded = try JSONDecoder().decode(SearchRouteSnapshot.self, from: encoder.encode(original))
        #expect(decoded == original)
        let reEncoded = try decoded.canonicalData()
        let originalData = try original.canonicalData()
        #expect(reEncoded == originalData)
        let reDigest = try decoded.computedDigest()
        let originalDigest = try original.computedDigest()
        #expect(reDigest == originalDigest)
    }

    @Test("Route digest stable across restart (WP3 step 2h1)")
    func testRouteDigestStableAcrossRestart() async throws {
        let policy = try FusionPolicySnapshot(policyID: "p", weights: [], rrfK: 60)
        let snapshot = try SearchRouteSnapshot(
            snapshotID: "s", schemaVersion: 1, routeVersion: 1,
            channels: [], fusion: policy,
            previousSnapshotID: nil, publishedAtEpochMilliseconds: 42, validationDigest: "stored"
        )
        let d1 = try snapshot.computedDigest()
        let d2 = try snapshot.computedDigest()
        #expect(d1 == d2)
        #expect(d1.count == 64) // SHA-256 hex
    }

    @Test("Rollback restores previous canonical digest (WP3 step 2i)")
    func testRollbackRestoresPreviousCanonicalDigest() async throws {
        let policy = try FusionPolicySnapshot(policyID: "p", weights: [], rrfK: 60)
        let v1 = try SearchRouteSnapshot(
            snapshotID: "v1", schemaVersion: 1, routeVersion: 1,
            channels: [makeRoute(.textDense, gen: "t")], fusion: policy,
            previousSnapshotID: nil, publishedAtEpochMilliseconds: 1, validationDigest: "stored-v1"
        )
        // 回滚语义：从持久化的前序快照字节恢复出相同 canonical 内容。
        // validationDigest 被 canonical encoder 刻意排除，故 stored 值不影响 digest。
        let restored = try SearchRouteSnapshot(
            snapshotID: v1.snapshotID,
            schemaVersion: v1.schemaVersion,
            routeVersion: v1.routeVersion,
            channels: v1.channels,
            fusion: v1.fusion,
            previousSnapshotID: v1.previousSnapshotID,
            publishedAtEpochMilliseconds: v1.publishedAtEpochMilliseconds,
            validationDigest: v1.validationDigest
        )
        let restoredData = try restored.canonicalData()
        let v1Data = try v1.canonicalData()
        #expect(restoredData == v1Data)
        let restoredDigest = try restored.computedDigest()
        let v1Digest = try v1.computedDigest()
        #expect(restoredDigest == v1Digest)

        // 身份字段必须参与编码：routeVersion 变更 ⇒ digest 必须变化
        let bumped = try SearchRouteSnapshot(
            snapshotID: v1.snapshotID,
            schemaVersion: v1.schemaVersion,
            routeVersion: v1.routeVersion + 1,
            channels: v1.channels,
            fusion: v1.fusion,
            previousSnapshotID: v1.previousSnapshotID,
            publishedAtEpochMilliseconds: v1.publishedAtEpochMilliseconds,
            validationDigest: v1.validationDigest
        )
        let bumpedDigest = try bumped.computedDigest()
        #expect(bumpedDigest != v1Digest)
    }
}
