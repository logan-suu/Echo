// ==========================================
// 文件: PersistentTranslationCache.swift
// 对应规格: docs/decisions/ADR-013-creation-export-boundary.md → 决策 2 (七天持久缓存跨重启),
//            docs/01-spec/用户故事与验收标准规格书.md → US-DIS-002 AC-5 (TTL=7d),
//            docs/03-implementation/双语言实现说明文档.md §6.3 (translationCache, TTL=7d)
// 任务: 3F.9 - Apple Translation 与 grounded creation
// AC 覆盖: US-DIS-002 AC-5 ✅ (翻译成功写入缓存 TTL=7d, 持久化跨重启),
//          ADR-013 决策 2 ✅ (PersistentTranslationCache TTL=7d 持久化跨重启)
// 架构约束: 展示层缓存; actor 隔离; 文件持久化 (JSON) — 关闭 DEF-43-003 (内存缓存不跨重启);
//           可注入 directory + clock 保证确定性测试
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，struct 成员需 nonisolated
// 生成时间: 2026-08-11
// ==========================================

import Foundation

/// 持久化翻译缓存 — TTL=7d，跨重启存活 (US-DIS-002 AC-5, ADR-013 决策 2)。
///
/// ## 与内存 `TranslationCache` 的区别
/// - 内存缓存: Preview / 单元测试 / UI 切片确定性路径
/// - 持久缓存: 生产展示层路径 — 写入磁盘 JSON，App 重启后命中不重新请求 Apple Translation
///
/// ## 存储
/// - 文件: `<directory>/translation-cache.json`
/// - 结构: `[key: CacheEntry]`，key 与 `TranslationCache.makeKey` 一致
actor PersistentTranslationCache: TranslationCaching {
    /// 缓存条目 — 与内存缓存共享值类型 (Codable 磁盘持久化)
    typealias Entry = CachedTranslationEntry

    /// 存储目录（测试注入临时目录）
    private nonisolated let directory: URL
    /// TTL — 默认 7 天 (AC-5)
    private nonisolated let ttl: TimeInterval
    /// 时钟注入 — 测试确定性
    private nonisolated let clock: @Sendable () -> Date

    /// 内存缓存字典（首次访问时从磁盘惰性加载）
    private var storage: [String: Entry] = [:]
    /// 磁盘是否已加载 — 幂等惰性加载
    private var didLoadFromDisk = false

    /// 缓存文件路径
    nonisolated private var cacheFileURL: URL {
        directory.appendingPathComponent("translation-cache.json")
    }

    init(
        directory: URL,
        ttl: TimeInterval = 7 * 24 * 3600,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.ttl = ttl
        self.clock = clock
    }

    // MARK: - Disk Persistence

    /// 从磁盘加载缓存 — 启动时调用；文件缺失/损坏返回 nil（确定性降级为空缓存）。
    nonisolated private static func loadFromDisk(cacheFileURL: URL) -> [String: Entry]? {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode([String: Entry].self, from: data)
    }

    /// 写回磁盘 — store 后原子写入。
    private func persistToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(storage) else { return }
        try? data.write(to: cacheFileURL, options: .atomic)
    }

    /// 幂等惰性加载磁盘缓存 — 首次访问时执行；文件缺失/损坏保持空缓存。
    private func ensureLoaded() {
        guard !didLoadFromDisk else { return }
        didLoadFromDisk = true
        storage = Self.loadFromDisk(cacheFileURL: cacheFileURL) ?? [:]
    }

    // MARK: - Public API

    /// 查询缓存 — 未命中或已过期（超过 TTL）返回 nil，并清除过期条目。
    func lookup(key: String) -> Entry? {
        ensureLoaded()
        guard let entry = storage[key] else { return nil }
        let now = clock()
        guard now.timeIntervalSince(entry.cachedAt) < ttl else {
            storage.removeValue(forKey: key)
            persistToDisk()
            return nil
        }
        return entry
    }

    /// 写入缓存 — 以注入时钟记录写入时间，并持久化到磁盘。
    func store(
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String,
        translatedText: String,
        sourceLanguageConfidence: Double
    ) {
        ensureLoaded()
        let entry = Entry(
            sourceText: sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            translatedText: translatedText,
            sourceLanguageConfidence: sourceLanguageConfidence,
            cachedAt: clock()
        )
        storage[TranslationCache.makeKey(
            sourceText: sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )] = entry
        persistToDisk()
    }

    /// 当前缓存条目数 — 测试断言用。
    var count: Int {
        ensureLoaded()
        return storage.count
    }

    /// 缓存是否为空 — 测试断言用。
    var isEmpty: Bool {
        ensureLoaded()
        return storage.isEmpty
    }
}
