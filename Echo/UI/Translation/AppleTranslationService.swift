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
// 修订: 2026-08-12 (PR #61 review B-1) — iOS 18.x 中 TranslationSession 无公开构造器
//       (init(installedSource:target:) 为 iOS 26+ API)，唯一官方途径是 SwiftUI
//       .translationTask；重构 SystemTranslationExecutor 为隐藏 host view 桥接模式
//       (RetroArch / Verto / Easydict 同款, WWDC24 Session 10117)
// ==========================================

// @preconcurrency: TranslationSession 未标注 Sendable，但仅在 MainActor 使用
// (Swift 6 strict-concurrency 下经 @preconcurrency 以 Swift 5 语义导入，社区标准做法)
import Foundation
import NaturalLanguage
import SwiftUI
@preconcurrency import Translation

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

/// 真实实现 — 经隐藏 host view 的 `.translationTask` 桥接获取 `TranslationSession` 执行翻译。
///
/// iOS 17.4~25.x 中 `TranslationSession` 无公开构造器（`init(installedSource:target:)` 为
/// iOS 26+ API，`init(configuration:)` 不存在），唯一官方途径是 SwiftUI `.translationTask`
/// （WWDC24 Session 10117）。本实现沿用成熟项目（RetroArch / Verto / Easydict）的
/// "App 根部常驻 1pt 隐藏 host view + `TranslationSessionBridge`" 模式；语言包未安装 → 抛
/// `.serviceUnavailable`（透明降级，不编造译文）。
struct SystemTranslationExecutor: TranslationExecuting {
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let sourceLang = Locale.Language(identifier: source)
        let targetLang = Locale.Language(identifier: target)
        return try await TranslationSessionBridge.shared.translate(
            text,
            source: sourceLang,
            target: targetLang
        )
    }
}

// MARK: - Translation Session Bridge (iOS 18.x 无公开构造器的桥接方案)

/// `TranslationSession` 桥 — 通过 App 根部隐藏 host view 的 `.translationTask` 获取 session。
///
/// iOS 18.x 中 `TranslationSession` 无法直接构造；唯一官方途径是 SwiftUI `.translationTask`，
/// 它在视图出现/配置变化时提供 session 实例。本桥由 `TranslationSessionHostView` 常驻挂载，
/// 将系统提供的 session 转译为 `TranslationExecuting` 所需的 async 翻译调用。
///
/// ## 设计要点（来自成熟开源实现）
/// - session 锚定在宿主视图生命周期内，禁止存储到持久化 model（Apple 文档/WWDC24）
/// - 语言包必须已安装才可翻译；未安装时隐藏视图无法弹出下载 UI（keyboop 教训）→ 抛 unavailable
/// - host view 不可 `.hidden()`（会阻止 translationTask 触发），用 1×1 + 高透明 + 禁交互
@MainActor
@Observable
final class TranslationSessionBridge {
    /// 单例 — 与 App 根部常驻的 host view 配对。
    static let shared = TranslationSessionBridge()

    /// 触发 `.translationTask` 的配置 — 语言对变化时更新以重跑任务。
    private(set) var configuration: TranslationSession.Configuration?

    /// 当前可用的 `TranslationSession`（由 host view 的 translationTask 提供）。
    private var session: TranslationSession?

    /// 待翻译请求 — 单条目队列（翻译是低频、串行的展示层操作）。
    private struct PendingRequest: Sendable {
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }
    private var pending: PendingRequest?

    private init() {}

    /// 请求翻译 — 语言包已安装时设置配置触发 translationTask，等待桥接结果。
    func translate(
        _ text: String,
        source: Locale.Language,
        target: Locale.Language
    ) async throws -> String {
        // 语言包预检：未安装则隐藏视图无法弹下载 UI，直接降级（不编造译文）
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        guard status == .installed else {
            throw TranslationError.serviceUnavailable
        }

        // 语言对变化 → 更新配置，translationTask 会重跑并提供新 session
        let desired = TranslationSession.Configuration(source: source, target: target)
        if configuration?.source != desired.source || configuration?.target != desired.target {
            configuration = desired
        }

        // 已有 session 直接翻译；否则等待 host view 提供新 session
        if let session {
            return try await translateNow(session, text: text)
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending = PendingRequest(text: text, continuation: continuation)
        }
    }

    /// host view 的 `.translationTask` 回调 — 提供系统生成的 session 并消费待处理请求。
    func adopt(_ newSession: TranslationSession) {
        session = newSession
        guard let pending else { return }
        self.pending = nil
        Task {
            do {
                let result = try await translateNow(newSession, text: pending.text)
                pending.continuation.resume(returning: result)
            } catch {
                pending.continuation.resume(throwing: error)
            }
        }
    }

    /// 在给定 session 上执行一次翻译。
    private func translateNow(_ session: TranslationSession, text: String) async throws -> String {
        let response = try await session.translate(text)
        return response.targetText
    }
}

/// 隐藏 host view — 常驻 App 根视图，唯一合法获取 `TranslationSession` 的途径。
///
/// ⚠️ 不可 `.hidden()`（阻止 translationTask 触发）；用 1×1 + 0.01 透明度 + 禁交互 + 隐藏无障碍。
struct TranslationSessionHostView: View {
    /// 桥接单例（@Bindable 使 configuration 变化驱动 translationTask 重跑）
    @Bindable private var bridge: TranslationSessionBridge

    init(bridge: TranslationSessionBridge = .shared) {
        self.bridge = bridge
    }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .translationTask(bridge.configuration) { session in
                bridge.adopt(session)
            }
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
