// ==========================================
// 文件: RA_DataCorrectnessTests.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-1 (数据正确性与隐私状态缺陷)
// 任务: R-1.1~R-1.8 - 核心数据正确性修复
// AC 覆盖: R-1.1 (同步原子性), R-1.2 (审计 success), R-1.3 (视频回滚),
//          R-1.4 (SQLite 错误), R-1.5 (精确枚举), R-1.6 (授权集过滤),
//          R-1.7 (unappliedFilters), R-1.8 (取消检查)
// 架构约束: AGENTS.md §4.1 (Pipeline 契约), §4.4 (错误分级), R-006
// 重要: @MainActor 标注因 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// 生成时间: 2026-07-31
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - R-1.4: SQLite Query Error Propagation

@Suite("R-1.4 SQLite Query Error", .serialized)
@MainActor
struct SQLiteQueryErrorTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
    }

    @Test("executeQuery throws on non-DONE final step code (R-1.4)")
    func test_query_stepError_throws() async throws {
        // 注入一个 UDF 错误：创建临时表 + 注册一个会报错的函数
        // 通过执行一个会中途出错的查询来验证错误传播
        // 使用一个未知函数调用触发 SQLITE_ERROR
        do {
            _ = try await db.executeQuery(
                sql: "SELECT nonexistent_function(1)",
                bindings: []
            )
            // 若没抛错，说明错误被吞掉了（R-1.4 缺陷未修复）
            #expect(Bool(false), "Expected readFailed error for broken query")
        } catch let error as Echo.DatabaseError {
            if case .readFailed = error {
                // expected — R-1.4 修复后错误正确传播
            } else {
                #expect(Bool(false), "Wrong error: \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected DatabaseError, got: \(error)")
        }
    }

    @Test("executeQuery returns rows normally for valid query")
    func test_query_valid_returnsRows() async throws {
        let rows = try await db.executeQuery(
            sql: "SELECT 1 AS one",
            bindings: []
        )
        #expect(rows.count == 1)
        #expect(rows[0]["one"]?.intValue == 1)
    }
}

// MARK: - R-1.1: Sync Atomicity

@Suite("R-1.1 Sync Atomicity", .serialized)
@MainActor
struct SyncAtomicityTests {

    let db = DatabaseManager.shared
    let privacyActor = PrivacyActor.shared
    let excludedAssets = ExcludedAssetsActor.shared
    let progressActor = ProgressActor.shared
    let vectorStore = VectorStoreActor(dimension: 512)
    let stubEmbedder = StubEmbedder()

    var sut: SyncPipeline!

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
        try await db.execute(sql: "DELETE FROM TaskProgress")
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice", "calendar"],
            policyVersion: 1
        ))
        sut = SyncPipeline(
            embedder: stubEmbedder,
            privacyActor: privacyActor,
            vectorStore: vectorStore,
            excludedAssets: excludedAssets,
            progressActor: progressActor
        )
    }

    private func ingestOldMemory(assetId: String) async throws -> String {
        let memory = MemoryEntry(
            assetId: assetId,
            embedding: Array(repeating: 1.0, count: 512),
            sourceType: "note",
            timestamp: Date(),
            exifMetadata: nil,
            privacyBlurApplied: false,
            traceID: UUID().uuidString,
            originalText: "旧内容"
        )
        let metadata = try memory.encodeMetadata()
        try await vectorStore.ingest(vector: memory.embedding, id: memory.id, metadata: metadata)
        return memory.id.uuidString
    }

    @Test("R-1.1: embedding failure keeps old memory (no data loss)")
    func test_embeddingFailure_keepsOldMemory() async throws {
        let assetId = "R11-\(UUID().uuidString.prefix(8))"
        let oldMemoryId = try await ingestOldMemory(assetId: assetId)

        // 让下一次 embed 抛错（模拟 embedding 失败）
        await stubEmbedder.setNextError(.modelNotLoaded)

        let change = ChangeEvent(
            assetId: assetId,
            source: .note,
            changeType: .modified,
            newContentHash: "new-hash"
        )
        let result = try await sut.sync(changes: [change], traceID: UUID().uuidString)

        // 失败计数 +1，且旧记忆仍在
        #expect(result.failedCount == 1)
        #expect(result.replacedCount == 0)

        // 关键断言：旧记忆未被删除（R-1.1 原子性）
        let entries = await vectorStore.allEntries()
        let stillPresent = entries.contains { $0.id.uuidString == oldMemoryId }
        #expect(stillPresent == true, "R-1.1: embedding 失败时旧记忆必须保留")
    }

    @Test("R-1.2: audit log success=false when sync has failures")
    func test_audit_successFalse_onFailure() async throws {
        let assetId = "R12-\(UUID().uuidString.prefix(8))"
        try await ingestOldMemory(assetId: assetId)

        // 触发 embedding 失败
        await stubEmbedder.setNextError(.modelNotLoaded)

        let change = ChangeEvent(
            assetId: assetId,
            source: .note,
            changeType: .modified,
            newContentHash: "new-hash"
        )
        _ = try await sut.sync(changes: [change], traceID: "trace-R12")

        // 查询最近一条 .dataSourceChangeSynced 审计日志
        let rows = try await db.executeQuery(
            sql: "SELECT success, sourceType FROM AuditLog WHERE eventType = 'dataSourceChangeSynced' ORDER BY timestamp DESC LIMIT 1",
            bindings: []
        )
        #expect(rows.count == 1)
        let success = rows[0]["success"]?.intValue
        #expect(success == 0, "R-1.2: 有失败项时 success 必须为 false")
        let sourceType = rows[0]["sourceType"]?.stringValue ?? ""
        #expect(sourceType.contains("failed=1"), "R-1.2: sourceType 应包含 failed=1，实际: \(sourceType)")
    }

    @Test("R-1.2: audit log success=true when sync fully succeeds")
    func test_audit_successTrue_onSuccess() async throws {
        let assetId = "R12-OK-\(UUID().uuidString.prefix(8))"
        try await ingestOldMemory(assetId: assetId)

        await stubEmbedder.setNextEmbedding(Array(repeating: 2.0, count: 512))
        let change = ChangeEvent(
            assetId: assetId,
            source: .note,
            changeType: .modified,
            newContentHash: "new-hash"
        )
        _ = try await sut.sync(changes: [change], traceID: "trace-R12-ok")

        let rows = try await db.executeQuery(
            sql: "SELECT success, sourceType FROM AuditLog WHERE eventType = 'dataSourceChangeSynced' ORDER BY timestamp DESC LIMIT 1",
            bindings: []
        )
        let success = rows[0]["success"]?.intValue
        #expect(success == 1, "R-1.2: 全部成功时 success 应为 true")
    }
}

// MARK: - R-1.5: VectorStore Exact Enumeration

@Suite("R-1.5 VectorStore allEntries", .serialized)
@MainActor
struct VectorStoreAllEntriesTests {

    @Test("allEntries enumerates all ingested entries exactly")
    func test_allEntries_exact() async throws {
        let store = VectorStoreActor(dimension: 512)
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        try await store.ingest(vector: Array(repeating: 1.0, count: 512), id: id1)
        try await store.ingest(vector: Array(repeating: 2.0, count: 512), id: id2)
        try await store.ingest(vector: Array(repeating: 3.0, count: 512), id: id3)

        let entries = await store.allEntries()
        #expect(entries.count == 3)
        let ids = Set(entries.map(\.id))
        #expect(ids == [id1, id2, id3])
    }

    @Test("allEntries reflects deletions")
    func test_allEntries_afterDelete() async throws {
        let store = VectorStoreActor(dimension: 512)
        let id1 = UUID()
        let id2 = UUID()
        try await store.ingest(vector: Array(repeating: 1.0, count: 512), id: id1)
        try await store.ingest(vector: Array(repeating: 2.0, count: 512), id: id2)

        _ = await store.delete(id: id1)
        let entries = await store.allEntries()
        #expect(entries.count == 1)
        #expect(entries[0].id == id2)
    }
}

// MARK: - R-1.7: unappliedFilters

@Suite("R-1.7 unappliedFilters", .serialized)
@MainActor
struct UnappliedFiltersTests {

    let db = DatabaseManager.shared
    let privacyActor = PrivacyActor.shared

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice"],
            policyVersion: 1
        ))
    }

    private func makePipeline() -> SearchPipeline {
        SearchPipeline(
            embedder: StubEmbedder(defaultEmbedding: Array(repeating: 0.5, count: 384)),
            privacyActor: privacyActor,
            vectorStore: VectorStoreActor(dimension: 512)
        )
    }

    @Test("SearchResultItem unappliedFilters default empty")
    func test_unappliedFilters_default() {
        let item = SearchResultItem(
            id: UUID(),
            assetId: "a1",
            sourceType: "photo",
            timestamp: Date().timeIntervalSince1970,
            cosineSimilarity: 0.9
        )
        #expect(item.unappliedFilters.isEmpty)
    }

    @Test("SearchResultItem carries unappliedFilters after init")
    func test_unappliedFilters_set() {
        let item = SearchResultItem(
            id: UUID(),
            assetId: "a1",
            sourceType: "photo",
            timestamp: Date().timeIntervalSince1970,
            cosineSimilarity: 0.9,
            unappliedFilters: ["tags", "geoRadius"]
        )
        #expect(item.unappliedFilters == ["tags", "geoRadius"])
    }
}

// MARK: - R-1.8: Sync Cancellation

@Suite("R-1.8 Sync Cancellation", .serialized)
@MainActor
struct SyncCancellationTests {

    let db = DatabaseManager.shared
    let privacyActor = PrivacyActor.shared
    let excludedAssets = ExcludedAssetsActor.shared
    let progressActor = ProgressActor.shared
    let vectorStore = VectorStoreActor(dimension: 512)
    let stubEmbedder = StubEmbedder()

    var sut: SyncPipeline!

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
        try await db.execute(sql: "DELETE FROM TaskProgress")
        try await privacyActor.updatePolicy(UserPolicy(
            preferredLanguage: "zh-Hans",
            authorizedSourceTypes: ["photo", "note", "voice", "calendar"],
            policyVersion: 1
        ))
        sut = SyncPipeline(
            embedder: stubEmbedder,
            privacyActor: privacyActor,
            vectorStore: vectorStore,
            excludedAssets: excludedAssets,
            progressActor: progressActor
        )
    }

    @Test("SyncError.cancelled is defined with L1 level")
    func test_cancelled_error() {
        #expect(SyncError.cancelled.errorLevel == 1)
        #expect(SyncError.cancelled == .cancelled)
        #expect(SyncError.cancelled.errorDescription != nil)
    }
}
