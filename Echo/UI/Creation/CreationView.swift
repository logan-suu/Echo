// ==========================================
// 文件: CreationView.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.9.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SYN-003 (情感内容生成+保存到备忘录),
//            US-SYN-004 (月度/年度叙事报告), US-SYN-005 (私有 Prompt 草稿)
//            docs/ui/echo-memory-canvas-style.md §3.2 (Focus surfaces — 单列 + grouped metadata),
//            §4 (共享 Token), §7.1 (Focus 共享表达), §10.1.2 (数据加载失败空态),
//            docs/ui/architecture.md §3 (Surface View), §8 (Focus family)
// 任务: 3.9 - 整合所有 ViewModel 与 Pipeline + 创作保存 UI
// AC 覆盖: US-SYN-003 AC-1 ✅ (模板选择), AC-2 ✅ (溯源锚点), AC-3 ✅ (预览/复制/导出),
//          AC-4 ✅ (保存到备忘录按钮), AC-5 ✅ (Toast+链接 / L2 重试),
//          US-SYN-004 AC-4 ✅ (分享/导出/打印), AC-5 ✅ (标题含报告周期),
//          US-SYN-005 AC-4 ✅ (Prompt 草稿可编辑确认), AC-6 ✅ (重置为默认)
//          PR #44 review: W-1 ✅ (移除 example.com 外链回退), W-2 ✅ (Toast accessibility .contain)
// 架构约束: AGENTS.md §8.1 (ViewModel 驱动), §17.3 (Focus 禁止 masonry),
//           echo-memory-canvas apple-native 基础; 系统容器 + semantic colors + Dynamic Type
// 生成时间: 2026-08-02
// ==========================================

import SwiftUI

// MARK: - CreationView

/// AI 创作结果主视图 — 模板选择 + 生成预览 + 复制/导出/保存 + Prompt 草稿编辑。
///
/// ## Surface Family: Focus
/// - 布局: 单列内容流 + grouped metadata（echo-memory-canvas §3.2/§7.1）
/// - 系统容器: NavigationStack (由 MemoryDetailView push) + ScrollView + Form sheet (Prompt 编辑器) + confirmationDialog + Toast
/// - Masonry: **明确禁止**（Focus surface §3.2, §8.1）
///
/// ## 状态驱动
/// - idle: 模板选择 + 生成按钮 + Prompt 编辑入口
/// - generating: ProgressView
/// - generated: 生成内容 + 溯源锚点 + 复制/导出/保存/分享
/// - empty: 无匹配源记忆空态
/// - error: L2 重试横幅
/// - saving: 保存中 ProgressView
/// - saved: Toast + 笔记链接
///
/// ## Style
/// - echo-memory-canvas token: .title/.body/.caption, Color.primary, semantic colors, SF Symbols
/// - 禁止 masonry, 禁止 Pinterest 品牌元素
/// - 使用系统 Dynamic Type, semantic colors, 系统容器
struct CreationView: View {
    // MARK: - ViewModel

    @State private var viewModel: CreationViewModel

    init(viewModel: CreationViewModel = CreationViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
        }
        .navigationTitle("AI Creation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Prompt 草稿编辑入口 (US-SYN-005 AC-4)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.presentPromptEditor()
                } label: {
                    Label("Personal Prompt", systemImage: "person.text.rectangle")
                }
                .accessibilityIdentifier("creation-edit-prompt")
            }
        }
        .sheet(isPresented: $viewModel.isPromptEditorPresented) {
            PromptEditorSheet(viewModel: viewModel)
        }
        // 导出格式选择 (US-SYN-003 AC-3)
        .confirmationDialog(
            "Export creation",
            isPresented: $viewModel.isExportPickerPresented,
            titleVisibility: .visible
        ) {
            ForEach(CreationViewModel.ExportFormat.allCases, id: \.self) { format in
                Button(format.displayName) {
                    viewModel.export(format: format)
                }
                .accessibilityIdentifier("creation-export-\(format.rawValue)")
            }

            Button("Cancel", role: .cancel) {
                viewModel.isExportPickerPresented = false
            }
        } message: {
            Text("Choose a format for this creation.")
        }
        // 分享/导出/打印 Sheet (US-SYN-003 AC-3, US-SYN-004 AC-4)
        .sheet(isPresented: $viewModel.isSharePresented) {
            if let text = shareText {
                ShareLinkSheet(text: text)
            }
        }
        .onAppear {
            #if DEBUG
            handleLaunchArguments()
            #endif
        }
        .onDisappear { viewModel.onDisappear() }
        .animation(.easeInOut(duration: 0.25), value: viewModel.viewState)
    }

    // MARK: - Launch Argument Fixture Injection

    #if DEBUG
    /// 处理 XCUITest / Live Sim Review 启动参数注入确定性 fixture。
    ///
    /// 支持 `-ui-fixture creation-generated-letter|creation-generated-report|creation-empty|creation-saved`
    /// 及 `-creation-error`，通过 CreationFixtureLoader 加载确定性数据。
    /// 仅用于自动化；生产构建（#if DEBUG 排除）无此钩子。
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-ui-fixture"), idx + 1 < args.count else { return }
        let fixtureID = args[idx + 1]
        if let model = CreationFixtureLoader.load(fixtureID) {
            viewModel.loadPreloaded(model)
        } else if fixtureID == "creation-error" {
            viewModel.simulateError(.l2Recoverable(message: "Generation is currently unavailable. Please try again."))
        }
    }
    #endif

    // MARK: - Share Text

    /// 分享文本 — 生成内容 + 溯源锚点 (US-SYN-004 AC-4)。
    private var shareText: String? {
        guard let creation = viewModel.creation else { return nil }
        var lines: [String] = []
        if let title = creation.title {
            lines.append(title)
            lines.append("")
        }
        for paragraph in creation.paragraphs {
            lines.append(paragraph.text)
            if let citation = paragraph.citation {
                lines.append("[🔗 MemoryID:\(citation.memoryId.uuidString.prefix(8))…]")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Content Views

    /// 根据 ViewState 渲染对应内容
    @ViewBuilder
    private var contentView: some View {
        switch viewModel.viewState {
        case .idle:
            idleState

        case .generating:
            generatingState

        case .generated:
            if let creation = viewModel.creation {
                generatedContent(creation)
            } else {
                emptyState
            }

        case .empty:
            emptyState

        case .saving:
            savingState

        case .saved:
            if let creation = viewModel.creation {
                generatedContent(creation)
            } else {
                emptyState
            }

        case .error(let level):
            errorView(level: level)
        }
    }

    // MARK: - Idle State

    /// 初始态 — 模板选择 + 生成按钮 (US-SYN-003 AC-1)。
    private var idleState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Choose a template")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .accessibilityAddTraits(.isHeader)

                // 模板选择
                ForEach(CreationTemplate.allCases, id: \.self) { template in
                    templateRow(template)
                }

                // 生成按钮
                generateButton
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    /// 单个模板行 — 选择 + 展示。
    private func templateRow(_ template: CreationTemplate) -> some View {
        let isSelected = viewModel.selectedTemplate == template
        return Button {
            viewModel.selectTemplate(template)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: template.systemImage)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                Text(template.displayName)
                    .font(.body)
                    .foregroundStyle(Color.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(14)
            .background(
                isSelected ? Color(.systemGroupedBackground) : Color(.systemBackground),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(template.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier("creation-template-\(template.rawValue)")
    }

    /// 生成按钮 — 选择模板后启用。
    private var generateButton: some View {
        Button {
            viewModel.generate()
        } label: {
            Label("Generate", systemImage: "sparkles")
                .font(.callout)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.selectedTemplate == nil)
        .accessibilityIdentifier("creation-generate")
    }

    // MARK: - Generating State

    /// 生成中 — 系统 ProgressView (echo-memory-canvas §10.2)。
    private var generatingState: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .tint(Color.accentColor)
                .controlSize(.large)

            Text("Generating…")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)

            Spacer().frame(height: 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Generating creation")
    }

    // MARK: - Saving State

    /// 保存到备忘录中 (US-SYN-003 AC-4)。
    private var savingState: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .tint(Color.accentColor)
                .controlSize(.large)

            Text("Saving to Notes…")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)

            Spacer().frame(height: 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Saving to Notes…")
    }

    // MARK: - Generated Content

    /// 生成内容 — 单列内容流 + 溯源锚点 + 操作按钮 (US-SYN-003/004)。
    private func generatedContent(_ creation: CreationModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 标题（叙事报告含周期, US-SYN-004 AC-5）
                if let title = creation.title {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.primary)
                        .accessibilityAddTraits(.isHeader)
                }

                // 来源计数 metadata
                Label(String(format: EchoStrings.tr("%lld source memories"), creation.sourceMemoryCount), systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)

                // 生成内容 + 溯源锚点
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(creation.paragraphs) { paragraph in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(paragraph.text)
                                .font(.body)
                                .foregroundStyle(Color.primary)
                                .textSelection(.enabled)

                            if let citation = paragraph.citation {
                                citationAnchor(citation)
                            }
                        }
                    }
                }
                .padding(14)
                .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                // 操作按钮 (US-SYN-003 AC-3/AC-4, US-SYN-004 AC-4)
                actionButtons

                // 已保存 Toast + 链接 (US-SYN-003 AC-5)
                if viewModel.viewState == .saved {
                    savedToast
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    /// 溯源锚点 — [🔗 MemoryID:xxx] (US-SYN-002 AC-1, US-SYN-003 AC-2)。
    private func citationAnchor(_ citation: CreationCitation) -> some View {
        Button {
            // 🔮 Phase 3.9+: 跳转至原始数据详情页
        } label: {
            HStack(spacing: 6) {
                Image(systemName: citation.hasSource ? "link" : "exclamationmark.triangle")
                    .font(.caption)
                Text(citation.hasSource
                     ? "🔗 MemoryID:\(citation.memoryId.uuidString.prefix(8))…"
                     : "⚠️ NoSource")
                    .font(.caption)
            }
            .foregroundStyle(citation.hasSource ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!citation.hasSource)
        .accessibilityIdentifier("creation-citation-anchor-\(citation.memoryId.uuidString.prefix(8))")
        .accessibilityLabel(citation.hasSource ? "Source memory citation" : "No source available")
    }

    /// 操作按钮行 — 复制 / 导出 / 保存 / 分享。
    private var actionButtons: some View {
        VStack(spacing: 10) {
            // 复制 (AC-3)
            Button {
                viewModel.copyToClipboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("creation-copy")

            // 导出 (AC-3)
            Button {
                viewModel.presentExportPicker()
            } label: {
                Label("Export PDF / Markdown", systemImage: "square.and.arrow.up")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("creation-export")

            // 分享/打印 (US-SYN-004 AC-4)
            Button {
                viewModel.presentShare()
            } label: {
                Label("Share / Print", systemImage: "square.and.arrow.up.on.square")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("creation-share")

            // 保存到备忘录 (AC-4)
            Button {
                viewModel.saveToNotes()
            } label: {
                Label("Save to Notes", systemImage: "square.and.pencil")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("creation-save-to-notes")
        }
    }

    /// 已保存 Toast (US-SYN-003 AC-5)。
    /// ADR-013 决策 4 (3F.9): Notes 交接仅用系统 share/export，无 notes:// 深链 → 无 "Open" 链接。
    private var savedToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)

            Text(EchoStrings.tr(viewModel.saveToastMessage ?? "Saved"))
                .font(.subheadline)
                .foregroundStyle(Color.primary)

            Spacer()
        }
        .padding(12)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(viewModel.saveToastMessage ?? "Saved")
    }

    // MARK: - Empty State (US-SYN-003 无匹配源记忆)

    /// 空态 — 无匹配源记忆 (echo-memory-canvas §10.1.2 Focus 空态)。
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)

            Text("No source memories found")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(Color.primary)

            Text("Try a different template or add more memories.")
                .font(.body)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                viewModel.retry()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.callout)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("creation-retry-button")

            Spacer().frame(height: 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("No source memories found for this template")
    }

    // MARK: - Error State

    /// 错误视图 — L2 重试横幅 (docs/ui/architecture.md §2.2)。
    private func errorView(level: CreationViewModel.ErrorLevel) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.yellow)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text("Unable to generate")
                .font(.headline)
                .foregroundStyle(Color.primary)

            Text(EchoStrings.tr(errorMessage(for: level)))
                .font(.body)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                viewModel.retry()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.callout)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("creation-retry-button")

            Spacer().frame(height: 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func errorMessage(for level: CreationViewModel.ErrorLevel) -> String {
        switch level {
        case .l2Recoverable(let msg):
            return msg
        }
    }
}

// MARK: - PromptEditorSheet

/// Prompt 草稿编辑器 (US-SYN-005 AC-4) — 可编辑确认 + 重置为默认。
///
/// ## Surface Family: Task
/// - Form 布局（Task/Focus 共享 Form 容器，非 masonry）
/// - 字段: Prompt 草稿多行文本 + 确认/取消 + 重置
struct PromptEditorSheet: View {
    @Bindable var viewModel: CreationViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $viewModel.promptDraftText)
                        .frame(minHeight: 160)
                        .accessibilityIdentifier("creation-prompt-editor")
                } header: {
                    Text("Personal Prompt")
                } footer: {
                    Text("Used to personalize AI responses. Confirmed drafts are injected into synthesis requests.")
                }

                Section {
                    Button(role: .destructive) {
                        viewModel.resetPrompt()
                        dismiss()
                    } label: {
                        Label("Reset to default prompt", systemImage: "arrow.counterclockwise")
                    }
                    .accessibilityIdentifier("creation-reset-prompt")
                }
            }
            .navigationTitle("Personal Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        viewModel.cancelPromptEdit()
                    }
                    .accessibilityIdentifier("creation-prompt-cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") {
                        viewModel.confirmPrompt()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("creation-confirm-prompt")
                }
            }
        }
    }
}

// MARK: - ShareLinkSheet

/// 分享 Sheet — 生成内容分享/导出/打印 (US-SYN-003 AC-3, US-SYN-004 AC-4)。
///
/// ## Surface Family: Focus
/// - 系统分享面板，非 masonry
struct ShareLinkSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ShareLink(
                    item: text,
                    preview: SharePreview("Echo Creation")
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.callout)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("creation-share-link")

                Text("Share or export this creation as text, PDF, or Markdown.")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
            .padding()
            .navigationTitle("Share Creation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("creation-share-done")
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Idle") {
    NavigationStack {
        CreationView(viewModel: makeCreationViewModel(state: .idle))
    }
}

#Preview("Generating") {
    NavigationStack {
        CreationView(viewModel: makeCreationViewModel(state: .generating))
    }
}

#Preview("Generated Letter") {
    NavigationStack {
        CreationView(viewModel: makeCreationViewModel(state: .generatedLetter))
    }
}

#Preview("Generated Report") {
    NavigationStack {
        CreationView(viewModel: makeCreationViewModel(state: .generatedReport))
    }
}

#Preview("Empty") {
    NavigationStack {
        CreationView(viewModel: makeCreationViewModel(state: .empty))
    }
}

#Preview("Error") {
    NavigationStack {
        CreationView(viewModel: makeCreationViewModel(state: .error))
    }
}

#Preview("Saved") {
    NavigationStack {
        CreationView(viewModel: makeCreationViewModel(state: .saved))
    }
}

// MARK: - Preview Helpers

/// 从 fixture 构造确定性创作结果。
@MainActor
private func makeCreationViewModel(state: CreationPreviewState) -> CreationViewModel {
    let vm = CreationViewModel()

    switch state {
    case .idle:
        break

    case .generating:
        vm.selectTemplate(.letter)
        vm.generate()

    case .generatedLetter:
        if let model = CreationFixtureLoader.load("creation-generated-letter") {
            vm.loadPreloaded(model)
        }

    case .generatedReport:
        if let model = CreationFixtureLoader.load("creation-generated-report") {
            vm.loadPreloaded(model)
        }

    case .empty:
        if let model = CreationFixtureLoader.load("creation-empty") {
            vm.loadPreloaded(model)
        }

    case .error:
        vm.simulateError(.l2Recoverable(message: "Generation is currently unavailable. Please try again."))

    case .saved:
        if let model = CreationFixtureLoader.load("creation-saved") {
            vm.loadPreloaded(model)
        }
    }

    return vm
}

/// Preview 状态枚举
private enum CreationPreviewState {
    case idle
    case generating
    case generatedLetter
    case generatedReport
    case empty
    case error
    case saved
}
