// ==========================================
// 文件: HomeView.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8.
// 对应规格: docs/ui/echo-memory-canvas-style.md §3.1 (Discovery surfaces — 自适应卡片, 非 masonry),
//            §4 (共享 Token), §10.1.1 (无记忆时品牌欢迎页), §10.2.1 (骨架屏),
//            §16.1 (离线模式指示器 US-RES-001 AC-3)
//            docs/ui/architecture.md §3 (Surface View), §8 (Discovery surface family)
//            docs/01-spec/用户故事与验收标准规格书.md → US-AWK-001 AC-4, US-AWK-005, US-RES-001 AC-3
// 任务: 3.1 - HomeView + HomeViewModel + Awakening Cards + Offline Indicator
// AC 覆盖: US-AWK-001 AC-4 ✅ (唤醒卡片 UI), US-AWK-005 AC-1 ✅ (卡片展示),
//          US-RES-001 AC-3 ✅ (离线模式标识), AWK-002 AC-3 ✅ (纪念日卡片),
//          AWK-003 AC-4 ✅ (情绪卡片), AWK-005 AC-2 🔮 (左滑/右滑, Phase 3.3+)
// 架构约束: AGENTS.md §8.1 (ViewModel 驱动), §17.3 (Discovery 自适应卡片, 非 masonry),
//           §10.1 (Views 目录), echo-memory-canvas apple-native 基础
// 生成时间: 2026-07-26
// ==========================================

import SwiftUI

// MARK: - HomeView

/// Home 主视图 — 记忆发现与唤醒卡片主页。
///
/// ## Surface Family: Discovery
/// - 布局: 自适应内容卡片列表（非 masonry）
/// - 系统容器: NavigationStack (由 AppRootView 提供)
/// - Masonry 启用条件: 不满足 (§6.1 — 唤醒卡片内容简短, 但当前为单列自适应布局)
///
/// ## 状态驱动
/// - idle: 品牌欢迎页或初始状态
/// - loading: 骨架屏 (系统 .redacted)
/// - completed: 唤醒卡片列表 + 今日回忆提示
/// - error: 重试按钮
/// - cancelled: 返回 idle
///
/// ## 离线指示器 (US-RES-001 AC-3)
/// - isOffline = true 时, 顶部显示 wifi.slash 横幅
///
/// ## Style
/// - echo-memory-canvas token: .largeTitle, Color.primary, Color(.systemBackground), SF Symbols
/// - 禁止 masonry 布局, 禁止 Pinterest 品牌元素
/// - 使用系统 Dynamic Type, semantic colors, 系统容器
struct HomeView: View {
    // MARK: - ViewModel

    private var viewModel: HomeViewModel

    /// 后台任务面板 ViewModel — 由工具栏按钮展示 (US-SYS-001 AC-1 顶部状态栏入口)
    @State private var taskPanelViewModel = BackgroundTaskViewModel()

    /// 后台任务面板展示开关
    @State private var isTaskPanelPresented = false

    /// 降级横幅 ViewModel — Live Sim Review fixture 注入 (Task 3.6)
    @State private var degradationViewModel = DegradationBannerViewModel()

    /// 首次出现标记 — 控制 fixture 注入仅执行一次
    @State private var hasHandledLaunchArguments = false

    init(viewModel: HomeViewModel = HomeViewModel()) {
        self.viewModel = viewModel
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // Degradation banner (Task 3.6 — Live Sim Review fixture)
                DegradationBannerView(viewModel: degradationViewModel)

                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))

            // Offline banner (US-RES-001 AC-3)
            if viewModel.isOffline {
                offlineBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .navigationTitle("Echo · 回响")
        .navigationBarTitleDisplayMode(.large)
        .modifier(DisableLargeTitleScroll())
        .toolbar {
            // 后台任务面板入口 (US-SYS-001 AC-1: 顶部状态栏实时显示活跃任务)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    taskPanelViewModel.openPanel()
                    isTaskPanelPresented = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .accessibilityHidden(true)
                }
                .accessibilityLabel("Background Tasks")
                .accessibilityHint("Show active background task progress")
                .accessibilityIdentifier("background-tasks-open")
            }
        }
        .sheet(isPresented: $isTaskPanelPresented) {
            BackgroundTaskPanelView(viewModel: taskPanelViewModel) {
                taskPanelViewModel = BackgroundTaskViewModel()
            }
        }
        .onAppear {
            viewModel.onAppear()
            handleFirstAppear()
        }
        .onDisappear { viewModel.onDisappear() }
        .animation(.easeInOut(duration: 0.25), value: viewModel.viewState)
        .animation(.easeInOut(duration: 0.3), value: viewModel.isOffline)
    }

    // MARK: - Launch Argument Fixture Injection

    /// 首次出现时处理启动参数 fixture 注入。
    ///
    /// 支持 `-ui-fixture background-tasks-loaded|empty|error` — XCUITest / Live Sim Review
    /// 确定性导航到后台任务面板。生产构建（#if DEBUG 排除）无任何注入逻辑。
    private func handleFirstAppear() {
        guard !hasHandledLaunchArguments else { return }
        hasHandledLaunchArguments = true
        #if DEBUG
        handleLaunchArguments()
        #endif
    }

    #if DEBUG
    /// 处理 XCUITest / Live Sim Review 启动参数注入确定性 fixture。
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-ui-fixture"), idx + 1 < args.count else { return }
        let fixtureID = args[idx + 1]

        switch fixtureID {
        case "background-tasks-loaded", "background-tasks-empty":
            let items = BackgroundTaskFixtureLoader.load(fixtureID)
            taskPanelViewModel.loadPreloadedTasks(items)
            taskPanelViewModel.openPanel()
            isTaskPanelPresented = true

        case "degradation-low-power", "degradation-thermal", "degradation-model-degraded", "degradation-normal":
            degradationViewModel.loadFixture(fixtureID)

        default:
            break
        }
    }
    #endif

    // MARK: - Content Views

    /// 根据 ViewState 渲染对应内容
    @ViewBuilder
    private var contentView: some View {
        switch viewModel.viewState {
        case .idle, .loading:
            loadingSkeleton

        case .completed:
            if viewModel.awakeningCards.isEmpty {
                emptyWelcomePage
            } else {
                awakeningCardList
            }

        case .error(let level):
            errorView(level: level)

        case .cancelled:
            Color(.systemBackground)
                .onAppear { viewModel.dismissError() }
        }
    }

    // MARK: - Loading Skeleton

    /// 骨架屏 — 使用系统 .redacted(reason: .placeholder) (echo-memory-canvas §10.2.1)
    private var loadingSkeleton: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Welcome header skeleton
                welcomeHeaderSkeleton

                // Card skeletons
                ForEach(0..<4, id: \.self) { _ in
                    awakeningCardSkeleton
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .redacted(reason: .placeholder)
        .disabled(true)
        .accessibilityLabel("Loading awakening cards")
    }

    private var welcomeHeaderSkeleton: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(Color(.systemFill))
                .frame(width: 60, height: 60)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemFill))
                .frame(width: 200, height: 24)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.systemFill))
                .frame(width: 280, height: 16)
        }
        .padding(.vertical, 24)
    }

    private var awakeningCardSkeleton: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemFill))
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemFill))
                    .frame(width: 160, height: 16)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemFill))
                    .frame(width: 220, height: 12)
            }

            Spacer()
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Empty State (Brand Welcome Page)

    /// 空态 — 品牌欢迎页 (echo-memory-canvas §10.1.1)
    ///
    /// 当系统尚未摄入任何记忆时展示，而非空白列表。
    private var emptyWelcomePage: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer().frame(height: 40)

                // Echo Logo
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)

                // Title
                Text("Echo · 回响")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.primary)

                // Description
                Text("Your memories, always within reach.\nMemories from special places, past moments, and meaningful days will appear here.")
                    .font(.body)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)

                // Indicator
                ProgressView()
                    .tint(Color.accentColor)
                    .padding(.top, 8)

                Text("Echo is getting ready…")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)

                Spacer().frame(height: 60)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Echo welcome page. Your memories will appear here.")
    }

    // MARK: - Awakening Card List

    /// 唤醒卡片列表 — Discovery surface 自适应卡片布局
    private var awakeningCardList: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Section header
                sectionHeader

                // Awakening cards
                ForEach(viewModel.awakeningCards) { card in
                    AwakeningCardView(card: card)
                }

                // Bottom spacing for tab bar
                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .refreshable {
            viewModel.refresh()
        }
    }

    /// 列表章节头部
    private var sectionHeader: some View {
        HStack {
            Text("Awakenings")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(Color.primary)

            Spacer()

            Text("\(viewModel.awakeningCards.count) cards")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Error State

    /// 错误视图 — L2/L3 自适应
    @ViewBuilder
    private func errorView(level: HomeViewModel.ErrorLevel) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.yellow)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text(errorTitle(for: level))
                .font(.headline)
                .foregroundStyle(Color.primary)

            Text(errorMessage(for: level))
                .font(.body)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if isRecoverable(level) {
                Button {
                    viewModel.refresh()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.callout)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
            }

            Spacer().frame(height: 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: - Offline Banner

    /// 离线模式指示器 (US-RES-001 AC-3, echo-memory-canvas §16.1)
    ///
    /// 顶部 Banner, 浅灰背景, wifi.slash + "Offline mode — showing cached memories only"
    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.footnote)
                .foregroundStyle(Color.secondary)

            Text("Offline mode — showing cached memories only")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .padding(.top, 0)
        .accessibilityLabel("Offline mode")
        .accessibilityHint("Only cached memories are available")
    }

    // MARK: - Helpers

    private func errorTitle(for level: HomeViewModel.ErrorLevel) -> String {
        switch level {
        case .l2Recoverable:   return "Something went wrong"
        case .l3Blocking:      return "Unable to continue"
        }
    }

    private func errorMessage(for level: HomeViewModel.ErrorLevel) -> String {
        switch level {
        case .l2Recoverable(let msg),
             .l3Blocking(let msg):
            return msg
        }
    }

    private func isRecoverable(_ level: HomeViewModel.ErrorLevel) -> Bool {
        switch level {
        case .l2Recoverable: return true
        case .l3Blocking:    return false
        }
    }
}

// MARK: - AwakeningCardView

/// 唤醒卡片组件 — 展示单条唤醒记忆卡片。
///
/// ## Surface Family: Discovery
/// - 自适应卡片布局, 遵循 echo-memory-canvas token
/// - 包含: SF Symbol 图标 + 标题 + 副标题 + 相对时间
/// - 点击: 🔮 跳转 Focus surface (Phase 3.3 MemoryDetailView)
///
/// ## Style
/// - 系统 background + shadow 层级
/// - 系统 Dynamic Type: .headline, .subheadline, .caption
/// - SF Symbol: 由 triggerType 决定
struct AwakeningCardView: View {
    let card: AwakeningCardModel

    var body: some View {
        HStack(spacing: 14) {
            // Trigger type icon
            iconView

            // Card text content
            textContent

            Spacer(minLength: 8)

            // Relative time
            Text(card.relativeTimeDescription)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: Color.black.opacity(0.04), radius: 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityHint("Tap to view memories")
        .contentShape(Rectangle())
        .onTapGesture {
            // 🔮 Phase 3.3+: Navigate to MemoryDetailView with card.memoryIds
        }
    }

    // MARK: - Icon

    private var iconView: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.1))
                .frame(width: 44, height: 44)

            Image(systemName: card.symbolName)
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Text

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(card.title)
                .font(.headline)
                .foregroundStyle(Color.primary)
                .lineLimit(1)

            Text(card.subtitle)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
        }
    }

    // MARK: - Accessibility

    private var cardAccessibilityLabel: String {
        "\(card.title), \(card.subtitle), \(card.relativeTimeDescription)"
    }
}

// MARK: - Preview

#Preview("Idle / Loading") {
    NavigationStack {
        HomeView()
    }
}

#Preview("Awakening Cards") {
    NavigationStack {
        HomeView(viewModel: makePreviewViewModel(
            cards: [
                ("geofenceOnly", "Shanghai Tower"),
                ("emotionNegative", "Home"),
                ("anniversary", "Paris 2024"),
                ("emotionNeutral", "Office"),
            ]
        ))
    }
}

#Preview("Offline Mode") {
    NavigationStack {
        HomeView(viewModel: makePreviewViewModel(
            cards: [("geofenceOnly", "Central Park")],
            isOffline: true
        ))
    }
}

// MARK: - Preview Helpers

@MainActor
private func makePreviewViewModel(cards: [(String, String)], isOffline: Bool = false) -> HomeViewModel {
    let vm = HomeViewModel()
    for (triggerType, region) in cards {
        vm.appendAwakeningCard(AwakeningCard(
            cardId: UUID(),
            memoryIds: [UUID()],
            triggerType: triggerType,
            regionId: region,
            createdAt: Date().addingTimeInterval(-Double.random(in: 60...86400))
        ))
    }
    vm.loadAwakeningCardsPreloaded()
    if isOffline { vm.setOffline(true) }
    return vm
}

// MARK: - iOS 26 Large Title Workaround

/// iOS 26 (Liquid Glass) 将 Large Title 与内容中第一个最高层 ScrollView 联动，
/// overscroll 时标题被拉下穿过固定 Banner（iOS 18 无此行为，标题固定在导航栏）。
/// 通过包裹一个禁用的横向 ScrollView，让 NavigationStack 将标题关联到不可滚动外层，
/// 使标题在 iOS 26 上保持固定，与 iOS 18 行为一致。
/// 参考: stackoverflow.com/q/79771449 (Large navigation title scrolls with ScrollView)
/// 仅 iOS 26+ 生效；iOS 18 原样返回，不改变现有正确行为。
private struct DisableLargeTitleScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        Rectangle()
                            .frame(height: 0.5)
                            .foregroundStyle(.clear)
                        content
                            .frame(width: proxy.size.width)
                    }
                }
                .scrollDisabled(true)
            }
        } else {
            content
        }
    }
}
