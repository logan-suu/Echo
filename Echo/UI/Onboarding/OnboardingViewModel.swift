// ==========================================
// 文件: OnboardingViewModel.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8/3.9.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-PRV-008 (PIPL 隐私同意),
//            US-SRC-001 AC-6 (首次授权 iCloud 下载提示), US-SYN-001 AC-2 (语言选择)
//            docs/ui/echo-memory-canvas-style.md §15 (引导流程), §3.3 (Task surfaces),
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.11 - 引导流程：欢迎页 + PIPL 隐私同意 + 权限序列 + 语言选择 + 首次模型加载
// AC 覆盖: US-PRV-008 AC-1 ✅ (隐私摘要), AC-2 ✅ (摘要含目的/方式/种类/保留期限/本地处理声明),
//          AC-3 ✅ (同意/拒绝同等醒目), AC-4 🔶 (Settings 撤回同意入口, UI 切片留待 Settings 页集成),
//          AC-5 🔶 (撤回=注销流程, Core Phase 3.9), US-SRC-001 AC-6 ✅ (iCloud 提示 + Open Settings 意图),
//          US-SYN-001 AC-2 ✅ (zh-Hans/en-US 选择 + 繁体映射提示), 首次模型加载 ✅ (fixture 驱动 determinate 进度)
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum), §8.2 (状态流转),
//           docs/ui/architecture.md §6~7 (适配器契约), §2.5 (Adapter 不保存第二份领域真相 — 仅转换展示字段)
// 生成时间: 2026-08-03
// ==========================================

import SwiftUI
import Foundation

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
///                              → permissionDenied → (openSettings | skip) → next
/// privacyConsent → declined (PIPL 拒绝, US-PRV-008 AC-3)
/// ```
///
/// ## 职责 (docs/ui/architecture.md §7.1)
/// - 状态映射: fixture 载荷 → UI 步骤
/// - Intent 转发: 同意/拒绝/授权/跳过/选语言/开始加载 → 后续 Core 调用 (🔮 Phase 3.9 PrivacyActor/UserPolicy)
/// - 🔮 Phase 3.9: PrivacyActor.updatePolicy + UserPolicyStore 持久化; ModelLoaderActor 真实进度
@MainActor
@Observable
final class OnboardingViewModel {
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
        /// Step 5 首次模型加载 (进度 0.0~1.0)
        case modelLoading(Double)
        /// 引导完成 → 进入主界面
        case completed
        /// 用户拒绝 PIPL → 退出 (US-PRV-008 AC-3)
        case declined

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.welcome, .welcome), (.privacyConsent, .privacyConsent),
                 (.language, .language), (.completed, .completed), (.declined, .declined):
                return true

            case (.permissions(let l), .permissions(let r)):
                return l == r

            case (.permissionDenied(let l), .permissionDenied(let r)):
                return l == r

            case (.modelLoading(let l), .modelLoading(let r)):
                return l == r

            default:
                return false
            }
        }
    }

    deinit {}

    // MARK: - Published State

    /// 统一视图状态
    private(set) var viewState: ViewState = .welcome

    /// 当前权限步骤列表 (fixture 注入)
    private(set) var permissionSteps: [OnboardingPermission] = []

    /// 隐私政策摘要 (US-PRV-008 AC-2)
    private(set) var privacySummary: String = ""

    /// 权限拒绝提示 (US-SRC-001 AC-6 情境)
    private(set) var deniedMessage: String = ""

    /// 当前选择的语言 (US-SYN-001 AC-2)
    private(set) var selectedLanguage: String?

    /// 繁体/方言映射提示是否可见 (US-SYN-001 AC-2) — 首次启动提示一次
    private(set) var mappingHintVisible: Bool = false

    /// 是否已请求打开系统设置 (US-SRC-001 AC-6)
    private(set) var openSettingsRequested = false

    /// 模拟模型加载延迟 — 测试可注入 0 使加载立即完成 (fixture 模式)
    private let loadDelayNanoseconds: UInt64

    /// 模型加载 Task
    private var loadTask: Task<Void, Never>?

    /// UI 切片模式 fixture 注入源
    private var stubFixture: OnboardingFixture?

    // MARK: - Initialization

    /// 初始化 OnboardingViewModel。
    ///
    /// - Parameter loadDelayNanoseconds: 模拟模型加载总耗时。
    ///   测试注入 0 使加载立即完成；默认 3s 模拟首次模型加载耗时
    ///   (10 次进度 tick, 每次 300ms)。
    init(loadDelayNanoseconds: UInt64 = 3_000_000_000) {
        self.loadDelayNanoseconds = loadDelayNanoseconds
    }

    // MARK: - Actions

    /// Step 1 → Step 2: 点击"开始"进入隐私同意 (echo-memory-canvas §15.2→§15.3)。
    func start() {
        guard viewState == .welcome else { return }
        viewState = .privacyConsent
    }

    /// Step 2: 同意隐私政策 → 进入权限序列 (US-PRV-008 AC-3)。
    ///
    /// 🔮 Phase 3.9: PrivacyActor.updatePolicy(authorizedSourceTypes:) 持久化同意。
    func acceptPrivacy() {
        guard viewState == .privacyConsent else { return }
        viewState = .permissions(0)
    }

    /// Step 2: 拒绝隐私政策 → declined 退出态 (US-PRV-008 AC-3)。
    func declinePrivacy() {
        guard viewState == .privacyConsent else { return }
        viewState = .declined
    }

    /// Step 3: 允许当前权限 → 前进到下一权限或语言步骤 (echo-memory-canvas §15.4)。
    ///
    /// 🔮 Phase 3.12: 真实系统权限弹窗 (PHPhotoLibrary / UNUserNotificationCenter / CoreLocation / HealthKit)。
    func allowPermission() {
        guard case .permissions(let index) = viewState else { return }
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
    /// 🔮 Phase 3.9: PrivacyActor.updatePolicy(preferredLanguage:) 持久化。
    func selectLanguage(_ language: String) {
        guard case .language = viewState else { return }
        let normalized = language == "zh-Hans" ? "zh-Hans" : "en-US"
        selectedLanguage = normalized
    }

    /// Step 4: 根据系统语言设置默认首选语言 (US-SYN-001 AC-1)。
    ///
    /// 仅支持 zh-Hans/en-US；繁体/方言映射为 zh-Hans (AGENTS.md §1.3)。
    /// 🔮 Phase 3.9: 从 PrivacyActor UserPolicyStore 读取持久化 preferredLanguage。
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
    /// 🔮 Phase 3.9: ModelLoaderActor 真实加载进度。当前 fixture 模式模拟 determinate 进度。
    func beginLoad() {
        guard case .language = viewState, selectedLanguage != nil else { return }
        viewState = .modelLoading(0.0)
        startModelLoad()
    }

    /// 重置到初始状态。
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        viewState = .welcome
        permissionSteps = []
        privacySummary = ""
        deniedMessage = ""
        selectedLanguage = nil
        mappingHintVisible = false
        openSettingsRequested = false
        stubFixture = nil
    }

    // MARK: - Model Loading (fixture simulated)

    /// 模拟首次模型加载进度 (echo-memory-canvas §15.6)。
    ///
    /// 🔮 Phase 3.9: 替换为 ModelLoaderActor 真实进度订阅。
    private func startModelLoad() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            var progress = 0.0
            while progress < 1.0 {
                try? await Task.sleep(nanoseconds: loadDelayNanoseconds / 10)
                guard !Task.isCancelled else { return }
                progress = min(progress + 0.1, 1.0)
                self.viewState = .modelLoading(progress)
            }
            self.viewState = .completed
        }
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
            viewState = .modelLoading(0.0)

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
