// ==========================================
// 文件: HomeViewModel.swift
// i18n: AwakeningCardModel title/subtitle strings are hardcoded English. String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-001 AC-4 (唤醒卡片),
//            US-AWK-002 AC-3 (纪念日唤醒), US-AWK-003 AC-4 (情绪唤醒卡片),
//            US-AWK-005 AC-1~3 (交互式卡片展示), US-RES-001 AC-3 (离线标识)
//            docs/ui/echo-memory-canvas-style.md §10.1 (空态/加载态), §16.1 (离线指示器)
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.1 - HomeView + HomeViewModel + Awakening Cards + Offline Indicator
// AC 覆盖: US-AWK-001 AC-4 ✅ (唤醒卡片展示), US-AWK-002 AC-3 ✅ (纪念日卡片),
//          US-AWK-003 AC-4 ✅ (情绪唤醒卡片), US-AWK-005 AC-1 ✅ (卡片展示),
//          US-RES-001 AC-3 ✅ (离线模式标识), AC-2 ❌ (无网络时仅缓存, Phase 4)
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum: idle/loading/completed/error/cancelled),
//           §8.2 (状态流转: idle→loading→completed/error/cancelled),
//           §4.2 (Actor 隔离 — 仅持有不可变引用), §8.2 (禁止 idle→completed 直接跳转),
//           docs/ui/architecture.md §2.2 (错误传播路径), §6 (ViewModel 状态枚举)
// 生成时间: 2026-07-26
// ==========================================

import SwiftUI
import Foundation

// MARK: - Awakening Card UI Model

/// UI 层唤醒卡片展示模型 — 从 ``AwakeningPipeline.AwakeningCard`` 映射的薄适配器。
///
/// 适配器职责 (docs/ui/architecture.md §7.1):
/// - 状态映射: Core 值类型 → UI State
/// - 不保存第二份领域真相 — 仅按需转换展示字段
struct AwakeningCardModel: Identifiable, Sendable, Equatable {
    /// 卡片唯一标识 (映射自 AwakeningCard.cardId)
    let id: UUID
    /// 关联的记忆 ID 列表
    let memoryIds: [UUID]
    /// 触发类型 (geofenceOnly / emotionNegative / emotionNeutral / anniversary)
    let triggerType: String
    /// 触发地点或来源标识
    let sourceLabel: String
    /// 卡片生成时间
    let createdAt: Date
    /// 卡片标题文案（English catalog key source; Phase 3 test contract）
    let title: String
    /// 卡片副标题/摘要文案（English catalog key source; Phase 3 test contract）
    let subtitle: String
    /// 对应的 SF Symbol 图标名
    let symbolName: String
    /// String Catalog key for the localized title (3F.10 i18n)
    let titleKey: String
    /// Format arguments for the localized title
    let titleArgs: [String]
    /// String Catalog key for the localized subtitle (3F.10 i18n)
    let subtitleKey: String

    // MARK: - Init from Core Model

    /// 从 ``AwakeningCard`` 映射为 UI 展示模型。
    ///
    /// - Parameter card: AwakeningPipeline 生成的唤醒卡片
    init(from card: AwakeningCard) {
        self.id = card.cardId
        self.memoryIds = card.memoryIds
        self.triggerType = card.triggerType
        self.sourceLabel = card.regionId
        self.createdAt = card.createdAt

        switch card.triggerType {
        case "geofenceOnly":
            self.title = "Arrived at \(card.regionId)"
            self.subtitle = "A memory from this place"
            self.symbolName = "mappin.circle.fill"
            self.titleKey = "Arrived at %@"
            self.titleArgs = [card.regionId]
            self.subtitleKey = "A memory from this place"

        case "emotionNegative":
            self.title = "A bright moment for you"
            self.subtitle = "Joyful memories from the past"
            self.symbolName = "sparkles"
            self.titleKey = "A bright moment for you"
            self.titleArgs = []
            self.subtitleKey = "Joyful memories from the past"

        case "emotionNeutral":
            self.title = "A moment to reflect"
            self.subtitle = "Thoughtful memories"
            self.symbolName = "leaf.circle.fill"
            self.titleKey = "A moment to reflect"
            self.titleArgs = []
            self.subtitleKey = "Thoughtful memories"

        case "anniversary":
            self.title = "On this day"
            self.subtitle = "Memories from years past"
            self.symbolName = "clock.arrow.circlepath"
            self.titleKey = "On this day"
            self.titleArgs = []
            self.subtitleKey = "Memories from years past"

        default:
            self.title = "Awakening"
            self.subtitle = "A memory surfaced for you"
            self.symbolName = "bell.circle.fill"
            self.titleKey = "Awakening"
            self.titleArgs = []
            self.subtitleKey = "A memory surfaced for you"
        }
    }

    @MainActor
    var localizedTitle: String {
        let template = EchoStrings.tr(titleKey)
        guard !titleArgs.isEmpty else { return template }
        return String(format: template, arguments: titleArgs.map { $0 as CVarArg })
    }

    @MainActor
    var localizedSubtitle: String {
        EchoStrings.tr(subtitleKey)
    }

    /// 相对时间描述
    var relativeTimeDescription: String {
        let interval = Date().timeIntervalSince(createdAt)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    @MainActor
    var localizedRelativeTime: String {
        let interval = Date().timeIntervalSince(createdAt)
        if interval < 60 { return EchoStrings.tr("Just now") }
        if interval < 3600 { return String(format: EchoStrings.tr("%lldm ago"), Int(interval / 60)) }
        if interval < 86400 { return String(format: EchoStrings.tr("%lldh ago"), Int(interval / 3600)) }
        return String(format: EchoStrings.tr("%lldd ago"), Int(interval / 86400))
    }
}

// MARK: - HomeViewModel

/// Home 视图 ViewModel — 唤醒卡片展示 + 离线状态管理。
///
/// ## Surface Family: Discovery
/// - 布局: 自适应卡片列表（非 masonry）
/// - 样式: echo-memory-canvas + apple-native 基础
///
/// ## 职责 (docs/ui/architecture.md §7.1)
/// - 线程隔离: AwakeningPipeline (actor) → @MainActor 状态
/// - 状态映射: AwakeningCard → AwakeningCardModel (UI 模型)
/// - 错误映射: L1~L4 → error state
/// - Intent 转发: User Action → Core await 调用
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
final class HomeViewModel {
    // MARK: - State Enum

    /// ViewModel 统一状态枚举 (AGENTS.md §8.1)
    enum ViewState: Equatable, Sendable {
        /// 初始状态 — 尚未加载
        case idle
        /// 加载中 — 骨架屏或 ProgressView
        case loading
        /// 加载完成 — 正常展示内容
        case completed
        /// 错误状态 — 按 L2/L3 区分 UI 表现
        case error(ErrorLevel)
        /// 已取消 — 用户离开页面或手动取消
        case cancelled
    }

    /// 错误等级 — 对应 AGENTS.md §4.4 L1~L4
    enum ErrorLevel: Equatable, Sendable {
        /// L2 可恢复: Toast + 重试按钮
        case l2Recoverable(message: String)
        /// L3 阻断: 全屏引导页
        case l3Blocking(message: String)
    }

    // MARK: - Published State

    /// 统一视图状态
    private(set) var viewState: ViewState = .idle
    /// 唤醒卡片列表（由 AwakeningPipeline 事件驱动填充）
    private(set) var awakeningCards: [AwakeningCardModel] = []
    /// 离线模式标识 (US-RES-001 AC-3)
    private(set) var isOffline: Bool = false

    // MARK: - Dependencies (Immutable Actor References)

    /// AwakeningPipeline 引用 — 不可变 actor 引用，合法模式 (docs/ui/architecture.md §6.4)
    /// 可选注入: Phase 3 初期卡片由事件驱动，Pipeline 作为可选依赖
    private let awakeningPipeline: AwakeningPipeline?

    /// 3F.8: 唤醒卡片持久化存储（ADR-012 决策-5）— 启动时加载最近卡片
    private let cardRepository: AwakeningCardRepositoryActor?

    /// 当前活跃的加载 Task
    private var loadingTask: Task<Void, Never>?

    // MARK: - Initialization

    /// 初始化 HomeViewModel。
    ///
    /// - Parameter awakeningPipeline: AwakeningPipeline 实例（可选注入）。
    ///   Phase 3.12+ 完整集成后通过 DI 容器注入。
    /// - Parameter cardRepository: 唤醒卡片持久化存储（3F.8，可选注入）。
    init(
        awakeningPipeline: AwakeningPipeline? = nil,
        cardRepository: AwakeningCardRepositoryActor? = nil
    ) {
        self.awakeningPipeline = awakeningPipeline
        self.cardRepository = cardRepository
    }

    deinit {}

    // MARK: - Actions

    /// 加载唤醒卡片列表。
    ///
    /// 设置 state = .loading，执行加载，完成后设置 .completed 或 .error。
    /// 遵循 AGENTS.md §8.2 状态流转: idle→loading→completed/error/cancelled。
    func loadAwakeningCards() {
        // 防止重复加载
        guard viewState != .loading else { return }

        // 取消已有 Task
        loadingTask?.cancel()

        // Set loading synchronously (AGENTS.md §8.1: first line of action)
        viewState = .loading

        loadingTask = Task { [weak self] in
            guard let self else { return }

            do {
                // 3F.8: 从持久化卡片存储加载最近唤醒卡片（ADR-012 决策-5，重启去重后展示）
                if let cardRepository {
                    let cards = try await cardRepository.fetchRecent(limit: 20)
                    self.awakeningCards = cards.map(AwakeningCardModel.init)
                } else if let pipeline = self.awakeningPipeline {
                    // Example: cards would be fetched from a local store
                    // let cards = await pipeline.fetchRecentCards()
                    _ = pipeline // Silenced for now; Phase 3.12+ wires the store
                }

                guard !Task.isCancelled else {
                    self.viewState = .cancelled
                    return
                }

                self.viewState = .completed
            } catch is CancellationError {
                self.viewState = .cancelled
            } catch {
                guard !Task.isCancelled else {
                    self.viewState = .cancelled
                    return
                }
                self.viewState = .error(.l2Recoverable(
                    message: "Unable to load awakening cards. Please try again."
                ))
            }
        }
    }

    /// 刷新唤醒卡片 — 下拉刷新时调用。
    func refresh() {
        loadAwakeningCards()
    }

    /// Set state to completed with preloaded cards (for Preview/testing only).
    func loadAwakeningCardsPreloaded() {
        viewState = .completed
    }

    /// 手动添加一张唤醒卡片（由 Pipeline 事件驱动时调用）。
    ///
    /// - Parameter card: AwakeningPipeline 生成的原始卡片
    func appendAwakeningCard(_ card: AwakeningCard) {
        let model = AwakeningCardModel(from: card)
        awakeningCards.insert(model, at: 0)
    }

    /// 设置离线模式状态 (US-RES-001 AC-3)。
    ///
    /// - Parameter offline: 是否离线
    func setOffline(_ offline: Bool) {
        isOffline = offline
    }

    func offlineIndicatorAccessibilityLabel(locale: Locale) -> String {
        EchoLocalization.localized("Offline mode", locale: locale)
    }

    /// 消除错误状态，返回 idle。
    func dismissError() {
        viewState = .idle
    }

    /// 取消当前加载任务。
    func cancelLoading() {
        loadingTask?.cancel()
        loadingTask = nil
        viewState = .cancelled
    }

    // MARK: - Lifecycle

    /// 视图出现时调用 — 触发首次加载。
    func onAppear() {
        if viewState == .idle {
            loadAwakeningCards()
        }
    }

    /// 视图消失时调用 — 取消正在进行的任务。
    func onDisappear() {
        cancelLoading()
    }
}
