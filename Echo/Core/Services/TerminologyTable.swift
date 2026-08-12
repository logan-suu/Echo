// ==========================================
// 文件: TerminologyTable.swift
// 对应规格: docs/03-implementation/双语言实现说明文档.md §6.2 (领域术语表机制),
//            docs/01-spec/用户故事与验收标准规格书.md → US-SYN-007 AC-1 (Prompt 注入术语表子集),
//            AC-3 (展示层翻译优先查术语表)
// 任务: 3F.9 - Apple Translation 与 grounded creation
// AC 覆盖: US-SYN-007 AC-1 ✅ (CreativePipeline Prompt 注入术语表子集),
//          AC-3 ✅ (AppleTranslationService 术语表优先, 未命中再调 Apple Translation)
// 架构约束: Core 服务 (被 Core CreativePipeline prompt 注入 + UI 展示层翻译共同消费);
//           JSON 格式 { "term_key": { "zh-Hans": "...", "en-US": "..." } }
// 生成时间: 2026-08-11
// ==========================================

import Foundation

/// 领域术语表 (US-SYN-007)。
///
/// ## 契约 (双语言文档 §6.2)
/// - 格式: JSON `{ "term_key": { "zh-Hans": "...", "en-US": "..." } }`
/// - 覆盖范围: 产品功能名称、认知管线阶段名、隐私策略术语、错误码描述
/// - 展示层翻译优先查术语表: 命中则直接使用，未命中再调用 Apple Translation (AC-3)
/// - AI 生成内容术语注入: CreativePipeline 在 Prompt 中附带术语表子集约束 LLM 用词 (AC-1)
public struct TerminologyTable: Sendable, Equatable {
    /// 术语条目 — key → 语言 → 译文
    public nonisolated let entries: [String: [String: String]]

    public nonisolated init(entries: [String: [String: String]]) {
        self.entries = entries
    }

    /// 空术语表 — 非隔离静态（供 actor 默认参数，R-007 精神）。
    public nonisolated static var empty: TerminologyTable {
        TerminologyTable(entries: [:])
    }

    /// 从 JSON 数据解码术语表。
    ///
    /// 结构: `{ "term_key": { "zh-Hans": "...", "en-US": "..." } }`
    /// 解析失败抛 `TerminologyError.invalidJSON`（调用方降级为 Apple Translation）。
    public nonisolated init(jsonData: Data) throws {
        guard let raw = try JSONSerialization.jsonObject(with: jsonData) as? [String: [String: String]] else {
            throw TerminologyError.invalidJSON
        }
        self.entries = raw
    }

    /// 从 Bundle 资源加载术语表（存在时），资源缺失返回空表（不抛错，保持确定性降级）。
    public static func load(
        named name: String = "terminology",
        in bundle: Bundle = Bundle.main
    ) -> TerminologyTable {
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? TerminologyTable(jsonData: data) else {
            return TerminologyTable(entries: [:])
        }
        return table
    }

    /// 解析术语 — 精确匹配 term_key + 目标语言 (US-SYN-007 AC-3)。
    ///
    /// - Parameters:
    ///   - term: 术语 key 或源文本
    ///   - targetLanguage: 目标语言 (zh-Hans / en-US)
    /// - Returns: 术语译文；未命中或语言不支持时返回 nil
    public func resolve(_ term: String, to targetLanguage: String) -> String? {
        guard let byLanguage = entries[term],
              let translation = byLanguage[targetLanguage],
              !translation.isEmpty else {
            return nil
        }
        return translation
    }

    /// 术语表是否为空。
    public nonisolated var isEmpty: Bool { entries.isEmpty }
}

// MARK: - Error

/// 术语表错误。
enum TerminologyError: Error, LocalizedError, Sendable {
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Terminology table JSON is invalid."
        }
    }
}
