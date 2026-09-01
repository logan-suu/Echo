// ==========================================
// File: DiscoveryViews.swift
// Specification: docs/ui/echo-memory-canvas-style.md §§6, 8
// Task: 4.0a - Discovery Balanced Canvas with live Home/Search data
// AC coverage: AC-2 (adaptive masonry), AC-4 (stable semantic order and Focus route)
// Architecture: AGENTS.md §17.2 (Discovery surface family)
// Generated: 2026-09-01
// ==========================================

@preconcurrency import Photos
import SwiftUI
import UIKit

struct DiscoveryMasonryLayout: Layout {
    let columnCount: Int
    let spacing: CGFloat

    init(columnCount: Int = 2, spacing: CGFloat = DiscoveryPresentationRules.columnSpacing) {
        self.columnCount = max(1, columnCount)
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? DiscoveryPresentationRules.minimumMasonryContentWidth
        let layout = measurements(width: width, subviews: subviews)
        return CGSize(width: width, height: layout.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let layout = measurements(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            guard layout.frames.indices.contains(index) else { continue }
            let frame = layout.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func measurements(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let columnWidth = max(0, (width - totalSpacing) / CGFloat(columnCount))
        var heights = Array(repeating: CGFloat.zero, count: columnCount)
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)

        for subview in subviews {
            let column = heights.enumerated().min { lhs, rhs in
                lhs.element == rhs.element ? lhs.offset < rhs.offset : lhs.element < rhs.element
            }?.offset ?? 0
            let size = subview.sizeThatFits(
                ProposedViewSize(width: columnWidth, height: nil)
            )
            let x = CGFloat(column) * (columnWidth + spacing)
            let y = heights[column]
            frames.append(CGRect(x: x, y: y, width: columnWidth, height: size.height))
            heights[column] += size.height + spacing
        }

        let height = max(0, (heights.max() ?? 0) - (subviews.isEmpty ? 0 : spacing))
        return (frames, height)
    }
}

struct DiscoveryMemoryCardView: View {
    let card: DiscoveryCardPresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            EchoContainer(level: .card) {
                VStack(alignment: .leading, spacing: EchoSpacingToken.normal.points) {
                    if let aspectRatio = card.aspectRatio {
                        DiscoveryMediaThumbnail(
                            assetID: card.sourceLocator,
                            aspectRatio: aspectRatio,
                            sourceType: card.sourceType
                        )
                    }

                    if let summary = card.summary {
                        Text(summary)
                            .font(EchoTypographyToken.body.font)
                            .foregroundStyle(EchoColorToken.primaryText.color)
                            .lineLimit(card.presentationKind == .scanEligible ? 3 : nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    EchoMetadataGroup {
                        Label(sourceLabel, systemImage: sourceSymbol)
                        Text(
                            Date(timeIntervalSince1970: card.timestamp),
                            format: .dateTime.month(.abbreviated).day().year()
                        )
                        if let locationLabel = card.locationLabel {
                            Label(locationLabel, systemImage: "location")
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Open memory details")
        .accessibilityIdentifier("discovery-memory-\(card.id.uuidString)")
    }

    private var sourceLabel: LocalizedStringResource {
        switch card.sourceType.lowercased() {
        case "photo": "Photo"
        case "video", "video_frame", "video_audio": "Video"
        case "voice": "Voice"
        default: "Note"
        }
    }

    private var sourceSymbol: String {
        switch card.sourceType.lowercased() {
        case "photo": "photo"
        case "video", "video_frame", "video_audio": "video"
        case "voice": "waveform"
        default: "note.text"
        }
    }

    private var accessibilityLabel: String {
        let summary = card.summary ?? String(localized: sourceLabel)
        let date = Date(timeIntervalSince1970: card.timestamp)
            .formatted(date: .abbreviated, time: .omitted)
        return "\(summary), \(date)"
    }
}

struct DiscoveryMediaThumbnail: View {
    let assetID: String
    let aspectRatio: CGFloat
    let sourceType: String

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(EchoColorToken.fill.color)
                    .overlay {
                        Image(systemName: sourceType.lowercased().contains("video") ? "video" : "photo")
                            .font(EchoTypographyToken.subtitle.font)
                            .foregroundStyle(EchoColorToken.secondaryText.color)
                            .accessibilityHidden(true)
                    }
            }
        }
        .aspectRatio(max(aspectRatio, 0.1), contentMode: .fit)
        .frame(maxWidth: .infinity)
        .compositingGroup()
        .clipShape(.rect(cornerRadius: EchoRadiusToken.image.points))
        .accessibilityHidden(true)
        .task(id: assetID) {
            loadImage()
        }
    }

    @MainActor
    private func loadImage() {
        guard image == nil,
              let asset = PHAsset.fetchAssets(
                  withLocalIdentifiers: [assetID],
                  options: nil
              ).firstObject else { return }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 720, height: 720 / max(aspectRatio, 0.1)),
            contentMode: .aspectFill,
            options: options
        ) { loadedImage, _ in
            image = loadedImage
        }
    }
}
