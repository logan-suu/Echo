// ==========================================
// 文件: AppleTranslationService.swift
// 对应规格: docs/decisions/ADR-013-creation-export-boundary.md → 决策 1 (Apple Translation 仅展示层),
//            docs/01-spec/用户故事与验收标准规格书.md → US-DIS-002 (按需翻译),
//            ADR-005 (翻译质量兜底修订: 源语言检测不确定 <0.9 保留原文)
// 任务: 3F.9 - Apple Translation 与 grounded creation
// AC 覆盖: US-DIS-002 AC-1 (展开触发), AC-2 (Apple Translation fallback), AC-3 (不确定保留原文),
//          US-SYN-007 AC-3 (术语表优先, 未命中再调 Apple Translation), AC-4 (.termTableMiss 回退)
// 架构约束: 展示层服务 (非 Core); 先做 LanguageAvailability 检查 (不支持语言对 → 保留原文 + 语言标签);
//           **绝不编造翻译质量分数** (ADR-005); 源语言置信度来自 NLTagger 检测
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，struct 成员需 nonisolated
// 生成时间: 2026-08-11
// ==========================================

import Foundation
import NaturalLanguage
import Translation

// MARK: - Translation Availability

/// 语言对可用性状态 (ADR-013 决策 1 — 先做 LanguageAvailability 检查)。
enum TranslationAvailabilityStatus: Sendable, Equatable {
    /// 语言包已安装
    case installed
    /// 支持但未安装（系统可下载）
    case supported
    /// 不支持该语言对 — 保留原文 + 语言标签，不提供译文
    case unsupported
}

/// 语言对可用性检查器 — 可注入 seam（真实实现包装 `LanguageAvailability`）。
protocol TranslationAvailabilityProviding: Sendable {
    /// 检查语言对可用性。
    func status(from source: String, to target: String) async -> TranslationAvailabilityStatus
}

/// 真实实现 — 包装 Apple `LanguageAvailability`。
struct SystemTranslationAvailability: TranslationAvailabilityProviding {
    func status(from source: String, to target: String) async -> TranslationAvailabilityStatus {
        let availability = LanguageAvailability()
        let sourceLang = Locale.Language(identifier: source)
        let targetLang = Locale.Language(identifier: target)
        let status = await availability.status(from: sourceLang, to: targetLang)
        switch status {
        case .installed:  return .installed
        case .supported:  return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }
}

// MARK: - Translation Executor

/// 实际翻译执行器 — 可注入 seam（真实实现包装 `TranslationSession`）。
protocol TranslationExecuting: Sendable {
    /// 执行翻译，返回目标语言文本。
    func translate(_ text: String, from source: String, to target: String) async throws -> String
}

/// 真实实现 — 包装 Apple `TranslationSession`。
///
/// `TranslationSession` 程序化创建 (installedSource) 为 iOS 26+ API；
/// iOS < 26 抛出 `.serviceUnavailable`（保持透明降级，不编造译文）。
struct SystemTranslationExecutor: TranslationExecuting {
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard #available(iOS 26.0, *) else {
            throw TranslationError.serviceUnavailable
        }
        let sourceLang = Locale.Language(identifier: source)
        let targetLang = Locale.Language(identifier: target)
        let session = TranslationSession(installedSource: sourceLang, target: targetLang)
        try await session.prepareTranslation()
        let response = try await session.translate(text)
        return response.targetText
    }
}

// MARK: - Apple Translation Service

/// Apple Translation 展示层服务 — 先 LanguageAvailability 检查，术语表优先，绝不编造质量分数。
///
/// ## 流程 (ADR-013 决策 1 + 双语言 §6.2)
/// 1. **术语表优先** (US-SYN-007 AC-3): 命中术语表直接返回，未命中继续。
/// 2. **LanguageAvailability 检查**: 不支持语言对 → 抛 `.unsupportedLanguage`
///    （View 保留原文 + 语言标签，不提供译文）。
/// 3. **源语言置信度**: NLTagger 检测（ADR-005），**绝不编造翻译质量分数**。
/// 4. **执行翻译**: 经 `TranslationExecuting`（真实 `TranslationSession` / 测试 stub）。
@MainActor
struct AppleTranslationService: TranslationService {
    /// 语言对可用性检查器
    private let availability: any TranslationAvailabilityProviding
    /// 实际翻译执行器
    private let executor: any TranslationExecuting
    /// 领域术语表 (US-SYN-007 AC-3)
    private let terminology: TerminologyTable

    init(
        availability: any TranslationAvailabilityProviding = SystemTranslationAvailability(),
        executor: any TranslationExecuting = SystemTranslationExecutor(),
        terminology: TerminologyTable = TerminologyTable.load()
    ) {
        self.availability = availability
        self.executor = executor
        self.terminology = terminology
    }

    // MARK: - TranslationService

    func translate(
        _ text: String,
        from sourceLanguage: String,
        to targetLanguage: String
    ) async throws -> TranslationResult {
        // US-SYN-007 AC-3: 术语表优先 — 命中直接返回，未命中回退 Apple Translation
        if let termTranslation = terminology.resolve(text, to: targetLanguage) {
            return TranslationResult(
                translatedText: termTranslation,
                sourceLanguageConfidence: Self.detectSourceLanguageConfidence(text)
            )
        }

        // ADR-013 决策 1: LanguageAvailability 检查 — 不支持语言对 → 保留原文 + 语言标签
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        guard status != .unsupported else {
            throw TranslationError.unsupportedLanguage(targetLanguage)
        }

        // ADR-005: 源语言置信度来自 NLTagger 检测，绝不编造翻译质量分数
        let confidence = Self.detectSourceLanguageConfidence(text)

        // 执行实际翻译
        let translated = try await executor.translate(text, from: sourceLanguage, to: targetLanguage)
        return TranslationResult(
            translatedText: translated,
            sourceLanguageConfidence: confidence
        )
    }

    // MARK: - Source Language Confidence (ADR-005)

    /// 源语言检测置信度 (0~1) — NLLanguageRecognizer 确定性检测。
    ///
    /// 空/极短文本返回 0（`<0.9` → View 保留原文 + 语言标签）。
    nonisolated static func detectSourceLanguageConfidence(_ text: String) -> Double {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        defer { recognizer.reset() }
        guard let language = recognizer.dominantLanguage else { return 0 }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        return hypotheses[language] ?? 0
    }
}
