// ==========================================
// File: EchoSharedComponents.swift
// Specification: docs/ui/echo-memory-canvas-style.md
// Task: 4.0 - Balanced Canvas foundation and AppShell
// AC coverage: AC-2 (shared components), AC-4 (accessibility)
// Architecture: AGENTS.md §17.2 (shared visual language)
// Generated: 2026-08-31
// ==========================================

import SwiftUI

struct EchoSectionHeader: View {
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource?

    init(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EchoSpacingToken.compact.points) {
            Text(title)
                .font(EchoTypographyToken.subtitle.font)

            if let subtitle {
                Text(subtitle)
                    .font(EchoTypographyToken.metadata.font)
                    .foregroundStyle(EchoColorToken.secondaryText.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct EchoContainer<Content: View>: View {
    let level: EchoContainerLevel
    @ViewBuilder let content: Content

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        level: EchoContainerLevel = .card,
        @ViewBuilder content: () -> Content
    ) {
        self.level = level
        self.content = content()
    }

    var body: some View {
        content
            .padding(level.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(level.background)
            .overlay {
                if level != .canvas {
                    RoundedRectangle(cornerRadius: level.radius, style: .continuous)
                        .strokeBorder(
                            EchoColorToken.separator.color,
                            lineWidth: EchoAccessibilityPolicy.borderWidth(
                                increasedContrast: colorSchemeContrast == .increased
                            )
                        )
                }
            }
            .compositingGroup()
            .clipShape(
                RoundedRectangle(cornerRadius: level.radius, style: .continuous)
            )
    }
}

struct EchoMetadataGroup<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EchoSpacingToken.compact.points) {
            content
        }
        .font(EchoTypographyToken.metadata.font)
        .foregroundStyle(EchoColorToken.secondaryText.color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EchoStatusPresentation: View {
    let role: EchoStatusRole
    let systemImage: String
    let title: String
    let message: String?

    init(
        role: EchoStatusRole,
        systemImage: String,
        title: String,
        message: String? = nil
    ) {
        self.role = role
        self.systemImage = systemImage
        self.title = title
        self.message = message
    }

    var body: some View {
        HStack(alignment: .top, spacing: EchoSpacingToken.normal.points) {
            Image(systemName: systemImage)
                .font(EchoTypographyToken.subtitle.font)
                .foregroundStyle(role.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: EchoSpacingToken.compact.points) {
                Text(title)
                    .font(EchoTypographyToken.subtitle.font)

                if let message {
                    Text(message)
                        .font(EchoTypographyToken.body.font)
                        .foregroundStyle(EchoColorToken.secondaryText.color)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct EchoActionButtonStyle: ButtonStyle {
    let role: EchoActionRole

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(role: EchoActionRole = .primary) {
        self.role = role
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EchoTypographyToken.action.font)
            .foregroundStyle(foregroundStyle)
            .frame(maxWidth: role == .secondary ? nil : .infinity)
            .padding(.horizontal, EchoSpacingToken.grouped.points)
            .padding(.vertical, EchoSpacingToken.normal.points)
            .background(backgroundStyle)
            .overlay {
                RoundedRectangle(
                    cornerRadius: EchoRadiusToken.card.points,
                    style: .continuous
                )
                .strokeBorder(
                    borderStyle,
                    lineWidth: EchoAccessibilityPolicy.borderWidth(
                        increasedContrast: colorSchemeContrast == .increased
                    )
                )
            }
            .compositingGroup()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: EchoRadiusToken.card.points,
                    style: .continuous
                )
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(
                configuration.isPressed && EchoAccessibilityPolicy.allowsMotion(
                    reduceMotion: reduceMotion
                ) ? 0.98 : 1
            )
            .animation(
                EchoAccessibilityPolicy.allowsMotion(reduceMotion: reduceMotion)
                    ? .smooth(duration: 0.18)
                    : nil,
                value: configuration.isPressed
            )
    }

    private var foregroundStyle: Color {
        switch role {
        case .primary, .recovery: EchoColorToken.onWarmAccent.color
        case .secondary: .primary
        case .destructive: .white
        }
    }

    private var backgroundStyle: Color {
        switch role {
        case .primary, .recovery: EchoColorToken.warmAccent.color
        case .secondary: EchoColorToken.fill.color
        case .destructive: EchoColorToken.blocking.color
        }
    }

    private var borderStyle: Color {
        switch role {
        case .primary, .recovery: EchoColorToken.warmAccent.color
        case .secondary: EchoColorToken.separator.color
        case .destructive: EchoColorToken.blocking.color
        }
    }
}
