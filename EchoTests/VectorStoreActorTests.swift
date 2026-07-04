// ==========================================
// 文件: VectorStoreActorTests.swift
// 对应规格: docs/02-architecture/技术选型文档.md §4 (端侧向量数据库)
//            docs/02-architecture/架构设计文档.md §4.2, §4.3
// 任务: 1.3 - 集成向量数据库，封装 VectorStoreActor
// AC 覆盖: N/A (基础设施任务，非用户故事驱动)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-007/R-008
// 生成时间: 2026-07-04
// ==========================================

import Testing
import Foundation
import ProximaKit
@testable import Echo

// MARK: - Vector Store Actor Unit Tests

@Suite("VectorStoreActor")
struct VectorStoreActorTests {

    // MARK: - Fixtures

    /// Creates a fresh in-memory VectorStoreActor for each test
    func makeSUT(dimension: Int = 768) -> VectorStoreActor {
        VectorStoreActor(dimension: dimension)
    }

    /// Creates a random normalized vector for cosine similarity testing
    func randomVector(dimension: Int = 768) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        return (0..<dimension).map { _ in Float.random(in: -1...1, using: &rng) }
    }

    // MARK: - Initialization Tests

    @Test("init creates actor with specified dimension")
    func test_init_createsActorWithDimension() {
        let sut = makeSUT(dimension: 128)
        #expect(sut.dimension == 128)
    }

    @Test("init creates actor with default 768 dimensions")
    func test_init_defaultDimension() {
        let sut = makeSUT()
        #expect(sut.dimension == 768)
    }

    @Test("init produces empty index")
    func test_init_emptyIndex() async {
        let sut = makeSUT()
        let isEmpty = await sut.isEmpty
        #expect(isEmpty == true)
        let liveCount = await sut.liveCount
        #expect(liveCount == 0)
    }

    // MARK: - Ingest Tests

    @Test("ingest single vector succeeds and increments liveCount")
    func test_ingest_singleVector_succeeds() async throws {
        let sut = makeSUT(dimension: 3)
        let vec: [Float] = [1.0, 0.0, 0.0]

        try await sut.ingest(vector: vec, id: UUID())

        let liveCount = await sut.liveCount
        #expect(liveCount == 1)
    }

    @Test("ingest with metadata stores recoverable data")
    func test_ingest_withMetadata_storesData() async throws {
        let sut = makeSUT(dimension: 3)
        let id = UUID()
        let metadata = try JSONEncoder().encode(["label": "test"])

        try await sut.ingest(vector: [1.0, 0.0, 0.0], id: id, metadata: metadata)

        let results = await sut.search(query: [1.0, 0.0, 0.0], k: 1)
        #expect(results.count == 1)
        #expect(results[0].id == id)

        #expect(results[0].metadata != nil)
    }

    @Test("ingest with dimension mismatch throws")
    func test_ingest_dimensionMismatch_throws() async {
        let sut = makeSUT(dimension: 3)
        let wrongVec: [Float] = [1.0, 0.0] // 2-dim, expected 3

        do {
            try await sut.ingest(vector: wrongVec, id: UUID())
            #expect(Bool(false), "Expected VectorStoreError.dimensionMismatch but no error was thrown")
        } catch is Echo.VectorStoreError {
            // Expected
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("ingest replaces existing vector with same ID")
    func test_ingest_duplicateID_replaces() async throws {
        let sut = makeSUT(dimension: 3)
        let id = UUID()
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [0.0, 1.0, 0.0]

        try await sut.ingest(vector: v1, id: id)
        try await sut.ingest(vector: v2, id: id)

        let liveCount = await sut.liveCount
        #expect(liveCount == 1)

        // Search with v2 should return high similarity
        let results = await sut.search(query: v2, k: 1)
        #expect(results.count == 1)
        #expect(results[0].id == id)
    }

    // MARK: - Batch Ingest Tests

    @Test("batchIngest inserts multiple vectors atomically")
    func test_batchIngest_multipleVectors_succeeds() async throws {
        let sut = makeSUT(dimension: 3)
        let entries: [(vector: [Float], id: UUID, metadata: Data?)] = [
            ([1.0, 0.0, 0.0], UUID(), nil),
            ([0.0, 1.0, 0.0], UUID(), nil),
            ([0.0, 0.0, 1.0], UUID(), nil),
        ]

        try await sut.batchIngest(entries)

        let liveCount = await sut.liveCount
        #expect(liveCount == 3)
    }

    @Test("batchIngest with empty array is no-op")
    func test_batchIngest_emptyArray_noop() async throws {
        let sut = makeSUT()
        try await sut.batchIngest([])
        let liveCount = await sut.liveCount
        #expect(liveCount == 0)
    }

    // MARK: - Search Tests

    @Test("search returns correct nearest neighbor")
    func test_search_cosineSimilarity_returnsNearest() async throws {
        let sut = makeSUT(dimension: 2)
        // Insert three vectors
        try await sut.ingest(vector: [1.0, 0.0], id: UUID())   // A: east
        try await sut.ingest(vector: [0.0, 1.0], id: UUID())   // B: north
        try await sut.ingest(vector: [-1.0, 0.0], id: UUID())  // C: west

        // Query pointing east — should return A first
        let results = await sut.search(query: [1.0, 0.1], k: 3)
        #expect(results.count == 3)
        // Results sorted by distance ascending (cosine: lower = more similar)
        #expect(results[0].distance < results[1].distance)
        #expect(results[1].distance < results[2].distance)
    }

    @Test("search on empty index returns empty array")
    func test_search_emptyIndex_returnsEmpty() async {
        let sut = makeSUT()
        let results = await sut.search(query: randomVector(), k: 5)
        #expect(results.isEmpty)
    }

    @Test("search with k larger than index returns all vectors")
    func test_search_kLargerThanIndex_returnsAll() async throws {
        let sut = makeSUT(dimension: 2)
        try await sut.ingest(vector: [1.0, 0.0], id: UUID())
        try await sut.ingest(vector: [0.0, 1.0], id: UUID())

        let results = await sut.search(query: [0.5, 0.5], k: 10)
        #expect(results.count == 2)
    }

    @Test("search with filter excludes filtered IDs")
    func test_search_withFilter_excludesFiltered() async throws {
        let sut = makeSUT(dimension: 2)
        let idA = UUID()
        let idB = UUID()
        try await sut.ingest(vector: [1.0, 0.0], id: idA)
        try await sut.ingest(vector: [-1.0, 0.0], id: idB)

        let results = await sut.search(query: [1.0, 0.0], k: 5) { $0 != idA }
        // filtered out idA, should only return idB
        #expect(results.count == 1)
        #expect(results[0].id == idB)
    }

    @Test("search returns results with correct SearchResult shape")
    func test_search_resultShape() async throws {
        let sut = makeSUT(dimension: 2)
        let id = UUID()
        let metadata = try JSONEncoder().encode(["key": "value"])
        try await sut.ingest(vector: [1.0, 0.0], id: id, metadata: metadata)

        let results = await sut.search(query: [1.0, 0.0], k: 1)
        #expect(results.count == 1)
        #expect(results[0].id == id)
        #expect(results[0].distance >= 0)
        #expect(results[0].distance <= 2.0) // cosine range [0, 2]
        #expect(results[0].metadata != nil)
    }

    // MARK: - Delete Tests

    @Test("delete existing ID removes vector and decrements liveCount")
    func test_delete_existing_removesVector() async throws {
        let sut = makeSUT(dimension: 2)
        let id = UUID()
        try await sut.ingest(vector: [1.0, 0.0], id: id)
        #expect(await sut.liveCount == 1)

        let deleted = await sut.delete(id: id)
        #expect(deleted == true)
        #expect(await sut.liveCount == 0)

        // Search should not return deleted vector
        let results = await sut.search(query: [1.0, 0.0], k: 1)
        #expect(results.isEmpty)
    }

    @Test("delete non-existent ID returns false")
    func test_delete_nonExistent_returnsFalse() async {
        let sut = makeSUT()
        let deleted = await sut.delete(id: UUID())
        #expect(deleted == false)
    }

    // MARK: - Persistence Tests

    @Test("save and load round-trip preserves all vectors")
    func test_saveLoad_roundTrip_preservesVectors() async throws {
        let sut = makeSUT(dimension: 2)
        let idA = UUID()
        let idB = UUID()
        try await sut.ingest(vector: [1.0, 0.0], id: idA)
        try await sut.ingest(vector: [0.0, 1.0], id: idB)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_vectorstore_\(UUID().uuidString).pxkt")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await sut.save(to: tempURL)
        let loaded = try VectorStoreActor.load(from: tempURL)

        #expect(await loaded.liveCount == 2)
        let results = await loaded.search(query: [1.0, 0.0], k: 2)
        #expect(results.count == 2)
    }

    @Test("save and load preserves metadata")
    func test_saveLoad_preservesMetadata() async throws {
        let sut = makeSUT(dimension: 2)
        let id = UUID()
        let metadata = try JSONEncoder().encode(["type": "image", "source": "camera"])
        try await sut.ingest(vector: [1.0, 0.0], id: id, metadata: metadata)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_metadata_\(UUID().uuidString).pxkt")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await sut.save(to: tempURL)
        let loaded = try VectorStoreActor.load(from: tempURL)

        let results = await loaded.search(query: [1.0, 0.0], k: 1)
        #expect(results.count == 1)
        #expect(results[0].id == id)
        #expect(results[0].metadata == metadata)
    }

    @Test("loading from non-existent file throws")
    func test_load_nonExistentFile_throws() {
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).pxkt")

        do {
            let _ = try VectorStoreActor.load(from: badURL)
            #expect(Bool(false), "Expected VectorStoreError.persistenceFailed but no error was thrown")
        } catch is Echo.VectorStoreError {
            // Expected
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    // MARK: - Concurrency Safety Tests

    @Test("concurrent searches on same actor do not deadlock or crash")
    func test_concurrentSearches_noDeadlock() async throws {
        let sut = makeSUT(dimension: 4)
        // Insert some vectors
        for _ in 0..<50 {
            let vec = (0..<4).map { _ in Float.random(in: -1...1) }
            try await sut.ingest(vector: vec, id: UUID())
        }

        // Run 10 concurrent searches
        let query = randomVector(dimension: 4)
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let results = await sut.search(query: query, k: 5)
                    return results.count
                }
            }
            var totalResults = 0
            for await count in group {
                totalResults += count
            }
            #expect(totalResults == 50) // 10 searches × 5 results each
        }
    }

    @Test("concurrent reads while writing does not crash")
    func test_concurrentReadWrite_noCrash() async throws {
        let sut = makeSUT(dimension: 4)
        // Pre-populate
        for _ in 0..<20 {
            try await sut.ingest(vector: randomVector(dimension: 4), id: UUID())
        }

        await withTaskGroup(of: Void.self) { group in
            // Writer: add 10 more vectors
            group.addTask {
                for _ in 0..<10 {
                    try? await sut.ingest(vector: VectorStoreActorTests().randomVector(dimension: 4), id: UUID())
                }
            }
            // Readers: 5 concurrent searches
            for _ in 0..<5 {
                group.addTask {
                    for _ in 0..<10 {
                        let _ = await sut.search(query: VectorStoreActorTests().randomVector(dimension: 4), k: 5)
                    }
                }
            }
        }

        // Should reach here without crashing
        let liveCount = await sut.liveCount
        #expect(liveCount >= 20)
        #expect(liveCount <= 30)
    }
}
