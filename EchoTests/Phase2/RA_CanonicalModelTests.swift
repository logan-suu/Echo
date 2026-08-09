// ==========================================
// 文件: RA_CanonicalModelTests.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-A (架构数据模型)
// 任务: R-A.1/R-A.2 - 规范 Memory/Representation + ModelManifest
// AC 覆盖: Memory/Representation 结构字段, Recoverability/Modality 枚举,
//          ModelManifest 字段与推理合同, model_manifest 表 CRUD
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007/R-008
// 生成时间: 2026-07-31
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - R-A.1: Canonical Memory & Representation Models

@Suite("R-A.1 Canonical Models", .serialized)
struct CanonicalModelTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
    }

    @Test("Memory initializer fills all canonical fields")
    func test_memory_initializer() {
        let memory = Memory(
            memoryId: UUID(),
            sourceLocator: "PHAsset.localIdentifier/abc123",
            canonicalText: "A memory summary",
            sourceType: "photo",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            recoverability: .partial
        )
        #expect(memory.sourceLocator == "PHAsset.localIdentifier/abc123")
        #expect(memory.canonicalText == "A memory summary")
        #expect(memory.sourceType == "photo")
        #expect(memory.recoverability == .partial)
    }

    @Test("Recoverability raw values round-trip")
    func test_recoverability_rawValues() {
        #expect(Recoverability.full.rawValue == "full")
        #expect(Recoverability.partial.rawValue == "partial")
        #expect(Recoverability.unrecoverable.rawValue == "unrecoverable")
        #expect(Recoverability(rawValue: "full") == .full)
    }

    @Test("Memory edit fields default to non-edited state (US-AWK-007)")
    func test_memory_edit_defaults() {
        let memory = Memory(
            sourceLocator: "PHAsset/d1",
            sourceType: "photo"
        )
        #expect(memory.originalTimestamp == nil)
        #expect(memory.userEdited == false)
        #expect(memory.userLocked == false)
    }

    @Test("Memory edit fields persist custom values (US-AWK-007 AC-2/4/6)")
    func test_memory_edit_fields() {
        let original = Date(timeIntervalSince1970: 1_600_000_000)
        let memory = Memory(
            sourceLocator: "PHAsset/d2",
            sourceType: "photo",
            originalTimestamp: original,
            userEdited: true,
            userLocked: true
        )
        #expect(memory.originalTimestamp == original)
        #expect(memory.userEdited == true)
        #expect(memory.userLocked == true)
    }

    @Test("Representation initializer fills modality-specific fields")
    func test_representation_initializer() {
        let rep = Representation(
            memoryId: UUID(),
            modality: .textDense,
            preprocessVersion: "e5-small-v1",
            contentHash: "sha256:abc"
        )
        #expect(rep.modality == .textDense)
        #expect(rep.preprocessVersion == "e5-small-v1")
        #expect(rep.contentHash == "sha256:abc")
    }

    @Test("Modality enum covers all planned channels")
    func test_modality_allCases() {
        #expect(Modality.allCases.count == 4)
        #expect(Modality.allCases.contains(.textDense))
        #expect(Modality.allCases.contains(.visionDense))
        #expect(Modality.allCases.contains(.ocrText))
        #expect(Modality.allCases.contains(.lexical))
    }
}

// MARK: - R-A.2: ModelManifest

@Suite("R-A.2 ModelManifest", .serialized)
struct ModelManifestActorTests {

    let sut = ModelManifestActor.shared
    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
        try await sut.removeAll()
    }

    func makeManifest(modelId: String = "e5-small-v1") -> ModelManifest {
        ModelManifest(
            modelId: modelId,
            revision: "833df7e",
            artifactHash: "sha256:test",
            licenseId: "research",
            runtime: .coreML,
            tokenizer: "sentencepiece",
            promptTemplate: "query: ",
            pooling: .maskedMean,
            normalization: .l2,
            dimension: 384,
            quantization: "none"
        )
    }

    @Test("register then loadAll returns the manifest")
    func test_register_loadAll() async throws {
        try await sut.register(makeManifest())
        let all = try await sut.loadAll()
        #expect(all.count == 1)
        #expect(all[0].modelId == "e5-small-v1")
        #expect(all[0].runtime == .coreML)
        #expect(all[0].dimension == 384)
        #expect(all[0].pooling == .maskedMean)
        #expect(all[0].normalization == .l2)
    }

    @Test("load by modelId returns specific manifest")
    func test_load_byId() async throws {
        try await sut.register(makeManifest(modelId: "mobileclip-v1"))
        let loaded = try await sut.load(modelId: "mobileclip-v1")
        #expect(loaded != nil)
        #expect(loaded?.revision == "833df7e")
        #expect(loaded?.promptTemplate == "query: ")
        #expect(loaded?.tokenizer == "sentencepiece")
    }

    @Test("load returns nil for unknown modelId")
    func test_load_unknown() async throws {
        let loaded = try await sut.load(modelId: "no-such-model")
        #expect(loaded == nil)
    }

    @Test("register same modelId twice updates (idempotent upsert)")
    func test_register_upsert() async throws {
        try await sut.register(makeManifest(modelId: "dup"))
        let updated = ModelManifest(
            modelId: "dup",
            revision: "new-rev",
            artifactHash: "sha256:new",
            licenseId: "mit",
            runtime: .coreML,
            dimension: 512
        )
        try await sut.register(updated)
        let loaded = try await sut.load(modelId: "dup")
        #expect(loaded?.revision == "new-rev")
        #expect(loaded?.dimension == 512)
        #expect(try await sut.loadAll().count == 1)
    }

    @Test("remove deletes manifest and returns true; second remove false")
    func test_remove() async throws {
        try await sut.register(makeManifest(modelId: "to-remove"))
        let removed = try await sut.remove(modelId: "to-remove")
        #expect(removed == true)
        #expect(try await sut.load(modelId: "to-remove") == nil)
        let second = try await sut.remove(modelId: "to-remove")
        #expect(second == false)
    }
}
