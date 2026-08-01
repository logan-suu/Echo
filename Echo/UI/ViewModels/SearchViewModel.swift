// ==========================================
// 文件: SearchViewModel.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RET-001 (语义检索), US-RET-006 (低置信度),
//            US-FBK-001 (👍/👎), US-FBK-003 (Bad Case), US-SRC-005 (手动扫描结果页)
//            docs/ui/echo-memory-canvas-style.md §14 (筛选与搜索 UI 模式), §6.2 (List 回退)
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.2 - SearchView + SearchViewModel + Feedback + Low-confidence banner + Scan results
// AC 覆盖: US-RET-001 AC-3 ✅ (结果展示), US-RET-006 AC-2/AC-4 ✅ (低置信度横幅),
//          US-FBK-001 AC-1 ✅ (👍/👎 按钮), US-FBK-003 AC-1 ✅ (Bad Case 标记)
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum: idle/loading/completed/error/cancelled),
//           §8.2 (状态流转), §4.2 (仅持有不可变引用), docs/ui/architecture.md §6~7 (适配器契约),
//           §2.5 (Adapter 不保存第二份领域真相 — 仅转换展示字段)
// 生成时间: 2026-08-01
// ==========================================

import SwiftUI
import Foundation

// MARK: - Search Result UI Model

/// UI 层搜索结果展示模型 — 从 ``SearchResultItem`` 映射的薄适配器。
///
/// 适配器职责 (docs/ui/architecture.md §7.1):
/// - 状态映射: Core 值类型 → UI State
/// - 不保存第二份领域真相 — 仅按需转换展示字段，不复制检索/重排规则
struct SearchResultModel: Identifiable, Sendable, Equatable {
    /// 记忆唯一标识 (映射自 SearchResultItem.id)
    let id: UUID
    /// 数据源引用
    let assetId: String
    /// 数据源类型 ("photo" / "video_frame" / "video_audio" / "text" / "voice")
    let sourceType: String
    /// 记忆时间戳
    let timestamp: TimeInterval
    /// 原文内容（文本/语音记忆），nil = 图片/视频帧
    let originalText: String?
    /// 源语言
    let sourceLanguage: String?
    /// 是否跨语言匹配
    let crossLanguageMatch: Bool
    /// 余弦相似度 (0~1)
    let cosineSimilarity: Float
    /// 跨语言对齐置信度
    let alignmentScore: Float?
    /// 低置信度标记 (US-RET-006)
    let lowConfidence: Bool
    /// 低置信度原因
    let fallbackReason: String?

    /// 从 Core ``SearchResultItem`` 映射。
    init(from item: SearchResultItem) {
        self.id = item.id
        self.assetId = item.assetId
        self.sourceType = item.sourceType
        self.timestamp = item.timestamp
        self.originalText = item.originalText
        self.sourceLanguage = item.sourceLanguage
        self.crossLanguageMatch = item.crossLanguageMatch
        self.cosineSimilarity = item.cosineSimilarity
        self.alignmentScore = item.alignmentScore
        self.lowConfidence = item.lowConfidence
        self.fallbackReason = item.fallbackReason
    }

    // MARK: - Presentation Helpers

    /// 数据源类型展示标签
    var sourceTypeLabel: String {
        switch sourceType {
        case "photo":         return "Photo"
        case "video_frame":   return "Video"
        case "video_audio":   return "Video audio"
        case "text":          return "Note"
        case "voice":         return "Voice"
        default:              return sourceType
        }
    }

    /// 内容摘要 — 优先原文摘要，其次来源类型
    var summary: String {
        if let text = originalText, !text.isEmpty {
            return text
        }
        return "A \(sourceTypeLabel.lowercased()) memory"
    }

    /// 相似度百分比展示
    var similarityPercent: String {
        "\(Int(cosineSimilarity * 100))%"
    }

    /// 时间描述（绝对日期）
    var dateDescription: String {
        let date = Date(timeIntervalSince1970: timestamp)
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// VoiceOver 标签 (echo-memory-canvas §17.3)
    var accessibilityLabel: String {
        let type = sourceTypeLabel
        let text = originalText ?? "a \(type.lowercased()) memory"
        return "\(type), \(text), \(dateDescription)"
    }
}

// MARK: - SearchViewModel

/// 检索视图 ViewModel — 搜索状态管理 + 反馈转发。
///
/// ## Surface Family: Discovery
/// - 布局: 系统 List（搜索结果是混合文本/图片内容，需阅读顺序 → §6.2 单列回退）
/// - 样式: echo-memory-canvas + apple-native 基础
///
/// ## 职责 (docs/ui/architecture.md §7.1)
/// - 线程隔离: SearchPipeline (actor) → @MainActor 状态
/// - 状态映射: SearchResultItem → SearchResultModel
/// - 错误映射: SearchError L1~L4 → error state
/// - Intent 转发: 反馈/重试 → SearchPipeline / FeedbackPipeline await 调用
/// - 生命周期: Task 管理，View 消失时 cancel
///
/// ## 状态流转 (AGENTS.md §8.2)
/// ```
/// idle → loading → completed
///                → error(L2/L3)
///                → cancelled
/// ```
@MainActor
@Observable
final class SearchViewModel {
    // MARK: - State Enum

    /// ViewModel 统一状态枚举 (AGENTS.md §8.1)
    enum ViewState: Equatable, Sendable {
        /// 初始状态 — 尚未搜索
        case idle
        /// 搜索中 — ProgressView 或骨架屏
        case loading
        /// 搜索完成 — 展示结果或空态
        case completed
        /// 错误状态 — 按 L2/L3 区分 UI 表现
        case error(ErrorLevel)
        /// 已取消 — 用户离开页面
        case cancelled
    }

    /// 错误等级 — 对应 AGENTS.md §4.4 L1~L4
    enum ErrorLevel: Equatable, Sendable {
        /// L2 可恢复: Toast + 重试按钮
        case l2Recoverable(message: String)
        /// L3 阻断: 全屏引导页
        case l3Blocking(message: String)
    }

    /// 单条结果的反馈状态（本地 UI 状态，不写回 Core 领域）
    enum FeedbackState: Equatable, Sendable {
        case none
        case liked
        case disliked
        case badCase
    }

    // MARK: - Published State

    /// 统一视图状态
    private(set) var viewState: ViewState = .idle
    /// 搜索结果列表（由 SearchPipeline 返回后填充）
    private(set) var results: [SearchResultModel] = []
    /// 当前查询文本
    private(set) var query: String = ""
    /// 跨语言低置信度标记 (US-RET-006) — 任一结果低置信度时显示横幅
    var hasLowConfidence: Bool { results.contains(where: \.lowConfidence) }
    /// 每条结果的反馈状态（本地 UI 展示）
    private(set) var feedbackStates: [UUID: FeedbackState] = [:]
    /// 是否已执行过搜索（区分 idle 空态与 completed 空态）
    private(set) var hasSearched: Bool = false

    // MARK: - Dependencies (Immutable Actor References)

    /// SearchPipeline 引用 — 不可变 actor 引用 (docs/ui/architecture.md §6.4)
    /// 可选注入: Phase 3.9 完整集成后通过 DI 容器注入
    private let searchPipeline: SearchPipeline?
    /// FeedbackPipeline 引用 — 反馈转发 (US-FBK-001/003)
    private let feedbackPipeline: FeedbackPipeline?

    /// 当前活跃的搜索 Task
    private var searchTask: Task<Void, Never>?

    /// UI 切片模式模拟检索源 — fixture 注入；空数组 = 无注入（搜索进入空态）
    private var stubResults: [SearchResultItem] = []

    // MARK: - Initialization

    /// 初始化 SearchViewModel。
    ///
    /// - Parameters:
    ///   - searchPipeline: SearchPipeline 实例（可选注入）
    ///   - feedbackPipeline: FeedbackPipeline 实例（可选注入）
    ///   Phase 3.9 完整集成后通过 DI 容器注入。
    init(searchPipeline: SearchPipeline? = nil, feedbackPipeline: FeedbackPipeline? = nil) {
        self.searchPipeline = searchPipeline
        self.feedbackPipeline = feedbackPipeline
    }

    // MARK: - Actions

    /// 提交搜索查询。
    ///
    /// 设置 state = .loading，调用 SearchPipeline.search()，完成后设置 .completed 或 .error。
    /// 遵循 AGENTS.md §8.2 状态流转: idle→loading→completed/error/cancelled。
    func submitQuery(_ newQuery: String) {
        // 防止重复搜索
        guard viewState != .loading else { return }

        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 取消已有 Task
        searchTask?.cancel()

        // Set loading synchronously (AGENTS.md §8.1: first line of action)
        query = trimmed
        viewState = .loading

        searchTask = Task { [weak self] in
            guard let self else { return }

            do {
                // 🔮 Phase 3.9+: SearchPipeline 完整接入。当前 UI 切片在 Preview/测试中
                // 通过 loadPreloadedResults 注入确定性数据。真实检索依赖 embedder + vectorStore
                // 运行时初始化（见 3.11 引导流程 Core 初始化）。
                if let pipeline = self.searchPipeline {
                    let items = try await pipeline.search(
                        query: self.query,
                        k: 10,
                        traceID: UUID().uuidString
                    )
                    guard !Task.isCancelled else {
                        self.viewState = .cancelled
                        return
                    }
                    self.results = items.map(SearchResultModel.init)
                } else {
                    // 无 Pipeline（UI 切片模式）：返回 fixture 注入的 stub 结果，
                    // 模拟真实检索（Phase 3.9 接入 SearchPipeline 后此分支移除）。
                    try await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else {
                        self.viewState = .cancelled
                        return
                    }
                    self.results = self.stubResults.map(SearchResultModel.init)
                }

                self.hasSearched = true
                self.viewState = .completed
            } catch is CancellationError {
                self.viewState = .cancelled
            } catch {
                guard !Task.isCancelled else {
                    self.viewState = .cancelled
                    return
                }
                self.viewState = Self.mapError(error)
            }
        }
    }

    /// 将 SearchPipeline 抛出的错误按 L1~L4 等级映射到 UI 状态（AGENTS.md §4.4）。
    ///
    /// - L1 瞬态: Pipeline 内部已完成指数退避重试（3 次），此处不重复重试
    /// - L2 可恢复: `.l2Recoverable` → Toast + 重试按钮
    /// - L3 阻断: `.l3Blocking` → 全屏引导页（不再显示无意义的重试）
    static func mapError(_ error: Error) -> ViewState {
        guard let searchError = error as? SearchError else {
            return .error(.l2Recoverable(message: error.localizedDescription))
        }
        switch searchError.errorLevel {
        case 3:
            return .error(.l3Blocking(message: searchError.errorDescription ?? "Unable to continue"))
        default:
            return .error(.l2Recoverable(message: searchError.errorDescription ?? "Search failed. Please try again."))
        }
    }

    /// 重试上一次搜索 (L2 恢复路径)。
    func retry() {
        let lastQuery = query
        guard !lastQuery.isEmpty else {
            viewState = .idle
            return
        }
        submitQuery(lastQuery)
    }

    /// 预加载确定性搜索结果（Preview / 测试 / XCUITest fixture 注入）。
    ///
    /// - Parameter items: SearchResultItem 数组（来自 fixture loader）
    func loadPreloadedResults(_ items: [SearchResultItem]) {
        stubResults = items
        results = items.map(SearchResultModel.init)
        hasSearched = true
        viewState = .completed
    }

    /// 清除结果，返回 idle。
    func clearResults() {
        searchTask?.cancel()
        results = []
        feedbackStates = [:]
        hasSearched = false
        viewState = .idle
    }

    // MARK: - Feedback Intents (US-FBK-001 / US-FBK-003)

    /// 记录点赞。转发到 FeedbackPipeline（存在时），并更新本地 UI 反馈状态。
    func recordLike(_ result: SearchResultModel) {
        feedbackStates[result.id] = .liked
        guard let pipeline = feedbackPipeline else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await pipeline.recordLike(
                    memoryId: result.id,
                    queryText: self.query,
                    cosineSimilarity: Double(result.cosineSimilarity)
                )
            } catch {
                // L1/L2 反馈写入失败：保持本地 UI 状态，静默降级（非阻断）
                // Phase 3.9+ 统一错误处理 UI（Task 3.6）接管展示
            }
        }
    }

    /// 记录点踩。转发到 FeedbackPipeline（存在时），并更新本地 UI 反馈状态。
    func recordDislike(_ result: SearchResultModel) {
        feedbackStates[result.id] = .disliked
        guard let pipeline = feedbackPipeline else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await pipeline.recordDislike(
                    memoryId: result.id,
                    queryText: self.query,
                    cosineSimilarity: Double(result.cosineSimilarity)
                )
            } catch {
                // 同上，静默降级
            }
        }
    }

    /// 标记 Bad Case (US-FBK-003)。转发到 FeedbackPipeline（存在时），并更新本地 UI 状态。
    func markBadCase(_ result: SearchResultModel) {
        feedbackStates[result.id] = .badCase
        guard let pipeline = feedbackPipeline else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await pipeline.markBadCase(
                    memoryId: result.id,
                    queryText: self.query,
                    reason: "Marked as problematic from search results"
                )
            } catch {
                // 同上，静默降级
            }
        }
    }

    /// 取消当前搜索任务。
    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        viewState = .cancelled
    }

    /// 消除错误状态，返回 idle。
    func dismissError() {
        viewState = .idle
    }

    #if DEBUG
    /// 仅 Preview/调试使用 — 直接构造错误状态，不触发任何副作用。
    /// 生产路径的错误由 submitQuery 的 catch 自然产生，不调用此方法。
    func simulateError(_ level: ErrorLevel) {
        viewState = .error(level)
    }
    #endif

    // MARK: - Lifecycle

    /// 视图消失时调用 — 取消正在进行的任务。
    func onDisappear() {
        cancelSearch()
    }
}
