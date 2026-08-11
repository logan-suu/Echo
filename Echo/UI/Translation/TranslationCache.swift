// ==========================================
// 文件: TranslationCache.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-DIS-002 AC-5 (翻译成功后写入缓存，TTL=7d),
//            docs/03-implementation/双语言实现说明文档.md §6.3 (记忆详情页翻译缓存策略 TTL=7d)
// 任务: 3.8 - 跨语言翻译层集成
// AC 覆盖: US-DIS-002 AC-2 (优先查 translationCache), AC-5 (TTL=7d 写入缓存)
// 架构约束: 展示层缓存 (非 Core); actor 隔离; 可注入 clock 保证确定性测试
// 生成时间: 2026-08-02
// ==========================================

import Foundation

// MARK: - Shared Cache Entry

/// 展示层翻译缓存条目 — 内存缓存与持久缓存共用 (US-DIS-002 AC-5)。
struct CachedTranslationEntry: Sendable, Equatable, Codable {
    /// 源文本（缓存键组成部分）
    let sourceText: String
    /// 源语言
    let sourceLanguage: String
    /// 目标语言
    let targetLanguage: String
    /// 译文
    let translatedText: String
    /// 源语言检测置信度 (ADR-005)
    let sourceLanguageConfidence: Double
    /// 写入时间
    let cachedAt: Date
}

/// 翻译缓存契约 — 内存 (`TranslationCache`) 与持久 (`PersistentTranslationCache`) 统一接口。
protocol TranslationCaching: Sendable {
    /// 查询缓存 — 未命中或已过期返回 nil。
    func lookup(key: String) async -> CachedTranslationEntry?
    /// 写入缓存。
    func store(
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String,
        translatedText: String,
        sourceLanguageConfidence: Double
    ) async
    /// 当前缓存条目数。
    var count: Int { get async }
    /// 缓存是否为空。
    var isEmpty: Bool { get async }
}

/// 展示层翻译缓存 — TTL=7d (US-DIS-002 AC-5)。
///
/// 内存实现 — Preview / 单元测试 / UI 切片确定性路径。
/// 生产路径使用 `PersistentTranslationCache`（持久化跨重启，ADR-013 决策 2）。
actor TranslationCache: TranslationCaching {
    /// 缓存条目 — 共享值类型
    typealias Entry = CachedTranslationEntry

    /// 缓存字典 — 键为 `sourceLanguage|targetLanguage|sourceText` 哈希
    private var storage: [String: Entry] = [:]

    /// TTL — 默认 7 天 (AC-5)
    private let ttl: TimeInterval

    /// 时钟注入 — 测试确定性 (docs/ui/testing-and-artifacts.md §2.1)
    private let clock: @Sendable () -> Date

    init(
        ttl: TimeInterval = 7 * 24 * 3600,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ttl = ttl
        self.clock = clock
    }

    /// 生成缓存键 — 确定性 (sourceLanguage|targetLanguage|sourceText)
    nonisolated static func makeKey(
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String
    ) -> String {
        "\(sourceLanguage)|\(targetLanguage)|\(sourceText)"
    }

    /// 查询缓存 — 未命中或已过期 (超过 TTL) 返回 nil，并清除过期条目。
    func lookup(key: String) -> Entry? {
        guard let entry = storage[key] else { return nil }
        let now = clock()
        guard now.timeIntervalSince(entry.cachedAt) < ttl else {
            storage.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    /// 写入缓存 — 以注入时钟记录写入时间，保证 TTL 判定确定性。
    func store(
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String,
        translatedText: String,
        sourceLanguageConfidence: Double
    ) {
        let entry = Entry(
            sourceText: sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            translatedText: translatedText,
            sourceLanguageConfidence: sourceLanguageConfidence,
            cachedAt: clock()
        )
        storage[Self.makeKey(
            sourceText: sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )] = entry
    }

    /// 当前缓存条目数 — 测试断言用。
    var count: Int { storage.count }

    /// 缓存是否为空 — 测试断言用。
    var isEmpty: Bool { storage.isEmpty }
}
