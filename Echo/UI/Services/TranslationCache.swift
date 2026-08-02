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

/// 展示层翻译缓存 — TTL=7d (US-DIS-002 AC-5)。
///
/// 独立于 Core 存储 (translationCache 字段属 Core 模型，Phase 3.9 接入)。
/// 本 actor 提供展示层确定性的内存缓存，供 TranslationService 与 Preview/测试使用。
actor TranslationCache {
    /// 缓存条目
    struct Entry: Sendable, Equatable {
        /// 源文本（缓存键组成部分）
        let sourceText: String
        /// 源语言
        let sourceLanguage: String
        /// 目标语言
        let targetLanguage: String
        /// 译文
        let translatedText: String
        /// 置信度
        let confidence: Double
        /// 写入时间
        let cachedAt: Date
    }

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
    static func makeKey(
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
        confidence: Double
    ) {
        let entry = Entry(
            sourceText: sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            translatedText: translatedText,
            confidence: confidence,
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
