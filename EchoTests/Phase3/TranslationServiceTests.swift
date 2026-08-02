// ==========================================
// 文件: TranslationServiceTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-DIS-002 (记忆详情按需翻译),
//            docs/03-implementation/双语言实现说明文档.md §6.3 (翻译缓存 TTL=7d)
// 任务: 3.8 - 跨语言翻译层集成
// AC 覆盖: US-DIS-002 AC-1 (展开详情触发), AC-2 (cache-first + service fallback),
//          AC-3 (置信度 <0.7 保留原文), AC-4 (原文/译文切换), AC-5 (缓存 TTL=7d)
// 架构约束: 展示层服务测试; 确定性 clock 注入; 无网络
// 生成时间: 2026-08-02
// ==========================================

import Testing
import Foundation
import os
@testable import Echo

// MARK: - FixtureTranslationService Tests

@Suite("FixtureTranslationService", .serialized)
@MainActor
struct FixtureTranslationServiceTests {

    private let service = FixtureTranslationService()

    @Test("US-DIS-002 AC-2: known zh-Hans text translates to en-US with detection confidence")
    func translatesKnownText() async throws {
        let result = try await service.translate(
            "昨晚在公园遇到一只橘猫，很亲人。它在我脚边蹭了很久，后来跟着我走了一段路。",
            from: "zh-Hans",
            to: "en-US"
        )
        #expect(result.translatedText.contains("orange tabby"))
        #expect(result.sourceLanguageConfidence == 0.95)
    }

    @Test("US-DIS-002 AC-3: low-confidence map entry returns sourceLanguageConfidence < 0.9")
    func returnsLowConfidence() async throws {
        let result = try await service.translate(
            "今天整个下午都在搞这个破项目，快崩了。",
            from: "zh-Hans",
            to: "en-US"
        )
        #expect(result.sourceLanguageConfidence < 0.9)
    }

    @Test("US-DIS-002 AC-2: unknown text throws L2 serviceUnavailable")
    func unknownTextThrows() async {
        await #expect(throws: TranslationError.serviceUnavailable) {
            try await service.translate(
                "这是一条没有映射的记忆。",
                from: "zh-Hans",
                to: "en-US"
            )
        }
    }

    @Test("US-DIS-002: unsupported target language throws")
    func unsupportedTargetThrows() async {
        await #expect(throws: TranslationError.unsupportedLanguage("fr-FR")) {
            try await service.translate(
                "你好",
                from: "zh-Hans",
                to: "fr-FR"
            )
        }
    }
}

// MARK: - TranslationCache Tests

@Suite("TranslationCache", .serialized)
@MainActor
struct TranslationCacheTests {

    /// 确定性时钟 — OSAllocatedUnfairLock 保护可变时间，避免 @unchecked Sendable (R-007 精神)。
    private struct MutableClock: Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))

        init(_ start: Date) {
            lock.withLock { $0 = start }
        }

        var now: Date {
            lock.withLock { $0 }
        }

        func advance(by interval: TimeInterval) {
            lock.withLock { $0 = $0.addingTimeInterval(interval) }
        }
    }

    private let key = "zh-Hans|en-US|昨晚在公园遇到一只橘猫。"

    @Test("US-DIS-002 AC-5: store then lookup returns entry within TTL")
    func lookupWithinTTL() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = MutableClock(start)
        let cache = TranslationCache { clock.now }

        await cache.store(
            sourceText: "昨晚在公园遇到一只橘猫。",
            sourceLanguage: "zh-Hans",
            targetLanguage: "en-US",
            translatedText: "An orange tabby in the park.",
            sourceLanguageConfidence: 0.95
        )

        clock.advance(by: 3 * 24 * 3600) // 3 天
        let entry = await cache.lookup(key: key)
        #expect(entry != nil)
        #expect(entry?.translatedText == "An orange tabby in the park.")
        #expect(entry?.sourceLanguageConfidence == 0.95)
    }

    @Test("US-DIS-002 AC-5: lookup after TTL (7d) returns nil and prunes entry")
    func lookupAfterTTLReturnsNil() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = MutableClock(start)
        let cache = TranslationCache { clock.now }

        await cache.store(
            sourceText: "昨晚在公园遇到一只橘猫。",
            sourceLanguage: "zh-Hans",
            targetLanguage: "en-US",
            translatedText: "An orange tabby in the park.",
            sourceLanguageConfidence: 0.95
        )

        clock.advance(by: 7 * 24 * 3600 + 1) // 7 天 + 1s
        let entry = await cache.lookup(key: key)
        #expect(entry == nil)
        #expect(await cache.isEmpty, "Expired entry must be pruned on lookup")
    }

    @Test("US-DIS-002 AC-5: lookup exactly at TTL boundary returns nil")
    func lookupAtTTLBoundaryReturnsNil() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = MutableClock(start)
        let cache = TranslationCache { clock.now }

        await cache.store(
            sourceText: "昨晚在公园遇到一只橘猫。",
            sourceLanguage: "zh-Hans",
            targetLanguage: "en-US",
            translatedText: "An orange tabby in the park.",
            sourceLanguageConfidence: 0.95
        )

        clock.advance(by: 7 * 24 * 3600) // 恰好 7 天
        let entry = await cache.lookup(key: key)
        #expect(entry == nil)
    }

    @Test("US-DIS-002 AC-5: cache miss on unknown key returns nil")
    func lookupMissReturnsNil() async {
        let cache = TranslationCache()
        let entry = await cache.lookup(key: "en-US|zh-Hans|unknown")
        #expect(entry == nil)
    }

    @Test("US-DIS-002 AC-2: makeKey is deterministic")
    func makeKeyDeterministic() {
        let a = TranslationCache.makeKey(
            sourceText: "你好",
            sourceLanguage: "zh-Hans",
            targetLanguage: "en-US"
        )
        let b = TranslationCache.makeKey(
            sourceText: "你好",
            sourceLanguage: "zh-Hans",
            targetLanguage: "en-US"
        )
        #expect(a == b)
        #expect(a == "zh-Hans|en-US|你好")
    }
}
