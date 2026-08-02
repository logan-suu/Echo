// ==========================================
// 文件: TranslationService.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-DIS-002 (记忆详情按需翻译),
//            docs/03-implementation/双语言实现说明文档.md §6 (显示层双语实现机制)
// 任务: 3.8 - 跨语言翻译层集成
// AC 覆盖: US-DIS-002 AC-2 (cache-first + Apple Translation fallback), AC-3 (源语言检测不确定保留原文, ADR-005), AC-5 (缓存 TTL=7d)
// 架构约束: 展示层服务 (非 Core, 见 docs/ui/architecture.md §5 允许内容);
//           禁止云端翻译 API (R-001/R-005); 端侧翻译为首选 (双语言文档 §6.4);
//           🔮 Phase 3.9: 接入 Apple Translation Framework + 术语表 JSON
// 生成时间: 2026-08-02
// ==========================================

import Foundation

/// 展示层翻译结果 (US-DIS-002)。
struct TranslationResult: Sendable, Equatable {
    /// 译文文本
    let translatedText: String
    /// 源语言检测置信度 (0~1，NLTagger) — < 0.9 时源语言检测不确定 (.uncertain)，
    /// 保留原文 + 语言标签 (US-DIS-002 AC-3, ADR-005)
    let sourceLanguageConfidence: Double
}

/// 展示层翻译错误 — 映射为 L2 可恢复 (Toast + 重试)。
enum TranslationError: Error, Equatable, Sendable {
    /// 翻译服务不可用
    case serviceUnavailable
    /// 目标语言不受支持 (仅 zh-Hans / en-US)
    case unsupportedLanguage(String)
}

/// 展示层翻译服务 — 按需翻译 (US-DIS-002 AC-2)。
///
/// 仅展示层使用 (双语言文档 §6.3): 翻译禁止在管线中间阶段触发。
/// 实现约束: 禁止云端翻译 API (R-001/R-005); 端侧翻译为首选。
protocol TranslationService: Sendable {
    /// 翻译一段文本。
    /// - Parameters:
    ///   - text: 源语言原文
    ///   - sourceLanguage: 源语言 (zh-Hans / en-US)
    ///   - targetLanguage: 目标语言 (zh-Hans / en-US)
    func translate(_ text: String, from sourceLanguage: String, to targetLanguage: String) async throws -> TranslationResult
}
