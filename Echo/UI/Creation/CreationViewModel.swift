// ==========================================
// 文件: CreationViewModel.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.9.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SYN-003 (情感内容生成+保存到备忘录),
//            US-SYN-004 (月度/年度叙事报告), US-SYN-005 (私有 Prompt 草稿编辑确认)
//            docs/ui/echo-memory-canvas-style.md §3.2 (Focus surfaces — 单列 + grouped metadata),
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.9 - 整合所有 ViewModel 与 Pipeline + 创作保存 UI
// AC 覆盖: US-SYN-003 AC-1 ✅ (模板选择), AC-2 ✅ (引用检索结果, 溯源锚点), AC-3 ✅ (预览/复制/导出),
//          AC-4 ✅ (保存到备忘录按钮), AC-5 ✅ (保存成功 Toast+链接 / 失败 L2 Toast+重试),
//          US-SYN-004 AC-4 ✅ (分享/导出/打印), AC-5 ✅ (保存逻辑与 SYN-003 一致, 标题含报告周期),
//          US-SYN-005 AC-4 ✅ (Prompt 草稿可编辑确认), AC-6 ✅ (重置为默认 Prompt)
//          PR #44 review: W-3 ✅ (saveTask 与 generateTask 分离, 取消保存恢复 .generated)
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum: idle/loading/completed/error/cancelled),
//           §8.2 (状态流转), docs/ui/architecture.md §6~7 (适配器契约),
//           §2.5 (Adapter 不保存第二份领域真相 — 仅转换展示字段)
// 生成时间: 2026-08-02
// ==========================================

import Foundation
import SwiftUI

// MARK: - CreationViewModel

/// AI 创作结果页 ViewModel — 模板选择 + 生成预览 + 复制/导出 + 保存到备忘录 + Prompt 草稿编辑。
///
/// ## Surface Family: Focus
/// - 布局: 单列内容流 + grouped metadata（echo-memory-canvas §3.2）
/// - 样式: echo-memory-canvas + apple-native 基础
/// - Masonry: 禁止（Focus surface）
///
/// ## 职责 (docs/ui/architecture.md §7.1)
/// - 状态映射: fixture/Core 创作输出 → UI State
/// - 错误映射: L1~L4 → error state
/// - Intent 转发: 生成/复制/导出/保存/分享/Prompt 编辑 → Core await 调用（🔮 Phase 3.9）
/// - 生命周期: Task 管理，View 消失时 cancel
///
/// ## 状态流转 (AGENTS.md §8.2)
/// ```
/// idle → generating → generated
///                     → empty
///                     → error(L2)
/// generated → saving → saved
///                    → error(L2, save)
/// ```
@MainActor
@Observable
final class CreationViewModel {
    // MARK: - State Enum

    /// ViewModel 统一状态枚举 (AGENTS.md §8.1)
    enum ViewState: Equatable, Sendable {
        /// 初始状态 — 未选择模板
        case idle
        /// 生成中 — ProgressView
        case generating
        /// 生成完成 — 展示内容 + 操作按钮
        case generated
        /// 空态 — 无匹配源记忆
        case empty
        /// 错误状态 — L2 重试
        case error(ErrorLevel)
        /// 保存到备忘录中
        case saving
        /// 已保存 — Toast + 链接
        case saved
    }

    /// 错误等级 — 对应 AGENTS.md §4.4 L1~L4
    enum ErrorLevel: Equatable, Sendable {
        /// L2 可恢复: Toast + 重试按钮
        case l2Recoverable(message: String)
    }

    /// 导出格式 (US-SYN-003 AC-3)
    enum ExportFormat: String, CaseIterable, Sendable {
        case pdf
        case markdown

        var displayName: String {
            switch self {
            case .pdf:       return "PDF"
            case .markdown:  return "Markdown"
            }
        }
    }

    // MARK: - Published State

    /// 统一视图状态
    private(set) var viewState: ViewState = .idle
    /// 当前创作结果
    private(set) var creation: CreationModel?
    /// 已选模板
    private(set) var selectedTemplate: CreationTemplate?

    // MARK: - Prompt Editor State (US-SYN-005 AC-4)

    /// Prompt 编辑器 Sheet 是否呈现
    var isPromptEditorPresented: Bool = false
    /// Prompt 草稿编辑文本
    var promptDraftText: String = CreationPromptDefaults.defaultDraft
    /// 当前生效的 Prompt 草稿（确认后更新）
    private(set) var confirmedPrompt: String = CreationPromptDefaults.defaultDraft
    /// True only after an explicit Preview/test/XCUITest fixture injection.
    private(set) var isFixtureBacked = false

    // MARK: - Export / Share State (US-SYN-003 AC-3, US-SYN-004 AC-4)

    /// 导出格式确认弹窗是否呈现
    var isExportPickerPresented: Bool = false
    /// 分享 Sheet 是否呈现
    var isSharePresented: Bool = false

    // MARK: - Toast State (US-SYN-003 AC-5)

    /// 保存成功 Toast 消息
    private(set) var saveToastMessage: String?
    /// 已保存笔记链接
    private(set) var noteLink: String?

    // MARK: - Dependencies

    /// 当前活跃的生成 Task
    private var generateTask: Task<Void, Never>?
    /// 当前活跃的保存 Task — 与 generateTask 分离 (PR #44 review W-3)
    private var saveTask: Task<Void, Never>?
    /// UI 切片模式模拟创作源 — fixture 注入
    private var stubCreation: CreationModel?
    /// Production creation pipeline. A missing runtime must fail closed and never load fixture output.
    private let creativePipeline: CreativePipeline?
    /// 创作源记忆（grounded 输入，经检索结果映射）— 3F.9 生产路径
    private var sourceMemories: [CreativeSource] = []

    init(
        creativePipeline: CreativePipeline? = nil
    ) {
        self.creativePipeline = creativePipeline
    }

    // MARK: - Actions

    /// 选择创作模板 (US-SYN-003 AC-1)。
    func selectTemplate(_ template: CreationTemplate) {
        guard viewState == .idle else { return }
        selectedTemplate = template
    }

    /// 生成内容 — 设置 state = .generating，完成后进入 generated/empty/error。
    ///
    /// Production uses grounded generation through CreativePipeline. Fixture output is
    /// available only after explicit Preview/test injection.
    func generate() {
        guard viewState == .idle, selectedTemplate != nil else { return }

        generateTask?.cancel()

        // Set loading synchronously (AGENTS.md §8.1: first line of action)
        viewState = .generating

        generateTask = Task { [weak self] in
            guard let self else { return }

            // 生产路径: grounded generation (ADR-013 决策 3)
            if let pipeline = self.creativePipeline, let template = self.selectedTemplate {
                self.isFixtureBacked = false
                await self.generateViaPipeline(pipeline, template: template)
                return
            }

            guard !Task.isCancelled else {
                self.viewState = .idle
                return
            }

            // Explicit Preview/test injection may regenerate deterministic output.
            if self.isFixtureBacked, let template = self.selectedTemplate {
                guard let model = self.stubCreation ?? CreationFixtureLoader.load(for: template) else {
                    self.creation = nil
                    self.viewState = .error(.l2Recoverable(
                        message: "Generation is currently unavailable. Please try again."
                    ))
                    return
                }
                self.creation = model
                self.viewState = model.emptyReason != nil ? .empty : .generated
            } else {
                self.creation = nil
                self.viewState = .error(.l2Recoverable(
                    message: "Offline generation runtime is not available. Please try again."
                ))
            }
        }
    }

    /// 经生产管线 grounded 生成 — 源记忆经检索结果映射（无源 → 空态）。
    private func generateViaPipeline(_ pipeline: CreativePipeline, template: CreationTemplate) async {
        do {
            let coreTemplate: CreativeTemplate
            switch template {
            case .letter:   coreTemplate = .letter
            case .report:   coreTemplate = .report
            case .poem:     coreTemplate = .poem
            case .timeline: coreTemplate = .timeline
            }

            let output = try await pipeline.generate(
                template: coreTemplate,
                sources: sourceMemories,
                traceID: UUID().uuidString
            )

            guard !Task.isCancelled else {
                viewState = .idle
                return
            }

            guard !output.didFallback else {
                viewState = .error(.l2Recoverable(
                    message: "Generation is currently unavailable. Please try again."
                ))
                return
            }

            guard !output.paragraphs.isEmpty else {
                creation = nil
                viewState = .empty
                return
            }

            creation = mapToCreationModel(output)
            viewState = .generated
        } catch CreativeError.noSources {
            creation = nil
            viewState = .empty
        } catch CreativeError.runtimeUnavailable {
            viewState = .error(.l2Recoverable(
                message: "Offline generation runtime is not available. Please try again."
            ))
        } catch {
            viewState = .error(.l2Recoverable(
                message: "Generation is currently unavailable. Please try again."
            ))
        }
    }

    /// 映射 grounded 输出为 UI 展示模型（适配器职责，docs/ui/architecture.md §7）。
    private func mapToCreationModel(_ output: CreativeOutput) -> CreationModel {
        let uiTemplate: CreationTemplate
        switch output.template {
        case .letter:   uiTemplate = .letter
        case .report:   uiTemplate = .report
        case .poem:     uiTemplate = .poem
        case .timeline: uiTemplate = .timeline
        }

        let paragraphs = output.paragraphs.map { paragraph in
            CreationParagraph(
                id: paragraph.id,
                text: paragraph.text,
                citation: paragraph.anchor.map {
                    CreationCitation(memoryId: $0.memoryID, hasSource: $0.hasSource)
                }
            )
        }

        return CreationModel(
            selectedTemplate: uiTemplate,
            title: output.title,
            periodType: output.periodType,
            paragraphs: paragraphs,
            sourceMemoryCount: output.sourceMemoryCount,
            emptyReason: output.emptyReason,
            noteLink: nil,
            savePhase: .none
        )
    }

    /// 重新生成 (generated → generating)。
    func regenerate() {
        guard viewState == .generated else { return }
        viewState = .idle
        generate()
    }

    /// 复制生成内容到剪贴板 (US-SYN-003 AC-3)。
    ///
    /// 复制纯文本（段落拼接，不含锚点标记）。
    func copyToClipboard() {
        guard let creation else { return }
        let text = creation.paragraphs.map(\.text).joined(separator: "\n\n")
        UIPasteboard.general.string = text
        // accessibility: 复制后触发朗读确认
        UIAccessibility.post(notification: .announcement, argument: "Creation copied to clipboard")
    }

    /// 呈现导出格式选择 (US-SYN-003 AC-3)。
    func presentExportPicker() {
        guard viewState == .generated else { return }
        isExportPickerPresented = true
    }

    /// 确认导出格式 — 呈现系统分享 Sheet (PDF/Markdown 导出入口, US-SYN-003 AC-3)。
    ///
    /// 3F.9 (ADR-013 决策 4): 经 `CreationExportService` 生成导出内容后呈现系统 share sheet。
    func export(format: ExportFormat) {
        isExportPickerPresented = false
        isSharePresented = true
    }

    /// 呈现分享/打印 Sheet (US-SYN-004 AC-4)。
    func presentShare() {
        guard viewState == .generated else { return }
        isSharePresented = true
    }

    /// 保存到备忘录 (US-SYN-003 AC-4)。
    ///
    /// ADR-013 决策 4 (3F.9): Notes 交接**仅用系统 share/export 流（用户中介）**，
    /// 禁止 `notes://` 深链与私有 NoteStore 直写。直接呈现系统分享面板，由用户选择保存到备忘录。
    func saveToNotes() {
        guard viewState == .generated else { return }
        isSharePresented = true
    }

    /// 打开已保存的笔记链接 (US-SYN-003 AC-5)。
    ///
    /// 🔮 Phase 3.9+: 跳转至该笔记。当前 UI 切片保留链接展示。
    func openNote() {
        guard let link = noteLink, let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    /// 重试 (L2 恢复路径) — error → generating; empty → generating。
    func retry() {
        guard case .error = viewState else { return }
        viewState = .idle
        generate()
    }

    // MARK: - Prompt Editor Actions (US-SYN-005)

    /// 呈现 Prompt 编辑器 (AC-4)。
    func presentPromptEditor() {
        promptDraftText = confirmedPrompt
        isPromptEditorPresented = true
    }

    /// 确认编辑后的 Prompt 草稿 (AC-4/AC-5)。
    ///
    /// 非空校验后更新生效草稿；后续合成请求注入（🔮 Phase 3.9）。
    func confirmPrompt() {
        let trimmed = promptDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        confirmedPrompt = trimmed
        isPromptEditorPresented = false
    }

    /// 重置为默认 Prompt (AC-6)。
    func resetPrompt() {
        confirmedPrompt = CreationPromptDefaults.defaultDraft
        promptDraftText = confirmedPrompt
        isPromptEditorPresented = false
    }

    /// 取消 Prompt 编辑，不保存。
    func cancelPromptEdit() {
        isPromptEditorPresented = false
    }

    // MARK: - Fixture Injection

    /// Enables deterministic generation only for an explicit Preview/test journey.
    /// Production composition never calls this method and therefore remains fail-closed.
    func enableFixtureGeneration() {
        isFixtureBacked = true
        stubCreation = nil
        creation = nil
        viewState = .idle
    }

    /// 预加载确定性创作结果（Preview / 测试 / XCUITest fixture 注入）。
    func loadPreloaded(_ model: CreationModel) {
        isFixtureBacked = true
        stubCreation = model
        creation = model
        selectedTemplate = model.selectedTemplate
        if model.emptyReason != nil {
            viewState = .empty
        } else {
            viewState = .generated
        }
        noteLink = model.noteLink
        if model.savePhase == .saved {
            // ADR-013 决策 4: 无 notes:// 深链 — saved 态保留 Toast，不提供伪造链接
            saveToastMessage = "Saved to Notes: \(model.title ?? "Echo creation")"
            viewState = .saved
        }
    }

    /// 注入 Prompt 草稿态 (Preview / 测试)。
    func loadPromptDraft(_ draft: String) {
        promptDraftText = draft
        confirmedPrompt = draft
    }

    /// 仅 Preview/调试使用 — 直接构造错误状态，不触发任何副作用。
    /// 生产路径的错误由 generate() 的 catch 自然产生，不调用此方法。
    func simulateError(_ level: ErrorLevel) {
        viewState = .error(level)
    }

    /// 注入 grounded 创作源记忆（US-SYN-003 AC-2: 严格引用检索结果）。
    ///
    /// 生产路径从检索结果映射 `CreativeSource` 后调用；UI 切片/测试可注入确定性源。
    func loadSourceMemories(_ sources: [CreativeSource]) {
        sourceMemories = sources
    }

    /// 消除错误状态，返回 idle。
    func dismissError() {
        viewState = .idle
    }

    // MARK: - Lifecycle

    deinit {}

    /// 视图消失时调用 — 取消进行中的任务。
    func onDisappear() {
        generateTask?.cancel()
        generateTask = nil
        saveTask?.cancel()
        saveTask = nil
    }
}
