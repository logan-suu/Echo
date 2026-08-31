// ==========================================
// 文件: OnboardingViewModel.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8/3.9.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-PRV-008 (PIPL 隐私同意),
//            US-SRC-001 AC-6 (首次授权 iCloud 下载提示), US-SYN-001 AC-2 (语言选择)
//            docs/ui/echo-memory-canvas-style.md §15 (引导流程), §3.3 (Task surfaces),
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.11 - 引导流程：欢迎页 + PIPL 隐私同意 + 权限序列 + 语言选择 + 首次模型加载
//       3F.1 - 同意持久化接线 (ADR-007 §决策-2, US-PRV-008 AC-4)
// AC 覆盖: US-PRV-008 AC-1 ✅ (隐私摘要), AC-2 ✅ (摘要含目的/方式/种类/保留期限/本地处理声明),
//          AC-3 ✅ (同意/拒绝同等醒目), AC-4 🔶 (Settings 撤回同意入口, UI 切片留待 Settings 页集成),
//          AC-5 🔶 (撤回=注销流程, Core Phase 3.9), US-SRC-001 AC-6 ✅ (iCloud 提示 + Open Settings 意图),
//          US-SYN-001 AC-2 ✅ (zh-Hans/en-US 选择 + 繁体映射提示), 首次模型加载 ✅ (4 模型真实逐项进度)
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum), §8.2 (状态流转),
//           docs/ui/architecture.md §6~7 (适配器契约), §2.5 (Adapter 不保存第二份领域真相 — 仅转换展示字段)
// 生成时间: 2026-08-03, 2026-08-04 (Task 3F.1)
// PR#65 third review fix: explicit fixture model loading takes precedence over live dependencies.
// ==========================================

import SwiftUI
import Foundation
@preconcurrency import Photos

// MARK: - Production Onboarding Content

/// Production-owned onboarding copy and permission order. Fixtures mirror this
/// configuration; the production composition root never reads a fixture loader.
enum OnboardingContentDefaults {
    static let privacySummary =
        "Echo processes your photos, videos, notes, and voice memos locally on your device to build a searchable personal memory index.\n\n"
        + "Purpose: To let you search, recall, and awaken memories from your own content.\n"
        + "Methods: All processing happens on-device using local AI models.\n"
        + "Data types: Media assets and transcripts you share with Echo.\n"
        + "Retention: Your data is kept until you delete it or remove it from Echo.\n"
        + "Local processing: Your data never leaves this device and is never uploaded."

    static let deniedMessage =
        "Without photo access, Echo cannot index your images and videos. You can still use Echo with notes and voice memos."

    static let mappingHint =
        "Echo currently supports Simplified Chinese and English only. It will display in Simplified Chinese."

    static let permissionSteps: [OnboardingPermission] = [
        OnboardingPermission(
            id: "photos",
            title: "Photos",
            purpose: "Echo reads your photo library locally to index and search images and videos.",
            systemImage: "photo.on.rectangle.angled",
            icloudHint: "For complete memories, set iCloud Photos to 'Download and Keep Originals' or download before using Echo. Optimized storage may not be recognizable.",
            openSettingsLabel: "Open Settings"
        ),
        OnboardingPermission(
            id: "notifications",
            title: "Notifications",
            purpose: "Echo sends local reminders to surface your memories at the right moment.",
            systemImage: "bell.badge"
        ),
        OnboardingPermission(
            id: "location",
            title: "Location",
            purpose: "Echo can wake with memories tied to where you are.",
            systemImage: "location"
        ),
        OnboardingPermission(
            id: "health",
            title: "Health",
            purpose: "Echo reads health context to enrich memory awakening. Raw values are not stored.",
            systemImage: "heart"
        ),
    ]
}

// MARK: - Permission Adapter

@MainActor
protocol OnboardingPermissionRequesting: AnyObject, Sendable {
    func request(_ permission: OnboardingPermission) async -> Bool
}

/// Thin system boundary used only by production onboarding.
@MainActor
final class SystemOnboardingPermissionRequester: OnboardingPermissionRequesting {
    private let notifications: any NotificationScheduling
    private let location: any LocationProviding
    private let health: any HealthStoreServing

    init(
        notifications: any NotificationScheduling = LocalNotificationAdapter(),
        location: any LocationProviding = CoreLocationProvider(),
        health: any HealthStoreServing = RealHealthStore()
    ) {
        self.notifications = notifications
        self.location = location
        self.health = health
    }

    deinit {}

    func request(_ permission: OnboardingPermission) async -> Bool {
        switch permission.id {
        case "photos":
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return status == .authorized || status == .limited

        case "notifications":
            return await notifications.requestAuthorization() == .authorized

        case "location":
            let status = await location.requestWhenInUseAuthorization()
            return status != .denied && status != .restricted

        case "health":
            guard health.isHealthDataAvailable() else { return false }
            return await health.requestAuthorization() == .authorized

        default:
            return false
        }
    }
}

// MARK: - Model Loading Adapter

/// Thin loading boundary used by onboarding so production uses the real actor while
/// fixtures can remain deterministic and offline.
nonisolated protocol OnboardingModelLoading: Sendable {
    func loadModel(_ modelType: ModelLoaderActor.ModelType) async -> ModelLoaderActor.ModelLoadState
}

extension ModelLoaderActor: OnboardingModelLoading {}

nonisolated struct OnboardingModelLoadProgress: Sendable, Equatable {
    nonisolated struct Item: Identifiable, Sendable, Equatable {
        nonisolated enum State: Sendable, Equatable {
            case pending
            case loading
            case loaded
            case failed
        }

        let modelType: ModelLoaderActor.ModelType
        var state: State

        var id: ModelLoaderActor.ModelType { modelType }

        nonisolated var displayName: String {
            switch modelType {
            case .multilingualE5Small: "Multilingual E5"
            case .siglip2Vision: "SigLIP2 Vision"
            case .siglip2Text: "SigLIP2 Text"
            case .whisperTiny: "Whisper Tiny"
            }
        }
    }

    var items: [Item]

    var completedCount: Int {
        items.filter { $0.state == .loaded || $0.state == .failed }.count
    }

    var failedCount: Int {
        items.filter { $0.state == .failed }.count
    }

    var fractionCompleted: Double {
        guard !items.isEmpty else { return 0 }
        return Double(completedCount) / Double(items.count)
    }

    static var initial: Self {
        Self(items: ModelLoaderActor.ModelType.allCases.map { Item(modelType: $0, state: .pending) })
    }

    static var fixtureLoading: Self {
        var value = initial
        guard value.items.count >= 2 else { return value }
        value.items[0].state = .loaded
        value.items[1].state = .loading
        return value
    }
}

// MARK: - OnboardingViewModel

/// 引导流程 ViewModel — 管理五步引导状态机 (欢迎→PIPL 同意→权限→语言→模型加载)。
///
/// ## Surface Family: Task
/// - 布局: fullScreenCover + 分步 TabView (echo-memory-canvas §15.1, §3.3)
/// - Masonry: 禁止 (Task surface)
///
/// ## 状态流转 (AGENTS.md §8.2)
/// ```
/// welcome → privacyConsent → permissions(0..3) → language → modelLoading → completed
///                                                               → modelLoadFailed → retry | limited completion
///                              → permissionDenied → (openSettings | skip) → next
/// privacyConsent → declined (PIPL 拒绝, US-PRV-008 AC-3)
/// ```
///
/// ## 职责 (docs/ui/architecture.md §7.1)
/// - 状态映射: fixture 载荷 → UI 步骤
/// - Intent 转发: 同意/拒绝/授权/跳过/选语言/开始加载 → Core 调用
/// - 3F.1: 同意持久化经 consentStore (ADR-007 §决策-2, US-PRV-008 AC-4)
@MainActor
@Observable
final class OnboardingViewModel {
    nonisolated static func progressPercentText(_ progress: Double) -> String {
        "\(Int(progress * 100))%"
    }

    // MARK: - State Enum

    /// 引导流程统一状态 (AGENTS.md §8.1)
    enum ViewState: Equatable, Sendable {
        /// Step 1 欢迎页
        case welcome
        /// Step 2 PIPL 隐私同意
        case privacyConsent
        /// Step 3 权限序列 (当前权限索引)
        case permissions(Int)
        /// 权限被拒绝 → 前往设置 / 跳过
        case permissionDenied(Int)
        /// Step 4 语言选择
        case language
        /// Step 5 首次模型加载（逐模型真实状态见 modelLoadProgress）
        case modelLoading
        /// 至少一个模型加载失败；停留在引导页等待用户手动重试或降级继续
        case modelLoadFailed
        /// 引导完成 → 进入主界面
        case completed
        /// 用户拒绝 PIPL → 退出 (US-PRV-008 AC-3)
        case declined

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.welcome, .welcome), (.privacyConsent, .privacyConsent),
                 (.language, .language), (.modelLoadFailed, .modelLoadFailed),
                 (.completed, .completed), (.declined, .declined):
                return true

            case (.permissions(let l), .permissions(let r)):
                return l == r

            case (.permissionDenied(let l), .permissionDenied(let r)):
                return l == r

            case (.modelLoading, .modelLoading):
                return true

            default:
                return false
            }
        }
    }

    deinit {}

    // MARK: - Published State

    /// 统一视图状态
    private(set) var viewState: ViewState = .welcome

    /// Production permission sequence. Explicit fixtures may replace it in tests.
    private(set) var permissionSteps: [OnboardingPermission] = OnboardingContentDefaults.permissionSteps

    /// 隐私政策摘要 (US-PRV-008 AC-2)
    private(set) var privacySummary: String = OnboardingContentDefaults.privacySummary

    /// 权限拒绝提示 (US-SRC-001 AC-6 情境)
    private(set) var deniedMessage: String = OnboardingContentDefaults.deniedMessage

    /// Prevents duplicate system permission requests from repeated taps.
    private(set) var permissionRequestInFlight = false

    /// True only after an explicit Preview/test fixture injection.
    private(set) var isFixtureBacked = false

    /// 当前选择的语言 (US-SYN-001 AC-2)
    private(set) var selectedLanguage: String?

    /// 繁体/方言映射提示是否可见 (US-SYN-001 AC-2) — 首次启动提示一次
    private(set) var mappingHintVisible: Bool = false

    /// 是否已请求打开系统设置 (US-SRC-001 AC-6)
    private(set) var openSettingsRequested = false

    /// Whether consent has been persisted (3F.1, US-PRV-008 AC-4)
    private(set) var consentPersisted = false

    /// Whether consent persistence failed (write errors surfaced for a retry UI)
    private(set) var consentPersistFailed = false

    /// Real per-model progress retained after completion for diagnostics and tests.
    private(set) var modelLoadProgress: OnboardingModelLoadProgress = .initial

    /// Simulated model load delay - tests inject 0 to complete loading instantly (fixture mode)
    private let loadDelayNanoseconds: UInt64

    /// Model loading task
    private var loadTask: Task<Void, Never>?

    /// Fixture injection source for the UI-slice mode
    private var stubFixture: OnboardingFixture?

    /// Consent store actor (3F.1 production wiring; nil in fixture/test mode)
    private let consentStore: ConsentStoreActor?

    /// Production model loader. Nil only for deterministic fixtures/previews.
    private let modelLoader: (any OnboardingModelLoading)?

    /// System permission boundary. Tests can inject a deterministic spy.
    private let permissionRequester: any OnboardingPermissionRequesting

    // MARK: - Initialization

    /// Initialize OnboardingViewModel.
    ///
    /// - Parameter loadDelayNanoseconds: simulated first-model-load duration;
    ///   tests inject 0 for instant completion; default 3s (10 ticks, 300ms each).
    /// - Parameter consentStore: consent store actor (3F.1 production wiring, default nil).
    init(loadDelayNanoseconds: UInt64 = 3_000_000_000,
         consentStore: ConsentStoreActor? = nil,
         modelLoader: (any OnboardingModelLoading)? = nil,
         permissionRequester: any OnboardingPermissionRequesting = SystemOnboardingPermissionRequester()) {
        self.loadDelayNanoseconds = loadDelayNanoseconds
        self.consentStore = consentStore
        self.modelLoader = modelLoader
        self.permissionRequester = permissionRequester
    }

    // MARK: - Actions

    /// Step 1 → Step 2: 点击"开始"进入隐私同意 (echo-memory-canvas §15.2→§15.3)。
    func start() {
        guard viewState == .welcome else { return }
        viewState = .privacyConsent
    }

    /// Step 2: 同意隐私政策 → 进入权限序列 (US-PRV-008 AC-3)。
    ///
    /// 3F.1: 若已注入 consentStore，同意持久化到 ConsentStore (US-PRV-008 AC-4)。
    func acceptPrivacy() {
        guard viewState == .privacyConsent else { return }
        if let consentStore {
            Task {
                do {
                    try await consentStore.acceptConsent(consentVersion: 1, policyVersion: 1)
                    consentPersisted = true
                } catch {
                    // Never swallow: mark persistence failure so the UI can surface a retry path
                    consentPersistFailed = true
                }
            }
        }
        if permissionSteps.isEmpty {
            viewState = .language
            applyDefaultLanguage()
        } else {
            viewState = .permissions(0)
        }
    }

    /// Step 2: 拒绝隐私政策 → declined 退出态 (US-PRV-008 AC-3)。
    ///
    /// 3F.1: 拒绝不入库（保持 deny-by-default 未同意状态）。
    func declinePrivacy() {
        guard viewState == .privacyConsent else { return }
        consentPersisted = false
        viewState = .declined
    }

    /// Step 3: Request the current system permission, then advance only on success.
    func allowPermission() {
        guard case .permissions(let index) = viewState,
              permissionSteps.indices.contains(index),
              !permissionRequestInFlight else { return }

        if isFixtureBacked {
            advancePermission(from: index)
            return
        }

        let permission = permissionSteps[index]
        permissionRequestInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.permissionRequester.request(permission)
            self.permissionRequestInFlight = false
            guard self.viewState == .permissions(index) else { return }
            if granted {
                self.advancePermission(from: index)
            } else {
                self.viewState = .permissionDenied(index)
            }
        }
    }

    private func advancePermission(from index: Int) {
        let next = index + 1
        if next < permissionSteps.count {
            viewState = .permissions(next)
        } else {
            enterLanguageStep()
        }
    }

    /// Step 3: 拒绝当前权限 → permissionDenied 态 (US-SRC-001 AC-6 提示 + 前往设置)。
    func denyPermission() {
        guard case .permissions(let index) = viewState else { return }
        viewState = .permissionDenied(index)
    }

    /// permissionDenied: 打开系统设置 (US-SRC-001 AC-6)。
    ///
    /// 记录 intent；实际 UIApplication.openSettingsURLString 调用由 View 触发。
    func openSettings() {
        openSettingsRequested = true
    }

    /// permissionDenied: 跳过该权限，继续前进 (US-SRC-001 AC-6 拒绝后继续使用部分功能)。
    func skipPermission() {
        guard case .permissionDenied(let index) = viewState else { return }
        let next = index + 1
        if next < permissionSteps.count {
            viewState = .permissions(next)
        } else {
            enterLanguageStep()
        }
    }

    /// 进入语言选择步骤并应用默认语言 (US-SYN-001 AC-1)。
    private func enterLanguageStep() {
        viewState = .language
        applyDefaultLanguage()
    }

    /// Step 4: 选择语言 (US-SYN-001 AC-2)。
    ///
    /// 繁体/方言 → 映射 zh-Hans + 首次提示一次 (AGENTS.md §1.3)。
    /// AppRootView persists this selection through LanguageCenter when onboarding completes.
    func selectLanguage(_ language: String) {
        guard case .language = viewState else { return }
        let normalized = language == "zh-Hans" ? "zh-Hans" : "en-US"
        selectedLanguage = normalized
    }

    /// Step 4: 根据系统语言设置默认首选语言 (US-SYN-001 AC-1)。
    ///
    /// 仅支持 zh-Hans/en-US；繁体/方言映射为 zh-Hans (AGENTS.md §1.3)。
    /// Reset restores the production default; persisted language is restored by LanguageCenter.
    func applyDefaultLanguage() {
        guard case .language = viewState, selectedLanguage == nil else { return }
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        if code == "zh" {
            selectedLanguage = "zh-Hans"
            let region = Locale.current.language.region?.identifier
            // 繁体区域 (TW/HK/MO) 或方言 → 映射提示 (US-SYN-001 AC-2)
            if region == "TW" || region == "HK" || region == "MO" {
                mappingHintVisible = true
            }
        } else {
            selectedLanguage = "en-US"
        }
    }

    /// Step 4 → Step 5: 开始首次模型加载。
    ///
    /// Production uses ModelLoaderActor results; fixtures use the same four-row state model deterministically.
    func beginLoad() {
        guard case .language = viewState else { return }
        // Fallback: cross-page jumps may skip the onAppear initialization, so set the
        // default language here before Continue can be used
        if selectedLanguage == nil { applyDefaultLanguage() }
        guard selectedLanguage != nil else { return }
        modelLoadProgress = .initial
        viewState = .modelLoading
        startModelLoad()
    }

    /// Model failure recovery is user initiated only (US-RES-004 AC-3).
    func retryModelLoad() {
        guard viewState == .modelLoadFailed else { return }
        for index in modelLoadProgress.items.indices where modelLoadProgress.items[index].state == .failed {
            updateModel(at: index, state: .pending)
        }
        viewState = .modelLoading
        startModelLoad()
    }

    /// Preserve the specified FTS5/basic-browsing fallback when a model remains unavailable.
    func continueWithLimitedFeatures() {
        guard viewState == .modelLoadFailed else { return }
        viewState = .completed
    }

    /// 重置到初始状态。
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        viewState = .welcome
        permissionSteps = OnboardingContentDefaults.permissionSteps
        privacySummary = OnboardingContentDefaults.privacySummary
        deniedMessage = OnboardingContentDefaults.deniedMessage
        permissionRequestInFlight = false
        isFixtureBacked = false
        selectedLanguage = nil
        mappingHintVisible = false
        openSettingsRequested = false
        modelLoadProgress = .initial
        stubFixture = nil
    }

    // MARK: - Model Loading

    /// 首次模型加载（echo-memory-canvas §15.6）。
    ///
    /// 生产路径逐个调用真实 ModelLoaderActor，并在每次调用完成后根据返回状态推进。
    /// fixture/preview 路径使用同一份 4 模型清单，但不访问生产模型文件。
    private func startModelLoad() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let models = ModelLoaderActor.ModelType.allCases
            for (index, modelType) in models.enumerated() {
                guard !Task.isCancelled else { return }
                self.updateModel(at: index, state: .loading)

                let result: ModelLoaderActor.ModelLoadState
                if self.isFixtureBacked {
                    let delay = self.loadDelayNanoseconds / UInt64(max(models.count, 1))
                    do {
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        return
                    }
                    result = .loaded
                } else if let modelLoader = self.modelLoader {
                    result = await modelLoader.loadModel(modelType)
                } else {
                    result = .failed(.modelNotFound(
                        modelName: modelType.modelName,
                        resourceName: modelType.resourceIdentifier
                    ))
                }

                guard !Task.isCancelled else { return }
                switch result {
                case .loaded:
                    self.updateModel(at: index, state: .loaded)

                case .failed:
                    self.updateModel(at: index, state: .failed)

                case .notLoaded, .loading:
                    self.updateModel(at: index, state: .failed)
                }
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            self.viewState = self.modelLoadProgress.failedCount == 0 ? .completed : .modelLoadFailed
        }
    }

    private func updateModel(at index: Int, state: OnboardingModelLoadProgress.Item.State) {
        guard modelLoadProgress.items.indices.contains(index) else { return }
        var progress = modelLoadProgress
        progress.items[index].state = state
        modelLoadProgress = progress
    }

    // MARK: - Fixture Injection

    /// 注入确定性 fixture (Preview / 测试 / XCUITest / Live Sim Review)。
    ///
    /// - Parameter fixtureID: onboarding-welcome | onboarding-privacy-consent | onboarding-permissions |
    ///                        onboarding-permission-denied | onboarding-language | onboarding-model-loading |
    ///                        onboarding-completed | onboarding-declined
    func loadFixture(_ fixtureID: String) {
        let fixture = OnboardingFixtureLoader.load(fixtureID)
        stubFixture = fixture
        isFixtureBacked = true
        applyFixture(fixture)
    }

    /// 将 fixture 载荷应用到 ViewModel 状态。
    private func applyFixture(_ fixture: OnboardingFixture) {
        permissionSteps = fixture.permissionSteps
        privacySummary = fixture.privacySummary
        deniedMessage = fixture.declinedMessage ?? OnboardingFixtureLoader.deniedMessage
        selectedLanguage = fixture.selectedLanguage
        mappingHintVisible = fixture.mappingHintVisible

        switch fixture.currentStep {
        case .welcome:
            viewState = .welcome

        case .privacyConsent:
            viewState = .privacyConsent

        case .permissions:
            viewState = .permissions(fixture.permissionIndex)

        case .permissionDenied:
            viewState = .permissionDenied(fixture.permissionIndex)

        case .language:
            viewState = .language
            applyDefaultLanguage()

        case .modelLoading:
            modelLoadProgress = .fixtureLoading
            viewState = .modelLoading

        case .completed:
            viewState = .completed

        case .declined:
            viewState = .declined
        }
    }

    /// 模拟触发语言映射提示 (US-SYN-001 AC-2) — 测试/Preview 注入。
    func simulateMappingHint() {
        guard viewState == .language else { return }
        selectedLanguage = "zh-Hans"
        mappingHintVisible = true
    }
}
