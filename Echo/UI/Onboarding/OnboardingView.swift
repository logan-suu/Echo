// ==========================================
// 文件: OnboardingView.swift
// i18n: User-facing literals are backed by Localizable.xcstrings (zh-Hans + en-US).
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-PRV-008 (PIPL 隐私同意 AC-1~3),
//            US-SRC-001 AC-6 (首次授权 iCloud 下载提示 + Open Settings),
//            US-SYN-001 AC-2 (语言选择 + 繁体映射提示)
//            docs/ui/echo-memory-canvas-style.md §15 (引导流程: fullScreenCover + 分步 TabView),
//            §3.3 (Task surfaces — Form/List/Sheet/Alert, 禁止 masonry),
//            §2.3 (semantic colors), §2.4 (SF Symbols), §2.5 (可访问性)
//            docs/ui/architecture.md §3 (Surface View), §8 (Task surface family)
// 任务: 4.0c - Task 平衡画布：设置、引导与运行状态页面
// AC 覆盖: US-PRV-008 AC-1 ✅ (隐私摘要展示), AC-2 ✅ (摘要含目的/方式/种类/保留期限/本地处理声明),
//          AC-3 ✅ (同意/拒绝同等醒目 + declined 终态页 Close 退出, PR #45 review P0-2 修复),
//          US-SRC-001 AC-6 ✅ (iCloud 提示 + Open Settings 按钮), US-SYN-001 AC-2 ✅ (zh-Hans/en-US Picker + 映射提示),
//          首次模型加载 ✅ (4 个真实模型逐项状态 + determinate 总进度)
// 架构约束: AGENTS.md §8.1 (ViewModel 驱动), §17.7 (Task surface 禁止 masonry),
//           echo-memory-canvas apple-native 基础; 系统容器 + SF Symbols + Dynamic Type
// 生成时间: 2026-09-02
// ==========================================

import SwiftUI

// MARK: - OnboardingView

/// 引导流程视图 — 首次启动五步引导 (欢迎→PIPL 同意→权限→语言→模型加载)。
///
/// ## Surface Family: Task
/// - 布局: fullScreenCover + 分步 TabView (echo-memory-canvas §15.1)
/// - Masonry: 绝对禁止 (Task surface, §3.3)
/// - 系统容器: TabView (page style) + ScrollView + Form (语言 Picker) + ProgressView
///
/// ## 状态驱动 (OnboardingViewModel.ViewState)
/// - welcome: 品牌欢迎页 (§15.2)
/// - privacyConsent: 可滚动 PIPL 摘要 + 同意/拒绝 (§15.3, US-PRV-008)
/// - permissions(index): 权限过渡页 + iCloud 提示 (照片) (§15.4, US-SRC-001 AC-6)
/// - permissionDenied(index): 拒绝提示 + Open Settings / Skip (US-SRC-001 AC-6)
/// - language: 系统 Picker zh-Hans/en-US (US-SYN-001 AC-2)
/// - modelLoading: 4 个已登记模型的逐项状态 + determinate 总进度 (§15.6)
/// - modelLoadFailed: 手动重试或降级继续（US-RES-004）
/// - completed / declined: 终态
///
/// ## 数据流 (docs/ui/architecture.md §2.1)
/// - User Action → OnboardingViewModel action → injected adapter → State Update → View Re-render
struct OnboardingView: View {
    // MARK: - ViewModel

    @State private var viewModel: OnboardingViewModel
    @Environment(\.echoDesignProfile) private var designProfile
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    /// 引导完成回调 — 宿主 (AppRootView) 关闭 fullScreenCover
    var onCompleted: (() -> Void)?

    /// 引导拒绝回调 — 宿主 (AppRootView) 关闭 fullScreenCover (US-PRV-008 AC-3 拒绝后退出)
    var onDeclined: (() -> Void)?

    init(viewModel: OnboardingViewModel = OnboardingViewModel(),
         onCompleted: (() -> Void)? = nil,
         onDeclined: (() -> Void)? = nil) {
        _viewModel = State(initialValue: viewModel)
        self.onCompleted = onCompleted
        self.onDeclined = onDeclined
    }

    // MARK: - Body

    var body: some View {
        TabView(selection: stepSelection) {
            welcomePage.tag("welcome")
            privacyConsentPage.tag("privacyConsent")
            permissionsPage.tag("permissions")
            languagePage.tag("language")
            modelLoadingPage.tag("modelLoading")
            declinedPage.tag("declined")
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: viewModel.viewState) { _, newState in
            if newState == .completed {
                onCompleted?()
            }
        }
        .animation(
            EchoAccessibilityPolicy.allowsMotion(reduceMotion: accessibilityReduceMotion)
                ? .easeInOut(duration: 0.25)
                : nil,
            value: viewModel.viewState
        )
        .background(EchoColorToken.groupedBackground.color)
        .environment(\.echoDesignProfile, designProfile)
        .accessibilityIdentifier("onboarding-view")
    }

    /// 当前 Tab 页 selection — 由 viewState 驱动 (permissions 有多个子步骤)。
    private var stepSelection: Binding<String> {
        Binding(
            get: {
                switch viewModel.viewState {
                case .welcome: return "welcome"
                case .privacyConsent, .consentPersisting, .consentPersistError: return "privacyConsent"
                case .permissions, .permissionDenied: return "permissions"
                case .language: return "language"
                case .modelLoading, .modelLoadFailed, .completed: return "modelLoading"
                case .declined: return "declined"
                }
            },
            set: { _ in }
        )
    }

    // MARK: - Step 1: Welcome (§15.2)

    /// Step 1 欢迎页 — Echo logo + 标题 + 标语 + 开始按钮。
    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text("Echo · 回响")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text("Your memories, within reach.")
                .font(.body)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button(action: { viewModel.start() }) {
                Text("Get Started")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("onboarding-start")
            .accessibilityHint("Begin the setup flow")

            Spacer().frame(height: 8)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Step 2: PIPL Privacy Consent (§15.3, US-PRV-008)

    /// Step 2 隐私同意页 — 可滚动摘要 + 同意/拒绝 (US-PRV-008 AC-1~3)。
    private var privacyConsentPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Privacy & Consent")
                .font(.title)
                .fontWeight(.semibold)
                .padding(.top, 24)

            Text("Before you begin, please review how Echo handles your data.")
                .font(.body)
                .foregroundStyle(Color.secondary)

            // PIPL 摘要 (US-PRV-008 AC-1/AC-2) — 可滚动
            ScrollView {
                EchoContainer(level: .card) {
                    Text(viewModel.privacySummary)
                        .font(EchoTypographyToken.body.font)
                        .lineSpacing(4)
                        .accessibilityIdentifier("onboarding-privacy-summary")
                }
            }
            .background(EchoColorToken.groupedBackground.color)
            .frame(maxHeight: 280)

            if viewModel.viewState == .consentPersisting {
                ProgressView("Saving your consent...")
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("onboarding-consent-persisting")
            } else if viewModel.viewState == .consentPersistError {
                EchoStatusPresentation(
                    role: .warning,
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Consent was not saved",
                    message: "Echo has not requested access to any protected data. Retry to continue."
                )
                Button("Retry") { viewModel.retryConsentPersistence() }
                    .buttonStyle(EchoActionButtonStyle(role: .recovery))
                    .accessibilityIdentifier("onboarding-consent-retry")
            } else {
                Button(action: { viewModel.acceptPrivacy() }) {
                    Text("Agree & Continue")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(consentActionStyle)
                .accessibilityIdentifier("onboarding-privacy-agree")
                .accessibilityHint("Agree to the privacy policy and continue")

                Button(action: { viewModel.declinePrivacy() }) {
                    Text("Decline")
                        .font(.callout)
                        .fontWeight(.regular)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(consentActionStyle)
                .accessibilityIdentifier("onboarding-privacy-decline")
                .accessibilityHint("Decline the privacy policy; Echo cannot process your memories")
            }

            Spacer().frame(height: 8)
        }
        .padding(.horizontal, 24)
    }

    /// Identical treatment keeps consent and refusal at the same visual hierarchy.
    private var consentActionStyle: EchoActionButtonStyle {
        EchoActionButtonStyle(role: .secondary)
    }

    // MARK: - Step 3: Permissions (§15.4, US-SRC-001 AC-6)

    /// Step 3 permission page — optional Photos access only.
    @ViewBuilder
    private var permissionsPage: some View {
        switch viewModel.viewState {
        case .permissions(let index):
            permissionStepView(index: index)

        case .permissionDenied(let index):
            permissionDeniedView(index: index)

        default:
            EmptyView()
        }
    }

    /// 单个权限过渡页 — 图标 + 用途 + 授权/拒绝按钮。
    private func permissionStepView(index: Int) -> some View {
        guard viewModel.permissionSteps.indices.contains(index) else {
            return AnyView(EmptyView())
        }
        let permission = viewModel.permissionSteps[index]

        return AnyView(
            VStack(alignment: .leading, spacing: 16) {
                Text("Allow Access")
                    .font(.title)
                    .fontWeight(.semibold)
                    .padding(.top, 24)

                HStack(spacing: 16) {
                    Image(systemName: permission.systemImage)
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(EchoStrings.tr(permission.title))
                            .font(.headline)
                        Text(EchoStrings.tr(permission.purpose))
                            .font(.callout)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .padding(16)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))

                // iCloud 下载提示 (US-SRC-001 AC-6) — 仅照片步骤
                if let hint = permission.icloudHint {
                    iCloudHintView(hint: hint, openSettingsLabel: permission.openSettingsLabel)
                }

                Spacer()

                Button(action: { viewModel.allowPermission() }) {
                    Text("Allow")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.permissionRequestInFlight)
                .accessibilityIdentifier("onboarding-permission-allow")
                .accessibilityHint(String(format: EchoStrings.tr("Allow %@ access"), EchoStrings.tr(permission.title)))

                Button(action: { viewModel.skipOptionalPhotos() }) {
                    Text("Not Now")
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("onboarding-permission-deny")
                .accessibilityHint(String(format: EchoStrings.tr("Decline %@ access for now"), EchoStrings.tr(permission.title)))

                Spacer().frame(height: 8)
            }
            .padding(.horizontal, 24)
        )
    }

    /// iCloud 下载提示 (US-SRC-001 AC-6) — 照片授权时展示。
    private func iCloudHintView(hint: String, openSettingsLabel: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("iCloud Photos")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: "icloud")
                    .foregroundStyle(Color.accentColor)
            }

            Text(EchoStrings.tr(hint))
                .font(.callout)
                .foregroundStyle(Color.secondary)

            if let label = openSettingsLabel {
                Button(action: {
                    viewModel.openSettings()
                    openSystemSettings()
                }) {
                    Text(EchoStrings.tr(label))
                        .font(.callout)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("onboarding-open-settings")
                .accessibilityHint("Open Settings to manage iCloud Photos storage")
            }
        }
        .padding(14)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-icloud-hint")
    }

    /// 权限拒绝页 (US-SRC-001 AC-6) — 前往设置 / 继续使用。
    private func permissionDeniedView(index: Int) -> some View {
        guard viewModel.permissionSteps.indices.contains(index) else {
            return AnyView(EmptyView())
        }
        let permission = viewModel.permissionSteps[index]

        return AnyView(
            VStack(alignment: .leading, spacing: 16) {
                Text("Access Needed")
                    .font(.title)
                    .fontWeight(.semibold)
                    .padding(.top, 24)

                HStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.yellow)
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(EchoStrings.tr(permission.title))
                            .font(.headline)
                        Text(viewModel.deniedMessage)
                            .font(.callout)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .padding(16)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))

                Spacer()

                Button(action: {
                    viewModel.openSettings()
                    openSystemSettings()
                }) {
                    Text("Open Settings")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("onboarding-open-settings")
                .accessibilityHint("Open the system Settings app")

                Button(action: { viewModel.skipPermission() }) {
                    Text("Continue Anyway")
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("onboarding-permission-skip")
                .accessibilityHint("Continue without this permission")

                Spacer().frame(height: 8)
            }
            .padding(.horizontal, 24)
        )
    }

    // MARK: - Step 4: Language Selection (§15.5, US-SYN-001 AC-2)

    /// Step 4 语言选择页 — 系统 Picker zh-Hans/en-US (US-SYN-001 AC-2)。
    private var languagePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Language")
                .font(.title)
                .fontWeight(.semibold)
                .padding(.top, 24)

            Text("Select the language Echo uses to display and respond.")
                .font(.body)
                .foregroundStyle(Color.secondary)

            // 系统 Picker (US-SYN-001 AC-2)
            Picker("Language", selection: languageSelection) {
                Text("Simplified Chinese").tag("zh-Hans")
                Text("English").tag("en-US")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("onboarding-language-picker")

            // 繁体/方言映射提示 (US-SYN-001 AC-2) — 首次提示一次
            if viewModel.mappingHintVisible {
                Label {
                    Text(OnboardingContentDefaults.mappingHint)
                        .font(.callout)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.accentColor)
                }
                .padding(14)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("onboarding-language-mapping-hint")
            }

            Spacer()

            Button(action: { viewModel.beginLoad() }) {
                Text("Continue")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedLanguage == nil)
            .accessibilityIdentifier("onboarding-begin-load")
            .accessibilityHint("Begin loading models with the selected language")

            Spacer().frame(height: 8)
        }
        .padding(.horizontal, 24)
        .onAppear { viewModel.applyDefaultLanguage() }
    }

    /// 语言选择 Binding — 选择后记录到 ViewModel。
    private var languageSelection: Binding<String> {
        Binding(
            get: { viewModel.selectedLanguage ?? "en-US" },
            set: { newValue in
                viewModel.selectLanguage(newValue)
            }
        )
    }

    // MARK: - Step 5: Model Loading (§15.6)

    /// Step 5 首次模型加载页 — 逐模型状态 + determinate 总进度。
    @ViewBuilder
    private var modelLoadingPage: some View {
        if viewModel.viewState == .modelLoading || viewModel.viewState == .modelLoadFailed {
            let progress = viewModel.modelLoadProgress
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "cpu")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                Text("Loading models…")
                    .font(.headline)

                VStack(spacing: 10) {
                    ForEach(progress.items) { item in
                        modelStatusRow(item)
                    }
                }
                .padding(.horizontal, 24)

                // Determinate overall progress derived from completed real load attempts.
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                    .padding(.horizontal, 40)
                    .accessibilityIdentifier("onboarding-model-progress")
                    .accessibilityValue(OnboardingViewModel.progressPercentText(progress.fractionCompleted))

                Text(OnboardingViewModel.progressPercentText(progress.fractionCompleted))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)

                if viewModel.viewState == .modelLoadFailed {
                    Text("Some models failed to load. Basic keyword search is still available.")
                        .font(.callout)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Button("Retry model load") {
                        viewModel.retryModelLoad()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding-model-retry")

                    Button("Continue Anyway") {
                        viewModel.continueWithLimitedFeatures()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding-model-continue-limited")
                }

                Spacer()
            }
        } else {
            EmptyView()
        }
    }

    private func modelStatusRow(_ item: OnboardingModelLoadProgress.Item) -> some View {
        HStack(spacing: 12) {
            modelStatusIcon(item.state)
                .frame(width: 22)
                .accessibilityHidden(true)

            Text(verbatim: item.displayName)
                .font(.body)

            Spacer()

            modelStatusText(item.state)
                .font(.caption)
                .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding-model-\(item.modelType.rawValue)")
    }

    @ViewBuilder
    private func modelStatusIcon(_ state: OnboardingModelLoadProgress.Item.State) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(Color.secondary)

        case .loading:
            ProgressView()
                .controlSize(.small)

        case .loaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)

        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
        }
    }

    @ViewBuilder
    private func modelStatusText(_ state: OnboardingModelLoadProgress.Item.State) -> some View {
        switch state {
        case .pending:
            Text("Waiting")

        case .loading:
            Text("Loading")

        case .loaded:
            Text("Ready")

        case .failed:
            Text("Failed")
        }
    }

    // MARK: - Step 6: Declined (US-PRV-008 AC-3)

    /// PIPL 拒绝终态页 — 说明 Echo 无法处理记忆 + Close 退出按钮。
    ///
    /// 修复 P0-2: 此前 declined 态被 stepSelection 映射回 privacyConsent 页但按钮已 guard 失效，
    /// 用户被卡死。现提供独立终态页 + onDeclined 回调关闭 fullScreenCover。
    private var declinedPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "hand.raised")
                .font(.system(size: 48))
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)

            Text("Privacy Consent Declined")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Echo cannot process your memories without your consent. Your data stays on this device.")
                .font(.body)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button(action: { onDeclined?() }) {
                Text("Close")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("onboarding-declined-close")
            .accessibilityHint("Close onboarding after declining privacy consent")

            Spacer().frame(height: 8)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - System Settings Helper

/// 打开系统设置 (US-SRC-001 AC-6)。与 DegradationBannerView 同模式。
/// 必须 @MainActor — UIApplication.shared 为 MainActor 隔离，文件级函数默认 nonisolated，
/// 在 CI (Xcode 16.4 toolchain, -strict-concurrency=complete) 下会编译失败 (P0-1)。
@MainActor
private func openSystemSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}

// MARK: - Preview

#Preview("Welcome") {
    let vm = OnboardingViewModel()
    vm.loadFixture("onboarding-welcome")
    return OnboardingView(viewModel: vm)
}

#Preview("Privacy Consent") {
    let vm = OnboardingViewModel()
    vm.loadFixture("onboarding-privacy-consent")
    return OnboardingView(viewModel: vm)
}

#Preview("Permissions") {
    let vm = OnboardingViewModel()
    vm.loadFixture("onboarding-permissions")
    return OnboardingView(viewModel: vm)
}

#Preview("Permission Denied") {
    let vm = OnboardingViewModel()
    vm.loadFixture("onboarding-permission-denied")
    return OnboardingView(viewModel: vm)
}

#Preview("Language") {
    let vm = OnboardingViewModel()
    vm.loadFixture("onboarding-language")
    return OnboardingView(viewModel: vm)
}

#Preview("Model Loading") {
    let vm = OnboardingViewModel()
    vm.loadFixture("onboarding-model-loading")
    return OnboardingView(viewModel: vm)
}
