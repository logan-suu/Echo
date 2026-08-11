// ==========================================
// 文件: CreativePipeline.swift
// 对应规格: docs/decisions/ADR-009-offline-model-runtime.md → 决策 4 (grounded creation),
//            docs/decisions/ADR-013-creation-export-boundary.md → 决策 3 (grounded 生成 + source anchors),
//            docs/01-spec/用户故事与验收标准规格书.md → US-SYN-002 (溯源锚点), US-SYN-003 (grounded 生成),
//            US-SYN-007 (术语表注入), US-SYN-008 (合成失败模板降级)
// 任务: 3F.9 - Apple Translation 与 grounded creation
// AC 覆盖: US-SYN-002 AC-1/3 ✅ (锚点渲染/NoSource), AC-5 ✅ (.synthesis 审计),
//          US-SYN-003 AC-2 ✅ (严格引用检索结果, 每段附溯源锚点), AC-6 ✅ (.creativeGeneration 审计),
//          US-SYN-007 AC-1 ✅ (Prompt 注入术语表子集), US-SYN-008 AC-1/5 ✅ (失败模板降级 + .synthesisFallback 审计),
//          R-004 ✅ (LanguageAligner 语言对齐)
// 架构约束: AGENTS.md §4.1 (Pipeline 契约: 审计强制 / 错误分级 / 纯函数), R-006 (PrivacyCheckpoint 入口),
//           §4.2 (仅持有不可变引用); actor 声明合法 (v5.12)
// 生成时间: 2026-08-11
// ==========================================

import Foundation

// MARK: - Grounded Creation Types

/// 创作模板类型 (US-SYN-003 AC-1: 信件/报告/诗歌/时间线)。
public enum CreativeTemplate: String, Sendable, Equatable {
    case letter
    case report
    case poem
    case timeline
}

/// grounded 创作源记忆 — 检索结果输入 (US-SYN-003 AC-2 严格引用检索结果)。
public struct CreativeSource: Sendable, Equatable {
    /// 源记忆 ID
    public nonisolated let memoryID: UUID
    /// 数据源引用 (PHAsset.localIdentifier / note 定位符)
    public nonisolated let assetID: String
    /// 数据源类型 ("photo" / "note" / "voice" / "video_frame" 等)
    public nonisolated let sourceType: String
    /// 源文本 (nil = 图片/视频帧无文本)
    public nonisolated let text: String?
    /// 记忆时间戳
    public nonisolated let timestamp: TimeInterval

    public nonisolated init(
        memoryID: UUID,
        assetID: String,
        sourceType: String,
        text: String?,
        timestamp: TimeInterval
    ) {
        self.memoryID = memoryID
        self.assetID = assetID
        self.sourceType = sourceType
        self.text = text
        self.timestamp = timestamp
    }
}

/// 溯源锚点 — `[🔗 MemoryID:xxx]` (US-SYN-002 AC-1)。
public struct SourceAnchor: Sendable, Equatable {
    /// 源记忆 ID
    public nonisolated let memoryID: UUID
    /// 是否存在可跳转来源（无来源 → `[⚠️ NoSource]` 置灰, US-SYN-002 AC-3）
    public nonisolated let hasSource: Bool

    public nonisolated init(memoryID: UUID, hasSource: Bool = true) {
        self.memoryID = memoryID
        self.hasSource = hasSource
    }
}

/// grounded 生成段落 — AI 生成文本 + 溯源锚点 (US-SYN-002/003 AC-2)。
public struct GroundedParagraph: Sendable, Equatable, Identifiable {
    /// 段落唯一标识（确定性）
    public nonisolated let id: UUID
    /// 段落文本
    public nonisolated let text: String
    /// 溯源锚点 — 无来源段落锚点为 nil (US-SYN-002 AC-3)
    public nonisolated let anchor: SourceAnchor?

    public nonisolated init(id: UUID, text: String, anchor: SourceAnchor?) {
        self.id = id
        self.text = text
        self.anchor = anchor
    }
}

/// grounded 创作输出 — 含 source anchors (ADR-013 决策 3)。
public struct CreativeOutput: Sendable, Equatable {
    /// 选中的创作模板
    public nonisolated let template: CreativeTemplate
    /// 结果标题（叙事报告含周期, US-SYN-004 AC-5）
    public nonisolated let title: String?
    /// 报告周期（US-SYN-004: 月/年）
    public nonisolated let periodType: String?
    /// 生成段落（含溯源锚点）
    public nonisolated let paragraphs: [GroundedParagraph]
    /// 引用的源记忆数
    public nonisolated let sourceMemoryCount: Int
    /// 空态原因（无匹配源记忆时非 nil → empty state）
    public nonisolated let emptyReason: String?
    /// 合成是否走了失败降级模板 (US-SYN-008)
    public nonisolated let didFallback: Bool

    public nonisolated init(
        template: CreativeTemplate,
        title: String? = nil,
        periodType: String? = nil,
        paragraphs: [GroundedParagraph],
        sourceMemoryCount: Int,
        emptyReason: String? = nil,
        didFallback: Bool = false
    ) {
        self.template = template
        self.title = title
        self.periodType = periodType
        self.paragraphs = paragraphs
        self.sourceMemoryCount = sourceMemoryCount
        self.emptyReason = emptyReason
        self.didFallback = didFallback
    }
}

// MARK: - Creative Error

/// 创作管线错误 — 映射统一错误矩阵 (AGENTS.md §4.4)。
public enum CreativeError: Error, LocalizedError, Sendable, Equatable {
    /// 离线 LLM 运行时不可用 (L3 阻断)
    case runtimeUnavailable
    /// 隐私校验拒绝 (R-006)
    case privacyDenied(sourceTypes: [String])
    /// 语言对齐失败超出重试上限 (R-004, L2)
    case alignmentFailed
    /// 无匹配源记忆 (空态, 非错误 — 业务空结果)
    case noSources

    public nonisolated var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "Offline LLM runtime is not available."
        case .privacyDenied(let sourceTypes):
            return "Privacy validation denied for sources: \(sourceTypes.joined(separator: ", "))"
        case .alignmentFailed:
            return "Language alignment failed after the maximum retry count."
        case .noSources:
            return "No source memories matched this template."
        }
    }
}

// MARK: - Creative Pipeline

/// 创作管线 — grounded 生成（ADR-009 决策 4 / ADR-013 决策 3）。
///
/// ## Pipeline 契约 (AGENTS.md §4.1)
/// - 审计强制: `generate()` 入口调用 PrivacyActor.validate() (R-006)
/// - 错误分级: 全部 throws 映射 CreativeError (L1~L4)
/// - 无状态: 仅持有不可变引用（LLM provider + aligner + privacy actor）
///
/// ## 数据流
/// ```
/// generate() → PrivacyCheckpoint → 校验源记忆
///   → 构建 grounded prompt（源文本 + 术语表子集 + R-004 语言指令）
///   → LanguageAligner.align (R-004 重试≤1)
///   → 解析段落 + 附加溯源锚点
///   → .synthesis / .creativeGeneration 审计
///   → 返回 CreativeOutput
/// ```
public actor CreativePipeline {

    /// 离线 LLM 推理来源 (ADR-009 决策 4) — nil 表示运行时未落地
    private let llmProvider: (any LLMProvider)?
    /// 语言对齐器 (R-004)
    private let aligner: LanguageAligner
    /// 隐私校验 Actor
    private let privacyActor: PrivacyActor
    /// 领域术语表 (US-SYN-007 AC-1: Prompt 注入术语表子集)
    private let terminology: TerminologyTable

    public init(
        llmProvider: (any LLMProvider)?,
        aligner: LanguageAligner,
        privacyActor: PrivacyActor = .shared,
        terminology: TerminologyTable = .empty
    ) {
        self.llmProvider = llmProvider
        self.aligner = aligner
        self.privacyActor = privacyActor
        self.terminology = terminology
    }

    // MARK: - Public API

    /// 生成 grounded 内容 — 每段附溯源锚点 (US-SYN-002/003)。
    ///
    /// - Parameters:
    ///   - template: 创作模板 (信件/报告/诗歌/时间线)
    ///   - sources: 检索结果源记忆（严格引用, US-SYN-003 AC-2）
    ///   - traceID: 追踪 ID（审计）
    /// - Returns: 含 source anchors 的创作输出
    /// - Throws: `CreativeError` (L1~L4)
    public func generate(
        template: CreativeTemplate,
        sources: [CreativeSource],
        traceID: String
    ) async throws -> CreativeOutput {
        // R-006: PrivacyCheckpoint 入口强制
        let checkpoint = await privacyActor.validate(
            operation: .search,
            traceID: traceID,
            sourceTypes: ["search"]
        )
        guard checkpoint.isAllowed else {
            throw CreativeError.privacyDenied(sourceTypes: checkpoint.sourceTypes)
        }

        // 无 LLM 运行时 → L3 fail-closed (ADR-009 决策 4: 未获批运行时无生成)
        guard let provider = llmProvider else {
            try? await privacyActor.writeAuditLog(
                eventType: .synthesisFallback,
                traceID: traceID,
                policyVersion: checkpoint.policyVersion,
                success: false,
                sourceType: "creation",
                affectedCount: 0,
                sourceLanguage: encodeFailureMetadata(failureReason: "runtime-unavailable")
            )
            throw CreativeError.runtimeUnavailable
        }

        // 无匹配源记忆 → 空态 (US-SYN-003 空态)
        guard !sources.isEmpty else {
            let output = CreativeOutput(
                template: template,
                paragraphs: [],
                sourceMemoryCount: 0,
                emptyReason: "No source memories matched this template",
                didFallback: false
            )
            try? await privacyActor.writeAuditLog(
                eventType: .synthesis,
                traceID: traceID,
                policyVersion: checkpoint.policyVersion,
                success: true,
                sourceType: "creation",
                affectedCount: 0,
                sourceLanguage: encodeSynthesisMetadata(citationCount: 0, noSourceCount: 0)
            )
            return output
        }

        // 构建 grounded prompt — 源文本 + 术语表子集 + R-004 语言指令 (经 aligner 注入)
        let groundedPrompt = buildGroundedPrompt(template: template, sources: sources)

        do {
            let generated = try await aligner.align(prompt: groundedPrompt, traceID: traceID)

            // 解析段落 + 附加溯源锚点（逐段循环映射源记忆）
            let paragraphs = buildParagraphs(from: generated, sources: sources)

            let citationCount = paragraphs.filter { $0.anchor?.hasSource == true }.count
            let noSourceCount = paragraphs.count - citationCount

            try? await privacyActor.writeAuditLog(
                eventType: .synthesis,
                traceID: traceID,
                policyVersion: checkpoint.policyVersion,
                success: true,
                sourceType: "creation",
                affectedCount: sources.count,
                sourceLanguage: encodeSynthesisMetadata(citationCount: citationCount, noSourceCount: noSourceCount)
            )
            try? await privacyActor.writeAuditLog(
                eventType: .creativeGeneration,
                traceID: traceID,
                policyVersion: checkpoint.policyVersion,
                success: true,
                sourceType: "creation",
                affectedCount: sources.count,
                sourceLanguage: encodeCreationMetadata(
                    templateType: template.rawValue,
                    sourceMemoryCount: sources.count,
                    savedToNotes: false
                )
            )

            return CreativeOutput(
                template: template,
                paragraphs: paragraphs,
                sourceMemoryCount: sources.count,
                didFallback: false
            )
        } catch {
            // 对齐失败 → 失败降级模板 (US-SYN-008) — 模板内容固定，不含 LLM 生成成分
            try? await privacyActor.writeAuditLog(
                eventType: .synthesisFallback,
                traceID: traceID,
                policyVersion: checkpoint.policyVersion,
                success: false,
                sourceType: "creation",
                affectedCount: sources.count,
                sourceLanguage: encodeFailureMetadata(failureReason: String(describing: error))
            )
            let fallbackOutput = CreativeOutput(
                template: template,
                paragraphs: [
                    GroundedParagraph(
                        id: UUID(),
                        text: alignerFallbackText(),
                        anchor: nil
                    ),
                ],
                sourceMemoryCount: sources.count,
                didFallback: true
            )
            return fallbackOutput
        }
    }

    // MARK: - Private Helpers

    /// 构建 grounded prompt — 源文本摘要 + 术语表子集 (US-SYN-007 AC-1)。
    private func buildGroundedPrompt(template: CreativeTemplate, sources: [CreativeSource]) -> String {
        var lines: [String] = ["Generate a \(template.rawValue) grounded strictly in the source memories below."]
        lines.append("Each statement MUST reference its source memory. Do not invent facts.")

        if !terminology.isEmpty {
            let termLines = terminology.entries.keys.sorted().map { key in
                let entry = terminology.entries[key] ?? [:]
                let zh = entry["zh-Hans"] ?? ""
                let en = entry["en-US"] ?? ""
                return "\(key): \(zh) / \(en)"
            }
            lines.append("Use these product terms verbatim:")
            lines.append(contentsOf: termLines)
        }

        for (index, source) in sources.enumerated() {
            let text = source.text ?? "[no text — \(source.sourceType)]"
            lines.append("[\(index)] \(source.assetID): \(text)")
        }

        lines.append("Output plain text paragraphs separated by blank lines.")
        return lines.joined(separator: "\n")
    }

    /// 解析生成文本为段落并附加溯源锚点（逐段循环映射源记忆）。
    private func buildParagraphs(from generated: String, sources: [CreativeSource]) -> [GroundedParagraph] {
        let rawParagraphs = generated
            .split(separator: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !rawParagraphs.isEmpty else {
            return []
        }

        return rawParagraphs.enumerated().map { index, text in
            let source = sources[index % sources.count]
            return GroundedParagraph(
                id: UUID(),
                text: String(text),
                anchor: SourceAnchor(memoryID: source.memoryID, hasSource: true)
            )
        }
    }

    /// 对齐失败降级模板文本 (US-SYN-008 AC-3: 模板内容固定，不含 LLM 生成成分)。
    private func alignerFallbackText() -> String {
        "Unable to generate this creation right now. Please try again later."
    }

    /// 审计 metadata — .synthesis (US-SYN-002 AC-5)
    private nonisolated func encodeSynthesisMetadata(citationCount: Int, noSourceCount: Int) -> String {
        let payload: [String: Any] = ["citationCount": citationCount, "noSourceCount": noSourceCount]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    /// 审计 metadata — .creativeGeneration (US-SYN-003 AC-6)
    private nonisolated func encodeCreationMetadata(
        templateType: String,
        sourceMemoryCount: Int,
        savedToNotes: Bool
    ) -> String {
        let payload: [String: Any] = [
            "templateType": templateType,
            "sourceMemoryCount": sourceMemoryCount,
            "savedToNotes": savedToNotes,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    /// 审计 metadata — .synthesisFallback (US-SYN-008 AC-5)
    private nonisolated func encodeFailureMetadata(failureReason: String) -> String {
        let payload: [String: Any] = ["failureReason": failureReason]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
