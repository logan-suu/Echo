// ==========================================
// 文件: MemoryDetailViewModel.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-007 (手动编辑记忆),
//            US-SYN-002 (溯源锚点), US-SYN-003 (创作预览), US-PRV-004 (删除确认), US-DIS-002 (按需翻译)
//            docs/ui/echo-memory-canvas-style.md §3.2 (Focus surfaces — 单列 + grouped metadata),
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.3 - MemoryDetailView + ViewModel + Edit + Conflict + Creation + Translation
// AC 覆盖: US-AWK-007 AC-1 ✅ (编辑入口: 标题/描述/标签/时间戳), AC-4 ✅ (冲突解决 UI, 🔮 Core 写),
//          US-DIS-002 AC-4 ✅ (原文/译文切换), US-PRV-004 AC-1 ✅ (删除双选项弹窗, 🔮 Core 写),
//          US-SYN-002 AC-1 ✅ (溯源锚点展示), US-SYN-003 AC-3 ✅ (创作预览/复制)
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum: idle/loading/completed/error/cancelled),
//           §8.2 (状态流转), §4.2 (仅持有不可变引用), docs/ui/architecture.md §6~7 (适配器契约),
//           §2.5 (Adapter 不保存第二份领域真相 — 仅转换展示字段)
// 生成时间: 2026-08-01
// ==========================================

import SwiftUI
import Foundation

// MARK: - Memory Detail UI Model

/// 媒体预览类型 — 详情页按记忆 sourceType 渲染媒体内容（US-RET-001 媒体记忆展示）。
enum MediaKind: Equatable, Sendable {
    /// 无媒体 — 纯文本记忆（note）
    case none
    /// 图片预览（photo）
    case image
    /// 视频播放（video_frame / video_audio）
    case video
    /// 音频播放（voice）
    case audio
}

/// UI 层记忆详情展示模型 — 从 Core ``Memory`` / ``MemoryEntry`` 映射的薄适配器。
///
/// 适配器职责 (docs/ui/architecture.md §7.1):
/// - 状态映射: Core 值类型 → UI State
/// - 不保存第二份领域真相 — 仅按需转换展示字段
struct MemoryDetailModel: Identifiable, Sendable, Equatable {
    /// 记忆唯一标识 (映射自 Memory.memoryId / MemoryEntry.id)
    let id: UUID
    /// 数据源引用
    let assetId: String
    /// 数据源类型 ("photo" / "note" / "voice" / "video_frame" 等)
    let sourceType: String
    /// 记忆标题（用户可编辑，US-AWK-007）
    var title: String
    /// 正文内容（备忘录/语音转写文本）
    var originalText: String
    /// 源语言
    let sourceLanguage: String
    /// 首选语言 (UserPolicy.preferredLanguage)
    let preferredLanguage: String
    /// 记忆时间戳（用户可覆盖时间戳，US-AWK-007 AC-1）
    var timestamp: Date
    /// 自定义标签列表 (US-AWK-007)
    var tags: [String]
    /// 用户已编辑标记 (US-AWK-007 AC-2 → userEdited=true)
    var userEdited: Bool

    // MARK: - Translation (US-DIS-002)

    /// 翻译可见性 — 原文/译文切换
    var translationVisible: Bool
    /// 译文文本（未请求时为 nil）
    var translatedText: String?
    /// 翻译置信度 — < 0.7 时保留原文 + 语言标签 (US-DIS-002 AC-3)
    var translationConfidence: Double?

    // MARK: - Conflict (US-AWK-007 AC-4)

    /// 冲突信息 — 外部数据源变更而用户编辑未保存
    var conflict: MemoryConflictModel?

    // MARK: - Media Preview (US-RET-001 媒体记忆展示)

    /// Bundle 内示例媒体资源名（photo/video/voice 记忆详情媒体预览）。
    /// UI 切片阶段确定性媒体样本；生产路径由 Core 提供媒体引用（Phase 3.9）。
    var mediaAssetName: String?

    // MARK: - Location (US-RET-004 多维元数据)

    /// 地点描述（geohash/地名，检索元数据）。无地点时为 nil。
    var location: String?

    // MARK: - Init

    init(
        id: UUID,
        assetId: String,
        sourceType: String,
        title: String,
        originalText: String,
        sourceLanguage: String,
        preferredLanguage: String,
        timestamp: Date,
        tags: [String] = [],
        userEdited: Bool = false,
        translationVisible: Bool = false,
        translatedText: String? = nil,
        translationConfidence: Double? = nil,
        conflict: MemoryConflictModel? = nil,
        mediaAssetName: String? = nil,
        location: String? = nil
    ) {
        self.id = id
        self.assetId = assetId
        self.sourceType = sourceType
        self.title = title
        self.originalText = originalText
        self.sourceLanguage = sourceLanguage
        self.preferredLanguage = preferredLanguage
        self.timestamp = timestamp
        self.tags = tags
        self.userEdited = userEdited
        self.translationVisible = translationVisible
        self.translatedText = translatedText
        self.translationConfidence = translationConfidence
        self.conflict = conflict
        self.mediaAssetName = mediaAssetName
        self.location = location
    }

    // MARK: - Presentation Helpers

    /// 是否展示翻译切换按钮 — 源语言 ≠ 首选语言时 (US-DIS-002)
    var needsTranslation: Bool {
        sourceLanguage != preferredLanguage
    }

    /// 媒体预览类型 — 从 sourceType 派生，不保存第二份领域真相 (docs/ui/architecture.md §7.1)
    var mediaKind: MediaKind {
        switch sourceType {
        case "photo":         return .image
        case "video_frame", "video_audio": return .video
        case "voice":         return .audio
        default:              return .none
        }
    }

    /// 数据源类型展示标签
    var sourceTypeLabel: String {
        switch sourceType {
        case "photo":       return "Photo"
        case "video_frame": return "Video"
        case "video_audio": return "Video audio"
        case "note":        return "Note"
        case "voice":       return "Voice"
        default:            return sourceType
        }
    }

    /// 时间描述（绝对日期）
    var dateDescription: String {
        timestamp.formatted(date: .abbreviated, time: .omitted)
    }

    /// VoiceOver 标签 (echo-memory-canvas §17.3)
    var accessibilityLabel: String {
        "\(sourceTypeLabel), \(title), \(dateDescription)"
    }
}

// MARK: - Memory Conflict Model

/// 记忆编辑冲突模型 (US-AWK-007 AC-4)。
///
/// 外部数据源变更而用户编辑未保存时标记 conflict，提供差异化对比。
struct MemoryConflictModel: Sendable, Equatable {
    /// 用户本地编辑草稿
    let localDraft: String
    /// 外部新版本内容
    let externalVersion: String
}

// MARK: - MemoryDetailViewModel

/// 记忆详情视图 ViewModel — 内容展示 + 翻译切换 + 编辑 + 冲突解决 + 删除确认。
///
/// ## Surface Family: Focus
/// - 布局: 单列内容流 + grouped metadata（echo-memory-canvas §3.2）
/// - 样式: echo-memory-canvas + apple-native 基础
/// - Masonry: 禁止（Focus surface）
///
/// ## 职责 (docs/ui/architecture.md §7.1)
/// - 状态映射: Memory/MemoryEntry → MemoryDetailModel
/// - 错误映射: L1~L4 → error state
/// - Intent 转发: 翻译/编辑/删除/冲突解决 → Core await 调用（🔮 Phase 3.9）
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
final class MemoryDetailViewModel {
    // MARK: - State Enum

    /// ViewModel 统一状态枚举 (AGENTS.md §8.1)
    enum ViewState: Equatable, Sendable {
        /// 初始状态 — 尚未加载
        case idle
        /// 加载中 — ProgressView
        case loading
        /// 加载完成 — 展示内容
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

    /// 冲突解决选择 (US-AWK-007 AC-4)
    enum ConflictResolution: Equatable, Sendable {
        /// 保留用户编辑 → userLocked=true，后续同步跳过
        case local
        /// 使用外部新版本
        case external
    }

    // MARK: - Published State

    /// 统一视图状态
    private(set) var viewState: ViewState = .idle
    /// 当前展示的记忆详情
    private(set) var memory: MemoryDetailModel?
    /// 编辑 Sheet 是否呈现 (US-AWK-007)
    var isEditing: Bool = false
    /// 删除确认弹窗是否呈现 (US-PRV-004)
    var showDeleteConfirmation: Bool = false

    // MARK: - Edit Form State (US-AWK-007 AC-1)

    /// 编辑标题
    var editTitle: String = ""
    /// 编辑描述（富文本 → 当前为多行文本）
    var editDescription: String = ""
    /// 编辑标签列表
    var editTags: String = ""
    /// 编辑覆盖时间戳
    var editTimestamp = Date()

    // MARK: - Dependencies

    /// 当前活跃的加载 Task
    private var loadTask: Task<Void, Never>?

    /// UI 切片模式模拟记忆源 — fixture 注入
    private var stubMemory: MemoryDetailModel?

    // MARK: - Initialization

    init() {}

    // MARK: - Actions

    /// 加载指定记忆详情。
    ///
    /// 设置 state = .loading，加载完成后设置 .completed 或 .error。
    /// 🔮 Phase 3.9+: 通过 Core 按 memoryId 拉取。当前 UI 切片通过 loadPreloaded 注入。
    func load(memoryId: UUID) {
        guard viewState != .loading else { return }

        loadTask?.cancel()

        // Set loading synchronously (AGENTS.md §8.1: first line of action)
        viewState = .loading

        loadTask = Task { [weak self] in
            guard let self else { return }

            // 短暂模拟加载以展示 loading 态
            try? await Task.sleep(nanoseconds: 250_000_000)

            guard !Task.isCancelled else {
                self.viewState = .cancelled
                return
            }

            if let stub = self.stubMemory {
                self.memory = stub
                self.viewState = .completed
            } else {
                self.viewState = .error(.l2Recoverable(
                    message: "Unable to load this memory. Please try again."
                ))
            }
        }
    }

    /// 预加载确定性记忆详情（Preview / 测试 / XCUITest fixture 注入）。
    ///
    /// - Parameter model: MemoryDetailModel（来自 fixture loader）
    func loadPreloaded(_ model: MemoryDetailModel) {
        stubMemory = model
        memory = model
        viewState = .completed
    }

    /// 切换原文/译文 (US-DIS-002 AC-4)。
    ///
    /// 源语言 ≠ 首选语言时可用。译文若未请求，通过翻译服务获取
    /// （🔮 Phase 3.8 接入 translationCache + Apple Translation；当前为 fixture 注入）。
    func toggleTranslation() {
        guard let current = memory, current.needsTranslation else { return }
        memory?.translationVisible.toggle()
    }

    /// 呈现编辑 Sheet (US-AWK-007 AC-1)。
    ///
    /// 从当前记忆填充编辑表单。若记忆已被外部修改（conflict），
    /// 不进入表单，交由冲突 UI 处理。
    func presentEditSheet() {
        guard let current = memory else { return }
        // AC-4: 外部数据源已变更时，阻止直接编辑，先解决冲突
        guard current.conflict == nil else { return }
        editTitle = current.title
        editDescription = current.originalText
        editTags = current.tags.joined(separator: ", ")
        editTimestamp = current.timestamp
        isEditing = true
    }

    /// 保存编辑 (US-AWK-007 AC-2)。
    ///
    /// 更新本地展示模型（userEdited=true），重新向量化 🔮 Phase 3.9。
    /// 若编辑期间外部数据源变更（conflict 被置位），阻止保存。
    func saveEdit() {
        guard var current = memory else { return }

        // AC-4: 编辑期间外部变更 → 阻止保存（由 SyncPipeline 检测时置位 conflict）
        if current.conflict != nil {
            isEditing = false
            return
        }

        let trimmedTitle = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            current.title = trimmedTitle
        }
        current.originalText = editDescription
        current.tags = editTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        current.timestamp = editTimestamp
        current.userEdited = true

        memory = current
        isEditing = false
    }

    /// 呈现删除确认弹窗 (US-PRV-004 AC-1)。
    func presentDeleteConfirmation() {
        showDeleteConfirmation = true
    }

    /// 选择"仅从 Echo 移除" (US-PRV-004 AC-2)。
    ///
    /// 保留原始文件，写入 ExcludedAssets（🔮 Phase 3.9 Core 写路径）。
    func removeFromEcho() {
        showDeleteConfirmation = false
        // 🔮 Phase 3.9+: 调用 ExcludedAssetsActor 写入 + 事务性清除记忆副本
        // 当前 UI 切片仅完成交互语义，展示已移除状态
        viewState = .completed
        memory = nil
    }

    /// 选择"同时删除原始文件" (US-PRV-004 AC-3)。
    ///
    /// 调用系统 API 删除原始文件，级联清除 Echo 数据，不写入 ExcludedAssets。
    func deleteOriginal() {
        showDeleteConfirmation = false
        // 🔮 Phase 3.9+: 调用系统删除 API + 级联清除
        viewState = .completed
        memory = nil
    }

    /// 解决冲突 (US-AWK-007 AC-4)。
    ///
    /// - keep: 保留用户编辑（.local）或使用外部版本（.external）
    func resolveConflict(keep: ConflictResolution) {
        guard var current = memory, let conflict = current.conflict else { return }

        switch keep {
        case .local:
            // 保留用户编辑，清除冲突标记，userLocked=true（后续同步跳过）
            current.conflict = nil
            current.userEdited = true

        case .external:
            // 使用外部新版本
            current.originalText = conflict.externalVersion
            current.conflict = nil
        }

        memory = current
    }

    /// 重试加载 (L2 恢复路径)。
    func retry() {
        guard let current = memory else {
            if let stub = stubMemory {
                loadPreloaded(stub)
            } else {
                viewState = .idle
            }
            return
        }
        _ = current
        viewState = .completed
    }

    #if DEBUG
    /// 仅 Preview/调试使用 — 直接构造错误状态，不触发任何副作用。
    /// 生产路径的错误由 load() 的 catch 自然产生，不调用此方法。
    func simulateError(_ level: ErrorLevel) {
        viewState = .error(level)
    }
    #endif

    /// 消除错误状态，返回 idle。
    func dismissError() {
        viewState = .idle
    }

    /// 取消当前加载任务。
    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        viewState = .cancelled
    }

    // MARK: - Lifecycle

    /// 视图消失时调用 — 取消进行中的任务；已完成内容保留。
    ///
    /// iOS 17+ NavigationStack push / TabView 切换会触发 onDisappear，
    /// 无条件取消会导致从详情切走再返回时卡在 loading（回归 2026-08-02 修复）。
    /// loading 状态离开 → cancelled（返回后回 idle）；completed 状态保留内容。
    func onDisappear() {
        loadTask?.cancel()
        loadTask = nil
        if viewState == .loading {
            viewState = .cancelled
        }
    }
}
