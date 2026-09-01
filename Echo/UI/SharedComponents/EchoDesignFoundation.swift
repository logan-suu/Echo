// ==========================================
// File: EchoDesignFoundation.swift
// Specification: docs/ui/echo-memory-canvas-style.md
// Task: 4.0 - Balanced Canvas foundation and AppShell
// AC coverage: AC-1 (profile contract), AC-2 (shared design tokens)
// Architecture: AGENTS.md §17.2 (surface families)
// Generated: 2026-08-31
// ==========================================

import SwiftUI

enum EchoSurfaceFamily: String, CaseIterable, Hashable, Sendable {
    case discovery
    case focus
    case task
}

struct EchoDesignProfile: Equatable, Sendable {
    let id: String
    let baseProfile: String
    let version: String
    let supportedSurfaceFamilies: [EchoSurfaceFamily]

    static let balancedCanvas = EchoDesignProfile(
        id: "echo-memory-canvas",
        baseProfile: "apple-native",
        version: "1.1.0",
        supportedSurfaceFamilies: EchoSurfaceFamily.allCases
    )
}

enum EchoAppShellContract {
    static let designProfileID = EchoDesignProfile.balancedCanvas.id
    static let hostedSurfaceFamilies = Set(EchoSurfaceFamily.allCases)
    static let usesNativeTabView = true
    static let usesPerTabNavigationStack = true
    static let usesNativeToolbarSearchAndModalChrome = true
    static let isContentSurface = false
}

enum EchoTypographyToken: String, CaseIterable, Hashable, Sendable {
    case title
    case subtitle
    case body
    case metadata
    case caption
    case action

    @MainActor
    var font: Font {
        switch self {
        case .title:
            .largeTitle.weight(.bold)
        case .subtitle:
            .headline
        case .body:
            .body
        case .metadata:
            .subheadline
        case .caption:
            .caption
        case .action:
            .body.weight(.semibold)
        }
    }
}

enum EchoSpacingToken: CaseIterable, Hashable, Sendable {
    case compact
    case normal
    case grouped
    case section

    var points: CGFloat {
        switch self {
        case .compact: 8
        case .normal: 12
        case .grouped: 16
        case .section: 20
        }
    }
}

enum EchoColorToken: CaseIterable, Hashable, Sendable {
    case primaryText
    case secondaryText
    case canvasBackground
    case groupedBackground
    case cardBackground
    case fill
    case separator
    case warmAccent
    case success
    case warning
    case blocking
    case conflict

    @MainActor
    var color: Color {
        switch self {
        case .primaryText: .primary
        case .secondaryText: .secondary
        case .canvasBackground: Color(.systemBackground)
        case .groupedBackground: Color(.systemGroupedBackground)
        case .cardBackground: Color(.secondarySystemGroupedBackground)
        case .fill: Color(.secondarySystemFill)
        case .separator: Color(.separator)
        case .warmAccent: Color.accentColor
        case .success: .green
        case .warning: .orange
        case .blocking: .red
        case .conflict: .purple
        }
    }
}

enum EchoRadiusToken: CaseIterable, Hashable, Sendable {
    case image
    case card
    case groupedContainer

    var points: CGFloat {
        switch self {
        case .image: 12
        case .card: 16
        case .groupedContainer: 20
        }
    }
}

enum EchoContainerLevel: CaseIterable, Hashable, Sendable {
    case canvas
    case section
    case card
    case emphasized

    @MainActor
    var background: Color {
        switch self {
        case .canvas:
            EchoColorToken.canvasBackground.color
        case .section:
            EchoColorToken.groupedBackground.color
        case .card:
            EchoColorToken.cardBackground.color
        case .emphasized:
            EchoColorToken.warmAccent.color.opacity(0.10)
        }
    }

    var padding: CGFloat {
        switch self {
        case .canvas: 0
        case .section: EchoSpacingToken.section.points
        case .card, .emphasized: EchoSpacingToken.grouped.points
        }
    }

    var radius: CGFloat {
        switch self {
        case .canvas: 0
        case .section: EchoRadiusToken.groupedContainer.points
        case .card, .emphasized: EchoRadiusToken.card.points
        }
    }
}

enum EchoStatusRole: CaseIterable, Hashable, Sendable {
    case informational
    case success
    case warning
    case blocking
    case conflict

    @MainActor
    var color: Color {
        switch self {
        case .informational: EchoColorToken.warmAccent.color
        case .success: EchoColorToken.success.color
        case .warning: EchoColorToken.warning.color
        case .blocking: EchoColorToken.blocking.color
        case .conflict: EchoColorToken.conflict.color
        }
    }
}

enum EchoActionRole: CaseIterable, Hashable, Sendable {
    case primary
    case secondary
    case recovery
    case destructive
}

enum EchoAccessibilityPolicy {
    static func borderWidth(increasedContrast: Bool) -> CGFloat {
        increasedContrast ? 2 : 1
    }

    static func allowsMotion(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }
}

extension EnvironmentValues {
    @Entry var echoDesignProfile: EchoDesignProfile = .balancedCanvas
}

private struct EchoAppShellStyleModifier: ViewModifier {
    let profile: EchoDesignProfile

    func body(content: Content) -> some View {
        content
            .environment(\.echoDesignProfile, profile)
            .tint(EchoColorToken.warmAccent.color)
    }
}

extension View {
    func echoAppShell(
        profile: EchoDesignProfile = .balancedCanvas
    ) -> some View {
        modifier(EchoAppShellStyleModifier(profile: profile))
    }
}
