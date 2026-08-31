// ==========================================
// 文件: OnboardingTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-PRV-008 (PIPL 隐私同意),
//            US-SRC-001 AC-6 (首次授权 iCloud 下载提示), US-SYN-001 AC-2 (语言选择)
//            docs/ui/echo-memory-canvas-style.md §15 (引导流程),
//            docs/ui/architecture.md §6 (ViewModel 契约), §7 (适配器契约)
// 任务: 3.11 - 引导流程：欢迎页 + PIPL 隐私同意 + 权限序列 + 语言选择 + 首次模型加载
// AC 覆盖: US-PRV-008 AC-1 ✅ (隐私摘要), AC-2 ✅ (摘要含目的/方式/种类/保留期限/本地处理声明),
//          AC-3 ✅ (同意/拒绝同等醒目 — 状态流转), US-SRC-001 AC-6 ✅ (iCloud 提示数据 + Open Settings 意图),
//          US-SYN-001 AC-2 ✅ (zh-Hans/en-US 选择 + 映射提示), 首次模型加载 ✅ (4 模型真实逐项进度 → completed)
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable + state enum), §8.2 (状态流转),
//           docs/ui/architecture.md §6~7 (适配器契约 — 不保存第二份领域真相)
// 生成时间: 2026-08-03
// ==========================================

import Testing
import Foundation
@testable import Echo

private actor OnboardingModelLoaderStub: OnboardingModelLoading {
    private let failedModel: ModelLoaderActor.ModelType?
    private var calls: [ModelLoaderActor.ModelType] = []

    init(failedModel: ModelLoaderActor.ModelType? = nil) {
        self.failedModel = failedModel
    }

    func loadModel(_ modelType: ModelLoaderActor.ModelType) async -> ModelLoaderActor.ModelLoadState {
        calls.append(modelType)
        if modelType == failedModel {
            return .failed(.modelNotFound(
                modelName: modelType.modelName,
                resourceName: modelType.resourceIdentifier
            ))
        }
        return .loaded
    }

    func loadedModels() -> [ModelLoaderActor.ModelType] {
        calls
    }
}

@MainActor
private final class OnboardingPermissionRequesterStub: OnboardingPermissionRequesting {
    private(set) var requestedIDs: [String] = []
    var granted = true

    func request(_ permission: OnboardingPermission) async -> Bool {
        requestedIDs.append(permission.id)
        return granted
    }
}

@MainActor
struct OnboardingTests {

    // MARK: - Fixture Helpers

    /// 等待模型加载 Task 收敛到非 modelLoading 状态。
    /// 注入 loadDelayNanoseconds=0 后真实异步转换可被 await。
    private func awaitSettled(
        _ vm: OnboardingViewModel,
        timeout: Duration = .seconds(2)
    ) async -> OnboardingViewModel.ViewState {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if case .modelLoading = vm.viewState {
                try? await Task.sleep(for: .milliseconds(5))
                continue
            }
            return vm.viewState
        }
        return vm.viewState
    }

    // MARK: - US-PRV-008 AC-1/AC-2: Privacy summary content

    @Test("Welcome fixture shows welcome state and steps are available")
    func test_AC1_welcomeState() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-welcome")
        #expect(vm.viewState == .welcome)
    }

    @Test("Privacy summary includes purpose, method, kind, retention, local processing (US-PRV-008 AC-2)")
    func test_AC2_privacySummaryContent() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-privacy-consent")
        #expect(vm.viewState == .privacyConsent)
        #expect(vm.privacySummary.contains("Purpose"))
        #expect(vm.privacySummary.contains("Methods"))
        #expect(vm.privacySummary.contains("Data types"))
        #expect(vm.privacySummary.contains("Retention"))
        #expect(vm.privacySummary.contains("Local processing"))
    }

    // MARK: - US-PRV-008 AC-3: Agree/Decline equal prominence (state transitions)

    @Test("Start transitions welcome to privacyConsent")
    func test_AC3_startTransitions() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-welcome")
        vm.start()
        #expect(vm.viewState == .privacyConsent)
    }

    @Test("Accept privacy transitions to permissions step 0")
    func test_AC3_acceptPrivacy() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-privacy-consent")
        vm.acceptPrivacy()
        #expect(vm.viewState == .permissions(0))
    }

    @Test("Decline privacy transitions to declined exit state")
    func test_AC3_declinePrivacy() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-privacy-consent")
        vm.declinePrivacy()
        #expect(vm.viewState == .declined)
    }

    // MARK: - Permission sequence (echo-memory-canvas §15.4)

    @Test("Production onboarding owns the four real permission steps without loading a fixture")
    func test_productionPermissionStepsAreAvailable() {
        let vm = OnboardingViewModel()
        #expect(vm.permissionSteps.map(\.id) == ["photos", "notifications", "location", "health"])
        #expect(vm.privacySummary.contains("Local processing"))
    }

    @Test("Allow invokes the real permission boundary before advancing")
    func test_allowInvokesPermissionBoundary() async {
        let requester = OnboardingPermissionRequesterStub()
        let vm = OnboardingViewModel(permissionRequester: requester)
        vm.start()
        vm.acceptPrivacy()

        vm.allowPermission()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(requester.requestedIDs == ["photos"])
        #expect(vm.viewState == .permissions(1))
    }

    @Test("Denied system permission enters the denied state instead of pretending success")
    func test_deniedSystemPermissionIsVisible() async {
        let requester = OnboardingPermissionRequesterStub()
        requester.granted = false
        let vm = OnboardingViewModel(permissionRequester: requester)
        vm.start()
        vm.acceptPrivacy()

        vm.allowPermission()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(requester.requestedIDs == ["photos"])
        #expect(vm.viewState == .permissionDenied(0))
    }

    @Test("Permission steps advance photos→notifications→location→health→language")
    func test_permissionSequenceAdvances() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-permissions")
        #expect(vm.viewState == .permissions(0))
        #expect(vm.permissionSteps.count == 4)

        vm.allowPermission()
        #expect(vm.viewState == .permissions(1))
        vm.allowPermission()
        #expect(vm.viewState == .permissions(2))
        vm.allowPermission()
        #expect(vm.viewState == .permissions(3))
        vm.allowPermission()
        #expect(vm.viewState == .language)
    }

    @Test("Photos permission includes iCloud download hint (US-SRC-001 AC-6)")
    func test_AC6_photosIcloudHint() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-permissions")
        let photos = vm.permissionSteps[0]
        #expect(photos.id == "photos")
        #expect(photos.icloudHint != nil)
        #expect(photos.icloudHint!.contains("Download and Keep Originals"))
        #expect(photos.openSettingsLabel == "Open Settings")
    }

    @Test("Deny permission transitions to permissionDenied state")
    func test_permissionDeniedState() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-permissions")
        vm.denyPermission()
        #expect(vm.viewState == .permissionDenied(0))
    }

    @Test("Open Settings records intent (US-SRC-001 AC-6)")
    func test_AC6_openSettingsIntent() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-permission-denied")
        #expect(vm.openSettingsRequested == false)
        vm.openSettings()
        #expect(vm.openSettingsRequested == true)
    }

    @Test("Skip denied permission advances to next step")
    func test_skipDeniedPermission() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-permission-denied")
        vm.skipPermission()
        #expect(vm.viewState == .permissions(1))
    }

    // MARK: - US-SYN-001 AC-2: Language selection

    @Test("Language fixture shows language state")
    func test_AC2_languageState() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-language")
        #expect(vm.viewState == .language)
    }

    @Test("Select zh-Hans records zh-Hans (US-SYN-001 AC-2)")
    func test_AC2_selectZhHans() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-language")
        vm.selectLanguage("zh-Hans")
        #expect(vm.selectedLanguage == "zh-Hans")
    }

    @Test("Select en-US records en-US (US-SYN-001 AC-2)")
    func test_AC2_selectEnglish() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-language")
        vm.selectLanguage("en-US")
        #expect(vm.selectedLanguage == "en-US")
    }

    @Test("Non-supported language maps to en-US (fallback normalization)")
    func test_AC2_languageNormalization() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-language")
        vm.selectLanguage("fr-FR")
        #expect(vm.selectedLanguage == "en-US")
    }

    @Test("Mapping hint becomes visible for traditional Chinese mapping (US-SYN-001 AC-2)")
    func test_AC2_mappingHint() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-language")
        vm.simulateMappingHint()
        #expect(vm.selectedLanguage == "zh-Hans")
        #expect(vm.mappingHintVisible == true)
    }

    @Test("Begin load applies default language from Locale then starts loading (US-SYN-001 AC-1)")
    func test_AC2_beginLoadAppliesDefaultLanguage() async {
        let vm = OnboardingViewModel(loadDelayNanoseconds: 0)
        vm.loadFixture("onboarding-language")
        // AC-1: preferredLanguage auto-syncs from Locale — no manual selection required
        #expect(vm.selectedLanguage != nil, "Default language should be applied from Locale")
        vm.beginLoad()
        guard case .modelLoading = vm.viewState else {
            Issue.record("Expected modelLoading")
            return
        }

        let settled = await awaitSettled(vm)
        #expect(settled == .completed)
    }

    // MARK: - First model load (§15.6)

    @Test("Begin load after language selection starts model loading and completes")
    func test_modelLoadCompletes() async {
        let vm = OnboardingViewModel(loadDelayNanoseconds: 0)
        vm.loadFixture("onboarding-language")
        vm.selectLanguage("en-US")
        vm.beginLoad()
        guard case .modelLoading = vm.viewState else {
            Issue.record("Expected modelLoading")
            return
        }

        let settled = await awaitSettled(vm)
        #expect(settled == .completed)
    }

    @Test("Production loading reports real progress for every bundled model")
    func test_modelLoadTracksEveryBundledModel() async {
        let loader = OnboardingModelLoaderStub()
        let vm = OnboardingViewModel(loadDelayNanoseconds: 0, modelLoader: loader)
        vm.loadFixture("onboarding-language")
        vm.selectLanguage("en-US")

        vm.beginLoad()
        let settled = await awaitSettled(vm)

        #expect(settled == .completed)
        #expect(await loader.loadedModels() == ModelLoaderActor.ModelType.allCases)
        #expect(vm.modelLoadProgress.items.count == 4)
        #expect(vm.modelLoadProgress.completedCount == 4)
        #expect(vm.modelLoadProgress.failedCount == 0)
        #expect(vm.modelLoadProgress.fractionCompleted == 1.0)
        #expect(vm.modelLoadProgress.items.allSatisfy { $0.state == .loaded })
    }

    @Test("Production loading preserves an individual model failure in progress")
    func test_modelLoadTracksIndividualFailure() async {
        let loader = OnboardingModelLoaderStub(failedModel: .siglip2Text)
        let vm = OnboardingViewModel(loadDelayNanoseconds: 0, modelLoader: loader)
        vm.loadFixture("onboarding-language")
        vm.selectLanguage("en-US")

        vm.beginLoad()
        let settled = await awaitSettled(vm)

        #expect(settled == .modelLoadFailed)
        #expect(vm.modelLoadProgress.completedCount == 4)
        #expect(vm.modelLoadProgress.failedCount == 1)
        #expect(vm.modelLoadProgress.items.first { $0.modelType == .siglip2Text }?.state == .failed)

        vm.continueWithLimitedFeatures()
        #expect(vm.viewState == .completed)
    }

    @Test("Declined fixture shows declined state (US-PRV-008 AC-3)")
    func test_declinedState() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-declined")
        #expect(vm.viewState == .declined)
    }

    @Test("Reset returns to welcome state")
    func test_reset() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-permissions")
        vm.reset()
        #expect(vm.viewState == .welcome)
        #expect(vm.permissionSteps.count == 4)
        #expect(vm.selectedLanguage == nil)
    }

    // MARK: - 3F.1: Consent persistence (US-PRV-008 AC-4, ADR-007 §决策-2)

    @Test("acceptPrivacy with consentStore persists consent (US-PRV-008 AC-4)")
    func test_3f1_acceptPrivacy_persistsConsent() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        try await db.execute(sql: "DELETE FROM ConsentStore")
        let store = ConsentStoreActor(db: db, privacyActor: PrivacyActor.shared)
        let vm = OnboardingViewModel(loadDelayNanoseconds: 0, consentStore: store)
        vm.loadFixture("onboarding-privacy-consent")
        vm.acceptPrivacy()

        #expect(vm.viewState == .permissions(0))
        // 等待异步持久化收敛
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            // 用全新实例验证 SQLite 已落盘（relaunch 语义，避免同实例内存态掩蔽）
            let fresh = ConsentStoreActor(db: db, privacyActor: PrivacyActor.shared)
            try await fresh.loadState()
            if await fresh.hasConsented() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let fresh = ConsentStoreActor(db: db, privacyActor: PrivacyActor.shared)
        try await fresh.loadState()
        #expect(await fresh.hasConsented() == true)
        #expect(vm.consentPersisted == true)
    }

    @Test("declinePrivacy does not persist consent (deny-by-default)")
    func test_3f1_declinePrivacy_noConsent() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        try await db.execute(sql: "DELETE FROM ConsentStore")
        let store = ConsentStoreActor(db: db, privacyActor: PrivacyActor.shared)
        let vm = OnboardingViewModel(loadDelayNanoseconds: 0, consentStore: store)
        vm.loadFixture("onboarding-privacy-consent")
        vm.declinePrivacy()

        #expect(vm.viewState == .declined)
        #expect(await store.hasConsented() == false)
    }

    @Test("acceptPrivacy uses production permission steps without fixture injection")
    func test_3f1_acceptPrivacy_usesProductionPermissionSteps() {
        let vm = OnboardingViewModel()
        vm.start()
        #expect(vm.viewState == .privacyConsent)
        #expect(vm.permissionSteps.count == 4)

        vm.acceptPrivacy()

        #expect(vm.viewState == .permissions(0))
        #expect(vm.selectedLanguage == nil)
    }

    @Test("acceptPrivacy with non-empty permissionSteps still advances to permissions (fixture path)")
    func test_3f1_acceptPrivacy_nonEmptyPermissionSteps_advancesToPermissions() {
        let vm = OnboardingViewModel()
        vm.loadFixture("onboarding-privacy-consent")
        #expect(vm.permissionSteps.count == 4)

        vm.acceptPrivacy()

        #expect(vm.viewState == .permissions(0))
    }
}
