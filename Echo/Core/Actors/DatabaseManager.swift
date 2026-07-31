// ==========================================
// 文件: DatabaseManager.swift
// 对应规格: docs/02-architecture/架构设计文档.md §5.1 (存储层次), §4.2 (Actor 隔离)
//            AGENTS.md §5 (数据持久化契约)
// 任务: 1.4 - 集成 SQLite，创建 ExcludedAssets, Feedback, TaskProgress, PendingOperations 表
// 架构约束: 遵循 AGENTS.md §4.2 (Actor 隔离契约), R-007 (禁止 @unchecked Sendable)
// 生成时间: 2026-07-04
// ==========================================

import Foundation
import SQLite3

// MARK: - Database Manager Actor

/// 共享 SQLite 数据库连接管理器 — 提供线程安全的数据库连接，负责建表与 WAL 模式配置。
///
/// ## Actor 隔离契约 (AGENTS.md §4.2)
/// - 可变状态封装: SQLite3 连接句柄指针封装在 Actor 中
/// - 串行执行: 同一 Actor 的操作串行执行，无数据竞争
/// - 所有 SQLite 写操作通过此 Actor 的串行队列执行
/// - OpaquePointer (SQL语句句柄) 不跨 Actor 传递，所有 SQL 操作内聚
///
/// ## 设计决策
/// - 使用系统 SQLite3（零外部依赖），通过 actor 保证线程安全
/// - WAL 模式：支持并发读，写入串行化
/// - 数据库文件路径：`<AppSupport>/Echo/db.sqlite`，NSFileProtectionComplete
public actor DatabaseManager {

    // MARK: - Singleton

    public static let shared = DatabaseManager()

    // MARK: - Properties

    private var db: OpaquePointer?
    private let dbURL: URL

    /// SQLite 版本号（运行时诊断用）
    public nonisolated var sqliteVersion: String {
        String(cString: sqlite3_libversion())
    }

    // MARK: - Initialization

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let echoDir = appSupport.appendingPathComponent("Echo", isDirectory: true)
        try? FileManager.default.createDirectory(at: echoDir, withIntermediateDirectories: true)
        self.dbURL = echoDir.appendingPathComponent("db.sqlite")
    }

    // MARK: - Connection Management

    /// 打开数据库连接（WAL 模式，NSFileProtectionComplete）
    public func open() async throws {
        guard sqlite3_open_v2(
            dbURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FILEPROTECTION_COMPLETE,
            nil
        ) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DatabaseError.connectionFailed(underlying: NSError(domain: "sqlite3", code: -1, userInfo: [NSLocalizedDescriptionKey: msg]))
        }
        try execute(sql: "PRAGMA journal_mode=WAL")
        try execute(sql: "PRAGMA foreign_keys=ON")
        try createAllTables()
    }

    public func close() {
        if let db = db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    // MARK: - Table Creation

    private func createAllTables() throws {
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS ExcludedAssets (
                assetId TEXT PRIMARY KEY NOT NULL,
                sourceType TEXT NOT NULL,
                excludedAt INTEGER NOT NULL
            )
            """)
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS FeedbackStore (
                feedbackId TEXT PRIMARY KEY NOT NULL,
                memoryId TEXT NOT NULL,
                queryText TEXT NOT NULL,
                sentiment TEXT NOT NULL,
                cosineSimilarity REAL NOT NULL,
                createdAt REAL NOT NULL,
                isBadCase INTEGER NOT NULL DEFAULT 0,
                badCaseReason TEXT
            )
            """)
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS TaskProgress (
                taskId TEXT PRIMARY KEY NOT NULL,
                taskType TEXT NOT NULL,
                lastProcessedId TEXT,
                lastProcessedIndex INTEGER NOT NULL DEFAULT 0,
                totalCount INTEGER NOT NULL DEFAULT 0,
                resumeData BLOB,
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL
            )
            """)
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS PendingOperations (
                operationId TEXT PRIMARY KEY NOT NULL,
                operationType TEXT NOT NULL,
                retryCount INTEGER NOT NULL DEFAULT 0,
                parameters BLOB NOT NULL,
                createdAt REAL NOT NULL,
                lastError TEXT
            )
            """)
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS AuditLog (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                eventType TEXT NOT NULL,
                timestamp REAL NOT NULL,
                traceID TEXT NOT NULL,
                policyVersion INTEGER NOT NULL DEFAULT 1,
                success INTEGER NOT NULL DEFAULT 1,
                sourceType TEXT,
                affectedCount INTEGER,
                excludedWritten INTEGER,
                sourceLanguage TEXT,
                elapsedMs INTEGER
            )
            """)
        try execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_auditlog_timestamp ON AuditLog(timestamp)
            """)
        // v2 schema migration: add video-specific audit fields (US-ING-005 AC-5, Task 2.4)
        // Idempotent: silently skip if columns already exist (SQLite rejects duplicate ADD COLUMN)
        try? execute(sql: "ALTER TABLE AuditLog ADD COLUMN frameCount INTEGER")
        try? execute(sql: "ALTER TABLE AuditLog ADD COLUMN audioTranscriptLength INTEGER")
        try? execute(sql: "ALTER TABLE AuditLog ADD COLUMN hasAudio INTEGER")
        // UserPolicy persistence table
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS UserPolicyStore (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                preferredLanguage TEXT NOT NULL DEFAULT 'zh-Hans',
                authorizedSourceTypes TEXT NOT NULL DEFAULT '["photo","note","voice"]',
                policyVersion INTEGER NOT NULL DEFAULT 1,
                updatedAt REAL NOT NULL
            )
            """)
        // ── v3 schema migration: ModelManifest / IndexGeneration / ActiveRouteSet (R-A) ──
        // 规范 Memory 表 (R-A.1): canonical facts source
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS Memory (
                memoryId TEXT PRIMARY KEY NOT NULL,
                sourceLocator TEXT NOT NULL,
                canonicalText TEXT,
                sourceType TEXT NOT NULL,
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL,
                recoverability TEXT NOT NULL DEFAULT 'full'
            )
            """)
        // 一个记忆的多种表示 (R-A.1): modality-specific representations
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS Representation (
                representationId TEXT PRIMARY KEY NOT NULL,
                memoryId TEXT NOT NULL REFERENCES Memory(memoryId) ON DELETE CASCADE,
                modality TEXT NOT NULL,
                preprocessVersion TEXT NOT NULL,
                contentHash TEXT NOT NULL
            )
            """)
        // 模型身份与许可登记 (R-A.2)
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS ModelManifest (
                modelId TEXT PRIMARY KEY NOT NULL,
                revision TEXT NOT NULL,
                artifactHash TEXT NOT NULL,
                licenseId TEXT NOT NULL,
                runtime TEXT NOT NULL,
                tokenizer TEXT,
                promptTemplate TEXT,
                pooling TEXT NOT NULL DEFAULT 'none',
                normalization TEXT NOT NULL DEFAULT 'none',
                dimension INTEGER NOT NULL,
                quantization TEXT
            )
            """)
        // 分代索引管理 (R-A.3): single model space per generation
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS IndexGeneration (
                generationId TEXT PRIMARY KEY NOT NULL,
                indexType TEXT NOT NULL,
                manifestId TEXT,
                dimension INTEGER NOT NULL DEFAULT 512,
                state TEXT NOT NULL DEFAULT 'building',
                counts INTEGER NOT NULL DEFAULT 0,
                validationDigest TEXT
            )
            """)
        // v3.1 schema migration: add dimension column to IndexGeneration
        // (existing DBs from initial R-A delivery lack this column)
        try? execute(sql: "ALTER TABLE IndexGeneration ADD COLUMN dimension INTEGER NOT NULL DEFAULT 512")
        // 逐项构建与恢复 (R-A.3)
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS IndexBuildItem (
                generationId TEXT NOT NULL REFERENCES IndexGeneration(generationId) ON DELETE CASCADE,
                representationId TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',
                error TEXT,
                retryCount INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (generationId, representationId)
            )
            """)
        // 原子服务路由 (R-A.4): single active route row
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS ActiveRouteSet (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                textGeneration TEXT NOT NULL,
                ocrGeneration TEXT,
                visionGeneration TEXT,
                lexicalGeneration TEXT,
                version INTEGER NOT NULL DEFAULT 1,
                updatedAt REAL NOT NULL
            )
            """)
    }

    // MARK: - Generic SQL Execution

    func execute(sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw DatabaseError.tableCreationFailed(table: "<sql>", underlying: NSError(domain: "sqlite3", code: -1, userInfo: [NSLocalizedDescriptionKey: msg]))
        }
    }

    @discardableResult
    func executeWrite(sql: String, bindings: [DBBinding]) throws -> Int32 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: NSError(domain: "sqlite3", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]))
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.writeFailed(operation: "prepare", underlying: NSError(domain: "sqlite3", code: -1, userInfo: [NSLocalizedDescriptionKey: msg]))
        }
        defer { sqlite3_finalize(prepared) }
        for (i, binding) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch binding {
            case .text(let value): sqlite3_bind_text(prepared, idx, (value as NSString).utf8String, -1, nil)
            case .int(let value): sqlite3_bind_int64(prepared, idx, value)
            case .double(let value): sqlite3_bind_double(prepared, idx, value)
            case .blob(let data):
                data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(prepared, idx, bytes.baseAddress, Int32(data.count), nil)
                }
            case .null: sqlite3_bind_null(prepared, idx)
            }
        }
        guard sqlite3_step(prepared) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.writeFailed(operation: "step", underlying: NSError(domain: "sqlite3", code: -1, userInfo: [NSLocalizedDescriptionKey: msg]))
        }
        return sqlite3_changes(db)
    }

    func executeQuery(sql: String, bindings: [DBBinding]) throws -> [[String: DBValue]] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: NSError(domain: "sqlite3", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"]))
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.readFailed(operation: "prepare", underlying: NSError(domain: "sqlite3", code: -1, userInfo: [NSLocalizedDescriptionKey: msg]))
        }
        defer { sqlite3_finalize(prepared) }
        for (i, binding) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch binding {
            case .text(let value): sqlite3_bind_text(prepared, idx, (value as NSString).utf8String, -1, nil)
            case .int(let value): sqlite3_bind_int64(prepared, idx, value)
            case .double(let value): sqlite3_bind_double(prepared, idx, value)
            case .blob(let data):
                data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(prepared, idx, bytes.baseAddress, Int32(data.count), nil)
                }
            case .null: sqlite3_bind_null(prepared, idx)
            }
        }
        var rows: [[String: DBValue]] = []
        let columnCount = sqlite3_column_count(prepared)
        while sqlite3_step(prepared) == SQLITE_ROW {
            var row: [String: DBValue] = [:]
            for i in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(prepared, i))
                switch sqlite3_column_type(prepared, i) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(prepared, i))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(prepared, i))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(prepared, i)))
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(prepared, i) {
                        row[name] = .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(prepared, i))))
                    } else { row[name] = .null }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func databaseSize() -> Int64 {
        Int64((try? Data(contentsOf: dbURL).count) ?? 0)
    }
}

// MARK: - Database Binding & Value Types

public enum DBBinding: Sendable {
    case text(String)
    case int(Int64)
    case double(Double)
    case blob(Data)
    case null
}

public enum DBValue: Sendable {
    case text(String)
    case int(Int64)
    case double(Double)
    case blob(Data)
    case null

    public nonisolated var stringValue: String? { if case .text(let s) = self { return s }; return nil }
    public nonisolated var intValue: Int64? { if case .int(let i) = self { return i }; return nil }
    public nonisolated var doubleValue: Double? { if case .double(let d) = self { return d }; return nil }
    public nonisolated var blobValue: Data? { if case .blob(let d) = self { return d }; return nil }
    public nonisolated var isNull: Bool { if case .null = self { return true }; return false }
}
