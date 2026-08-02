// ==========================================
// 文件: FixtureTranslationService.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-DIS-002 (按需翻译),
//            docs/03-implementation/双语言实现说明文档.md §6.4 (端侧翻译, 禁止云端 API)
// 任务: 3.8 - 跨语言翻译层集成
// AC 覆盖: US-DIS-002 AC-2 (翻译服务), AC-3 (源语言检测不确定时保留原文), AC-5 (缓存写入)
// 架构约束: 展示层服务; 确定性、离线、可复现 (fixture 模式);
//           🔮 Phase 3.9: AppleTranslationService 接入真实 Apple Translation Framework
// 生成时间: 2026-08-02
// ==========================================

import Foundation

/// 确定性翻译服务 — Preview / 单元测试 / Live Sim Review 注入。
///
/// ## 职责 (docs/ui/architecture.md §3: Fixture Loader 同模式)
/// - 为 UI 切片提供确定性翻译结果
/// - 不访问网络、不依赖真实 Apple Translation 模型
///
/// ## 确定性规则
/// - 已知文本 → 固定译文 + 固定置信度
/// - 未知文本 → 抛 L2 错误 (translation.serviceUnavailable)
struct FixtureTranslationService: TranslationService {
    /// 确定性 zh-Hans → en-US 翻译表。
    /// 键为源文本，值为 (译文, 源语言检测置信度)。
    private static let zhEnMap: [String: (String, Double)] = [
        "昨晚在公园遇到一只橘猫，很亲人。它在我脚边蹭了很久，后来跟着我走了一段路。":
            ("Last night I met an orange tabby in the park. It was very friendly, rubbing against my legs and following me for a while.", 0.95),
        "今天整个下午都在搞这个破项目，快崩了。":
            ("I spent the whole afternoon on this broken project and it is falling apart.", 0.55),
    ]

    /// 确定性翻译 — 已知文本返回固定结果，未知文本抛 L2 错误。
    func translate(
        _ text: String,
        from sourceLanguage: String,
        to targetLanguage: String
    ) async throws -> TranslationResult {
        guard targetLanguage == "en-US" else {
            throw TranslationError.unsupportedLanguage(targetLanguage)
        }
        guard let (translatedText, sourceLanguageConfidence) = Self.zhEnMap[text] else {
            throw TranslationError.serviceUnavailable
        }
        return TranslationResult(translatedText: translatedText, sourceLanguageConfidence: sourceLanguageConfidence)
    }
}
