// ==========================================
// 文件: AwakeningSettingsView.swift
// i18n: All user-facing strings are hardcoded English. Full String Catalog migration (zh-Hans + en-US) deferred to Phase 3.8.
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-001 (地理围栏唤醒),
//            US-AWK-002 (日期/纪念日唤醒), US-AWK-003 (情绪感知唤醒)
//            docs/ui/echo-memory-canvas-style.md §3.3 (Task surfaces), §7.2 (Task surfaces),
//            §10.1.3 (空态), §11 (Toast/Banner)
//            docs/ui/architecture.md §2 (单向数据流), §3 (组件边界)
// 任务: 3.12 - 唤醒投递：本地通知 + 位置/健康权限 + 地理围栏设置
// AC 覆盖: US-AWK-001 AC-5 ✅ (位置权限静默禁用/重新开启), AC-6 ✅ (审计记录查看),
//            US-AWK-002 AC-1 ✅ (每日推送开关控制), AC-4 🔮 Phase 3.9 (无匹配不推送 — Core pipeline),
//            US-AWK-003 AC-1 ✅ (HealthKit 权限管理)
// Legend: ✅ implemented (UI slice) | 🔶 stub (Core integration deferred to Phase 3.9)
// 架构约束: AGENTS.md §8.1 (@MainActor + @Observable), echo-memory-canvas apple-native 基础,
//           Task surface family (Form/List/Toggle/Picker, 禁止 masonry), §2.3~2.5 (semantic colors, SF Symbols, 可访问性),
//           §10.1 (Views 目录)
// 生成时间: 2026-08-03
// ==========================================

import SwiftUI

// MARK: - AwakeningSettingsView

struct AwakeningSettingsView: View {
    @State private var viewModel = AwakeningSettingsViewModel()

    var body: some View {
        content
            .navigationTitle("Awakening")
            .sheet(item: $viewModel.showGeofenceDetail) { geofence in
                geofenceDetailSheet(geofence)
            }
            .task { await viewModel.loadSettings() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            loadingView
        case .completed(let data):
            settingsForm(data)
        case .error(let level):
            errorView(level)
        case .cancelled:
            cancelledView
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Color.accentColor)
            Text("Loading awakening settings...")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Error

    private func errorView(_ level: AwakeningSettingsViewModel.ErrorLevel) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("Failed to load settings")
                .font(.headline)
            Text(levelDescription(level))
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.loadSettings() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .padding(40)
    }

    private func levelDescription(_ level: AwakeningSettingsViewModel.ErrorLevel) -> String {
        switch level {
        case .l1Transient:
            return "A temporary issue occurred. Please wait and try again."
        case .l2Recoverable(let msg):
            return msg
        case .l3Blocking(let msg):
            return msg
        case .l4Conflict(let msg):
            return msg
        }
    }

    // MARK: - Cancelled

    private var cancelledView: some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(Color.secondary)
            Text("Cancelled")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Settings Form

    private func settingsForm(_ data: AwakeningSettingsData) -> some View {
        Form {
            notificationSection(data)
            permissionsSection(data)
            awakeningTogglesSection(data)
            geofenceManagementSection(data)
            statusSection(data)
        }
    }

    // MARK: - Notification Section

    private func notificationSection(_ data: AwakeningSettingsData) -> some View {
        Section {
            HStack {
                Label(data.notificationPermission.displayName,
                      systemImage: data.notificationPermission.systemImage)
                    .foregroundStyle(data.notificationPermission.isGranted ? Color.primary : Color.secondary)
                Spacer()
                if data.notificationPermission.isGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Notifications enabled")
                } else if data.notificationPermission.isDeniedPermanently {
                    Button("Open Settings") {
                        viewModel.openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.accentColor)
                } else {
                    requestNotificationButton
                }
            }
            Text(data.notificationPermission.description)
                .font(.caption)
                .foregroundStyle(Color.secondary)
        } header: {
            Text("Notifications")
        }
    }

    private var requestNotificationButton: some View {
        Group {
            switch viewModel.notificationAuthStep {
            case .idle:
                Button("Enable") {
                    Task { await viewModel.requestNotificationPermission() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.accentColor)
            case .requesting:
                ProgressView()
                    .controlSize(.small)
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            case .denied:
                Button("Open Settings") {
                    viewModel.openSystemSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.accentColor)
            }
        }
    }

    // MARK: - Permissions Section

    private func permissionsSection(_ data: AwakeningSettingsData) -> some View {
        Section {
            permissionRow(data.locationPermission)
            permissionRow(data.healthPermission)
        } header: {
            Text("Required Permissions")
        } footer: {
            Text("Location is required for geofence awakening. Health data enables emotion-based awakening. Permissions can also be managed in Settings.")
        }
    }

    private func permissionRow(_ perm: AwakeningPermissionInfo) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(perm.displayName)
                    Text(perm.description)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: perm.systemImage)
                    .foregroundStyle(perm.isGranted ? Color.accentColor : Color.secondary)
            }
            Spacer()
            if perm.isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            } else if perm.isDeniedPermanently {
                Button("Settings") {
                    viewModel.openSystemSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("Allow") {
                    viewModel.openSystemSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.accentColor)
            }
        }
    }

    // MARK: - Awakening Toggles

    private func awakeningTogglesSection(_ data: AwakeningSettingsData) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { data.isGeofenceEnabled },
                set: { viewModel.toggleGeofenceAwakening($0) }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Geofence Awakening")
                        Text("Receive memories when arriving at meaningful places")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                } icon: {
                    Image(systemName: "mappin.circle")
                }
            }
            .disabled(!data.locationPermission.isGranted)

            Toggle(isOn: Binding(
                get: { data.isEmotionEnabled },
                set: { viewModel.toggleEmotionAwakening($0) }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Emotion Awakening")
                        Text("Surfaces joyful memories when mood is low")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                } icon: {
                    Image(systemName: "sparkles")
                }
            }
            .disabled(!data.healthPermission.isGranted)

            Toggle(isOn: Binding(
                get: { data.isAnniversaryEnabled },
                set: { viewModel.toggleAnniversaryAwakening($0) }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Anniversary Awakening")
                        Text("Daily 9:00 AM — memories from this day in past years")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            .disabled(!data.notificationPermission.isGranted)
        } header: {
            Text("Awakening Types")
        } footer: {
            if !data.notificationPermission.isGranted {
                Text("Enable notifications to receive awakening alerts.")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Geofence Management

    private func geofenceManagementSection(_ data: AwakeningSettingsData) -> some View {
        Section {
            if data.geofences.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "location.slash")
                        .font(.title2)
                        .foregroundStyle(Color.secondary)
                    Text("No geofences configured")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                    Text("Geofences are created automatically when you visit places frequently.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(data.geofences) { geofence in
                    Button {
                        viewModel.showGeofenceDetails(geofence)
                    } label: {
                        geofenceRow(geofence)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Monitored Geofences")
        } footer: {
            if !data.geofences.isEmpty {
                Text("Tap a geofence to view details. Geofences are automatically created from your visit patterns. Push deduplication: a geofence only delivers once per entry; must exit and re-enter to deliver again.")
            }
        }
    }

    private func geofenceRow(_ geofence: GeofenceInfo) -> some View {
        HStack {
            Image(systemName: geofence.isActive ? "location.circle.fill" : "location.circle")
                .foregroundStyle(geofence.isActive ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(geofence.displayName)
                    .font(.body)
                Text("\(geofence.memoryCount) memories · \(Int(geofence.radiusMeters))m radius")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                if let lastTriggered = geofence.lastTriggeredAt {
                    Text("Last delivery: \(lastTriggered.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    private func geofenceDetailSheet(_ geofence: GeofenceInfo) -> some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name", value: geofence.displayName)
                    LabeledContent("Status") {
                        Text(geofence.isActive ? "Active" : "Inactive")
                            .foregroundStyle(geofence.isActive ? Color.accentColor : Color.secondary)
                    }
                    LabeledContent("Radius", value: "\(Int(geofence.radiusMeters))m")
                    LabeledContent("Location") {
                        Text(String(format: "%.4f, %.4f", geofence.latitude, geofence.longitude))
                            .font(.caption)
                            .monospacedDigit()
                    }
                    LabeledContent("Memories", value: "\(geofence.memoryCount)")
                } header: {
                    Text("Geofence Details")
                }

                Section {
                    if let lastTriggered = geofence.lastTriggeredAt {
                        LabeledContent("Last Delivery", value: lastTriggered.formatted(date: .long, time: .shortened))
                    } else {
                        LabeledContent("Last Delivery") {
                            Text("Never")
                                .foregroundStyle(Color.secondary)
                        }
                    }
                } header: {
                    Text("Delivery Status")
                } footer: {
                    Text("Push deduplication: this geofence delivers only once per entry. You must exit and re-enter for a new delivery. Continuous stays never repeat push.")
                }
            }
            .navigationTitle(geofence.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        viewModel.dismissGeofenceDetail()
                    }
                }
            }
        }
    }

    // MARK: - Status Section

    private func statusSection(_ data: AwakeningSettingsData) -> some View {
        Section {
            if let lastDaily = data.lastDailyPushDate {
                LabeledContent("Last Daily Push", value: lastDaily.formatted(date: .abbreviated, time: .shortened))
            }
            if let lastEmotion = data.lastEmotionAnalysisDate {
                LabeledContent("Last Emotion Analysis", value: lastEmotion.formatted(date: .abbreviated, time: .shortened))
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Geofence push resets on exit+re-enter. Anniversary check runs daily at 9:00 AM. Emotion analysis caches results for 24 hours and uses 30-second debounce for new queries/feelings. Auditing records all awakening activity for 30 days (viewable in Audit Log).")
        }
    }
}

// MARK: - Preview

#Preview("Full Permissions") {
    NavigationStack {
        AwakeningSettingsView()
    }
}

#Preview("Unavailable") {
    NavigationStack {
        AwakeningSettingsView()
    }
}

#Preview("No Permissions") {
    NavigationStack {
        AwakeningSettingsView()
    }
}

#Preview("All Disabled") {
    NavigationStack {
        AwakeningSettingsView()
    }
}
