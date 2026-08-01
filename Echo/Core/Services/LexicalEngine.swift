// ==========================================
// 文件: LexicalEngine.swift
// 对应规格: Echo dev-1.0 缺陷修复计划.md → Phase R-3.6
//            调研报告 §9.3 (JiebaFTS5 + n-gram)
// 任务: R-3.6 - 中文词法通道（JiebaFTS5 + n-gram）
// AC 覆盖: JiebaFTS5 自定义 tokenizer、中文分词、FTS5 全文索引、
//          字符 bigram/trigram fallback、词法分数走 RRF 融合
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载)
// 状态: scaffold — 需 JiebaFTS5 C 扩展编译 + sqlite3_load_extension
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-01
// ==========================================

import Foundation

// MARK: - Lexical Engine Protocol

/// 词法搜索引擎协议 — 抽象全文检索，支持依赖注入与测试 Mock。
public protocol LexicalEngineProtocol: Sendable {
    /// 对文本执行词法搜索（BM25 排序）。
    ///
    /// - Parameters:
    ///   - query: 查询文本
    ///   - limit: 返回结果数量上限
    /// - Returns: 匹配的文档 ID 列表（按 BM25 分数降序）
    func search(query: String, limit: Int) async throws -> [String]

    /// 索引文档到 FTS5 全文索引。
    ///
    /// - Parameters:
    ///   - documentId: 文档唯一标识
    ///   - text: 文档文本内容
    func index(documentId: String, text: String) async throws
}

// MARK: - Lexical Error

/// 词法引擎统一错误类型
public enum LexicalError: Error, LocalizedError, Sendable {
    /// FTS5 扩展加载失败
    case extensionLoadFailed(reason: String)
    /// 分词失败
    case tokenizationFailed(reason: String)
    /// 搜索执行失败
    case searchFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .extensionLoadFailed(let reason):
            return "FTS5 extension load failed: \(reason)"
        case .tokenizationFailed(let reason):
            return "Tokenization failed: \(reason)"
        case .searchFailed(let error):
            return "Lexical search failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Lexical Engine

/// 中文词法搜索引擎（R-3.6）— JiebaFTS5 + 字符 n-gram fallback。
///
/// ## 架构
/// - JiebaFTS5：jieba 分词 + SQLite FTS5 自定义 tokenizer（C 扩展）
/// - 字符 bigram/trigram：未登录词 fallback（jieba 词典未覆盖的词汇）
/// - 词法分数不直接加到余弦分——走 RRF 融合（R-3.7）
///
/// ## 当前状态
/// Scaffold — 需要：
/// 1. JiebaFTS5 C 扩展编译为 dylib
/// 2. sqlite3_load_extension 加载
/// 3. FTS5 表创建（tokenize='jieba'）
/// 4. 字符 n-gram fallback 实现
public actor LexicalEngine: LexicalEngineProtocol {

    // MARK: - Constants

    /// FTS5 表名
    private nonisolated static let ftsTableName = "LexicalIndex"
    /// 字符 n-gram 大小（bigram + trigram）
    private nonisolated static let ngramSizes = [2, 3]

    // MARK: - Properties

    private let db: DatabaseManager
    private var extensionLoaded = false

    // MARK: - Initialization

    public init(db: DatabaseManager = .shared) {
        self.db = db
    }

    // MARK: - LexicalEngineProtocol

    /// 对文本执行词法搜索（BM25 排序）。
    public func search(query: String, limit: Int = 10) async throws -> [String] {
        // TODO (R-3.6): 完整实现
        // 1. try await ensureExtensionLoaded()
        // 2. let tokens = try tokenize(query)  // jieba 分词
        // 3. let ftsQuery = tokens.joined(separator: " OR ")
        // 4. let rows = try await db.executeQuery(
        //        sql: "SELECT documentId FROM \(Self.ftsTableName) WHERE \(Self.ftsTableName) MATCH ? ORDER BY rank LIMIT ?",
        //        bindings: [.text(ftsQuery), .int(Int64(limit))])
        // 5. return rows.compactMap { $0["documentId"]?.stringValue }
        throw LexicalError.extensionLoadFailed(reason: "JiebaFTS5 extension not yet integrated (R-3.6 scaffold)")
    }

    /// 索引文档到 FTS5 全文索引。
    public func index(documentId: String, text: String) async throws {
        // TODO (R-3.6): 完整实现
        // 1. try await ensureExtensionLoaded()
        // 2. try await db.executeWrite(
        //        sql: "INSERT OR REPLACE INTO \(Self.ftsTableName) (documentId, content) VALUES (?, ?)",
        //        bindings: [.text(documentId), .text(text)])
        throw LexicalError.extensionLoadFailed(reason: "JiebaFTS5 extension not yet integrated (R-3.6 scaffold)")
    }

    // MARK: - Extension Management

    /// 确保 JiebaFTS5 扩展已加载。
    private func ensureExtensionLoaded() async throws {
        guard !extensionLoaded else { return }
        // TODO (R-3.6): sqlite3_load_extension(db, "libjiebafts5", nil, nil)
        throw LexicalError.extensionLoadFailed(reason: "JiebaFTS5 dylib not yet compiled")
    }

    // MARK: - Tokenization

    /// 中文分词（jieba）+ 字符 n-gram fallback。
    ///
    /// 分词策略：
    /// 1. jieba 精确模式分词
    /// 2. 对未登录词（jieba 未识别）生成 bigram/trigram
    /// 3. 合并去重
    nonisolated func tokenize(_ text: String) -> [String] {
        // TODO (R-3.6): jieba 分词实现
        // 当前 fallback：字符 n-gram
        return characterNgrams(text)
    }

    /// 字符 n-gram 生成（bigram + trigram）。
    nonisolated func characterNgrams(_ text: String) -> [String] {
        let chars = Array(text)
        var ngrams: Set<String> = []
        for n in Self.ngramSizes {
            guard chars.count >= n else { continue }
            for i in 0...(chars.count - n) {
                ngrams.insert(String(chars[i..<(i + n)]))
            }
        }
        return Array(ngrams)
    }
}
