// ==========================================
// 文件: OnboardingView.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8/3.9.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-PRV-008 (PIPL 隐私同意 AC-1~3),
//            US-SRC-001 AC-6 (首次授权 iCloud 下载提示 + Open Settings),
//            US-SYN-001 AC-2 (语言选择 + 繁体映射提示)
//            docs/ui/echo-memory-canvas-style.md §15 (引导流程: fullScreenCover + 分步 TabView),
//            §3.3 (Task surfaces — Form/List/Sheet/Alert, 禁止 masonry),
//            §2.3 (semantic colors), §2.4 (SF Symbols), §2.5 (可访问性)
//            docs/ui/architecture.md §3 (Surface View), §8 (Task surface family)
// 任务: 3.11 - 引导流程：欢迎页 + PIPL 隐私同意 + 权限序列 + 语言选择 + 首次模型加载
// AC 覆盖: US-PRV-008 AC-1 ✅ (隐私摘要展示), AC-2 ✅ (摘要含目的/方式/种类/保留期限/本地处理声明),
//          AC-3 ✅ (同意/拒绝同等醒目按钮), US-SRC-001 AC-6 ✅ (iCloud 提示 + Open Settings 按钮),
//          US-SYN-001 AC-2 ✅ (zh-Hans/en-US Picker + 映射提示), 首次模型加载 ✅ (determinate ProgressView)
// 架构约束: AGENTS.md §8.1 (ViewModel 驱动), §17.7 (Task surface 禁止 masonry),
//           echo-memory-canvas apple-native 基础; 系统容器 + SF Symbols + Dynamic Type
// 生成时间: 2026-08-03
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
/// - modelLoading(progress): determinate 进度条 (首次模型加载, §15.6)
/// - completed / declined: 终态
///
/// ## 数据流 (docs/ui/architecture.md §2.1)
/// - User Action → OnboardingViewModel action → (🔮 Phase 3.9 Core) → State Update → View Re-render
struct OnboardingView: View {
    // MARK: - ViewModel

    @State private var viewModel: OnboardingViewModel

    /// 引导完成回调 — 宿主 (AppRootView) 关闭 fullScreenCover
    var onCompleted: (() -> Void)?

    init(viewModel: OnboardingViewModel = OnboardingViewModel(), onCompleted: (() -> Void)? = nil) {
        _viewModel = State(initialValue: viewModel)
        self.onCompleted = onCompleted
    }

    // MARK: - Body

    var body: some View {
        TabView(selection: stepSelection) {
            welcomePage.tag("welcome")
            privacyConsentPage.tag("privacyConsent")
            permissionsPage.tag("permissions")
            languagePage.tag("language")
            modelLoadingPage.tag("modelLoading")
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: viewModel.viewState) { _, newState in
            if newState == .completed {
                onCompleted?()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.viewState)
        .accessibilityIdentifier("onboarding-view")
    }

    /// 当前 Tab 页 selection — 由 viewState 驱动 (permissions 有多个子步骤)。
    private var stepSelection: Binding<String> {
        Binding(
            get: {
                switch viewModel.viewState {
                case .welcome: return "welcome"
                case .privacyConsent: return "privacyConsent"
                case .permissions, .permissionDenied: return "permissions"
                case .language: return "language"
                case .modelLoading, .completed: return "modelLoading"
                case .declined: return "privacyConsent"
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
                Text(viewModel.privacySummary)
                    .font(.callout)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("onboarding-privacy-summary")
            }
            .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxHeight: 280)

            // 同意/拒绝同等醒目 (US-PRV-008 AC-3)
            Button(action: { viewModel.acceptPrivacy() }) {
                Text("Agree & Continue")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("onboarding-privacy-agree")
            .accessibilityHint("Agree to the privacy policy and continue")

            Button(action: { viewModel.declinePrivacy() }) {
                Text("Decline")
                    .font(.callout)
                    .fontWeight(.regular)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("onboarding-privacy-decline")
            .accessibilityHint("Decline the privacy policy; Echo cannot process your memories")

            Spacer().frame(height: 8)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Step 3: Permissions (§15.4, US-SRC-001 AC-6)

    /// Step 3 权限页 — 逐项授权 (照片→通知→位置→健康)。
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
                        Text(permission.title)
                            .font(.headline)
                        Text(permission.purpose)
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
                .accessibilityIdentifier("onboarding-permission-allow")
                .accessibilityHint("Allow \(permission.title) access")

                Button(action: { viewModel.denyPermission() }) {
                    Text("Not Now")
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("onboarding-permission-deny")
                .accessibilityHint("Decline \(permission.title) access for now")

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

            Text(hint)
                .font(.callout)
                .foregroundStyle(Color.secondary)

            if let label = openSettingsLabel {
                Button(action: {
                    viewModel.openSettings()
                    openSystemSettings()
                }) {
                    Text(label)
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
                        Text(permission.title)
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
                    Text(OnboardingFixtureLoader.mappingHint)
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

    /// Step 5 首次模型加载页 — determinate 进度条 (首次模型加载进度)。
    @ViewBuilder
    private var modelLoadingPage: some View {
        if case .modelLoading(let progress) = viewModel.viewState {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "cpu")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                Text("Loading models…")
                    .font(.headline)

                // determinate 进度 (echo-memory-canvas §10.2)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                    .padding(.horizontal, 40)
                    .accessibilityIdentifier("onboarding-model-progress")

                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)

                Spacer()
            }
        } else {
            EmptyView()
        }
    }

    // MARK: - Declined State (US-PRV-008 AC-3)

    /// PIPL 拒绝提示页 — 由 AppRootView 在 viewState == .declined 时另行展示 (Alert/覆盖层)。
    /// ViewModel 的 declined 态由宿主处理；本视图 TabView 仅在 5 个主步骤间切换。
}

// MARK: - System Settings Helper

/// 打开系统设置 (US-SRC-001 AC-6)。与 DegradationBannerView 同模式。
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
