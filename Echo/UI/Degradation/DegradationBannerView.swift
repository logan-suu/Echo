// ==========================================
// 文件: DegradationBannerView.swift
// i18n: Strings resolved via Localizable.xcstrings (zh-Hans + en-US) — migrated by 3F.10 (DEF-41-1).
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RES-002 (低电量模式降级),
//            US-RES-003 (设备过热降级), US-RES-004 (模型加载失败),
//            docs/ui/echo-memory-canvas-style.md §11.4 (降级横幅 — Task surface family),
//            §7.2 (Task surfaces: errors & recovery), §2.3 (semantic colors), §2.4 (SF Symbols)
// 任务: 4.0c - Task 平衡画布：设置、引导与运行状态页面
// AC 覆盖: US-RES-002 AC-2 ✅ (低电量 Banner + battery.25),
//          US-RES-002 AC-3 ✅ (低电量时自动暂停后台任务 Toggle),
//          US-RES-002 AC-4 ✅ (退出低电量自动消失),
//          US-RES-003 AC-2 ✅ (过热 Banner + thermometer.high),
//          US-RES-003 AC-3 ✅ (热状态恢复自动消失),
//          US-RES-004 AC-7 ✅ (模型降级 Banner + exclamationmark.triangle + retry + settings)
// 架构约束: AGENTS.md §17.7 (Task surface 禁止 masonry),
//           echo-memory-canvas apple-native 基础; 系统 overlay + HStack 容器
// 生成时间: 2026-09-02
// ==========================================

import SwiftUI

struct DegradationBannerView: View {
    @State private var viewModel: DegradationBannerViewModel
    @State private var hasHandledLaunchArguments = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.echoDesignProfile) private var designProfile
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    init(viewModel: DegradationBannerViewModel = DegradationBannerViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isBannerVisible, let degradation = viewModel.activeDegradation {
                bannerContent(degradation)
                    .transition(.opacity)
            }
        }
        .animation(
            EchoAccessibilityPolicy.allowsMotion(reduceMotion: accessibilityReduceMotion)
                ? .easeInOut(duration: 0.3)
                : nil,
            value: viewModel.isBannerVisible
        )
        .background(EchoColorToken.groupedBackground.color.opacity(0.001))
        .environment(\.echoDesignProfile, designProfile)
        .zIndex(100)
        .onAppear {
            if !hasHandledLaunchArguments {
                handleLaunchArguments()
                hasHandledLaunchArguments = true
            }
        }
        .onChange(of: viewModel.pendingAccessibilityAnnouncement) { _, newValue in
            // US-DIS-004 AC-2: dynamic content change triggers a VoiceOver announcement
            guard let newValue, !newValue.isEmpty else { return }
            AccessibilityNotification.Announcement(EchoStrings.tr(newValue)).post()
            _ = viewModel.consumeAccessibilityAnnouncement()
        }
    }

    @ViewBuilder
    private func bannerContent(_ degradation: DegradationState) -> some View {
        EchoContainer(level: .emphasized) {
            HStack(spacing: EchoSpacingToken.normal.points) {
                Image(systemName: degradation.iconName)
                    .font(.callout)
                    .foregroundStyle(degradation.tint)
                    .accessibilityHidden(true)

                Text(EchoStrings.tr(degradation.message))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1.0 : 0.85)

                Spacer(minLength: 8)

                if degradation.showToggle {
                    Toggle(isOn: Binding(get: { degradation.backgroundTasksPaused },
                                         set: { _ in viewModel.toggleBackgroundTasks() })) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .scaleEffect(0.7)
                    .frame(width: 34, height: 24)
                    .accessibilityLabel("Pause background tasks during low power")
                }

                if degradation.showRetry {
                    Button(action: { viewModel.retryModelLoad() }) {
                        Text("Retry")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(EchoActionButtonStyle(role: .recovery))
                    .controlSize(.small)
                    .accessibilityLabel("Retry model load")
                }

                if degradation.showSettings {
                    Button(action: openSystemSettings) {
                        Text("Settings")
                            .font(.caption)
                    }
                    .buttonStyle(EchoActionButtonStyle(role: .secondary))
                    .controlSize(.small)
                    .tint(degradation.tint)
                    .accessibilityLabel("Open settings for model recovery")
                }

                Button(action: { viewModel.dismissBanner() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss banner")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Degradation banner: \(degradation.type.rawValue)")
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func handleLaunchArguments() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let fixtureIdx = args.firstIndex(of: "-degradationFixture"),
           fixtureIdx + 1 < args.count {
            viewModel.loadFixture(args[fixtureIdx + 1])
        }
        #endif
    }
}

#if DEBUG
#Preview("Normal (No Degradation)") {
    VStack {
        DegradationBannerView(viewModel: {
            let vm = DegradationBannerViewModel()
            vm.loadFixture("degradation-normal")
            return vm
        }())
        Spacer()
    }
}

#Preview("Low Power Degradation") {
    VStack {
        DegradationBannerView(viewModel: {
            let vm = DegradationBannerViewModel()
            vm.loadFixture("degradation-low-power")
            return vm
        }())
        Spacer()
    }
}

#Preview("Thermal Degradation") {
    VStack {
        DegradationBannerView(viewModel: {
            let vm = DegradationBannerViewModel()
            vm.loadFixture("degradation-thermal")
            return vm
        }())
        Spacer()
    }
}

#Preview("Model Degraded") {
    VStack {
        DegradationBannerView(viewModel: {
            let vm = DegradationBannerViewModel()
            vm.loadFixture("degradation-model-degraded")
            return vm
        }())
        Spacer()
    }
}

#Preview("Dynamic Type AX5") {
    VStack {
        DegradationBannerView(viewModel: {
            let vm = DegradationBannerViewModel()
            vm.loadFixture("degradation-low-power")
            return vm
        }())
        Spacer()
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}
#endif
