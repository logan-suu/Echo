// ==========================================
// 文件: ShareViewController.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-001 (备忘录/语音备忘录 Share 分享),
//            US-SRC-003 (第三方 Share 文本/图片/链接/文件, 导入前预览确认 + 标签/备注)
//            docs/decisions/ADR-008-source-import-boundaries.md §决策-2 (Share Extension 仅用户中介),
//            §决策-3 (App Group 信封原子入队), §决策-7 (最小数据边界)
// 任务: 3F.2 - PhotoKit、Share Extension 与真实来源
// AC 覆盖: US-SRC-001 (share-only 备忘录/语音), US-SRC-003 AC-1 (文本/图片/链接/文件),
//          AC-2 (导入前预览确认 + 可选标签/备注), AC-3 (第三方标记 source=thirdParty),
//          ADR-008 §决策-2 (拒绝不支持类型, 不落明文审计), §决策-3 (App Group 原子入队)
// 架构约束: AGENTS.md R-002 (文本记忆仅来自分享/转写, 无用户主动输入), R-007 (禁止 unchecked Sendable)
// 重要: 本 target 为 App Extension（独立进程），仅编译 SharedImportEnvelope + SharedImportQueueActor，
//       不依赖 Echo App target 其他符号。App Group 容器承载信封队列（ADR-008 §决策-3）
// 生成时间: 2026-08-05
// ==========================================

import UIKit
import UniformTypeIdentifiers

/// Share 内容提取器（US-SRC-003 AC-1：文本/图片/链接/文件；ADR-008 §决策-2 拒绝不支持类型）。
enum ShareContentExtractor {

    /// 从扩展上下文 attachments 提取分享信封（App Group 最小字段，不存原文件全文）。
    static func envelopes(
        from providers: [NSItemProvider],
        sourceAppBundleId: String
    ) async throws -> [SharedImportEnvelope] {
        var envelopes: [SharedImportEnvelope] = []
        for provider in providers {
            if let envelope = try await envelope(from: provider, sourceAppBundleId: sourceAppBundleId) {
                envelopes.append(envelope)
            }
        }
        return envelopes
    }

    private static func envelope(
        from provider: NSItemProvider,
        sourceAppBundleId: String
    ) async throws -> SharedImportEnvelope? {
        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            let text = try await loadString(from: provider)
            // 备忘录显式分享（US-SRC-001）→ note；其他 App → thirdParty（US-SRC-003 AC-3）
            let source: SharedImportSourceType =
                sourceAppBundleId == "com.apple.mobilenotes" ? .note : .thirdParty
            return try SharedImportEnvelope.make(
                contentKind: .text,
                sourceType: source,
                payload: text,
                sourceAppBundleId: sourceAppBundleId
            )
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            guard let url = await loadURL(from: provider) else { return nil }
            return try SharedImportEnvelope.make(
                contentKind: .url,
                sourceType: .thirdParty,
                payload: url.absoluteString,
                sourceAppBundleId: sourceAppBundleId
            )
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
            || provider.hasItemConformingToTypeIdentifier("com.apple.m4a-audio") {
            let fileURL = await loadFileURL(from: provider)
            let source: SharedImportSourceType =
                sourceAppBundleId == "com.apple.VoiceMemos" ? .voice : .thirdParty
            return try SharedImportEnvelope.make(
                contentKind: .audio,
                sourceType: source,
                payload: fileURL?.absoluteString ?? "",
                sourceAppBundleId: sourceAppBundleId
            )
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let fileURL = await loadFileURL(from: provider)
            return try SharedImportEnvelope.make(
                contentKind: .image,
                sourceType: .thirdParty,
                payload: fileURL?.absoluteString ?? "",
                sourceAppBundleId: sourceAppBundleId
            )
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let fileURL = await loadFileURL(from: provider)
            return try SharedImportEnvelope.make(
                contentKind: .file,
                sourceType: .thirdParty,
                payload: fileURL?.absoluteString ?? "",
                sourceAppBundleId: sourceAppBundleId
            )
        }
        // 不支持类型 → 拒绝（ADR-008 §决策-2）
        return nil
    }

    private static func loadString(from provider: NSItemProvider) async throws -> String {
        let data = try await loadData(from: provider, type: UTType.text.identifier)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SharedImportError.emptyPayload
        }
        return string
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        guard let url = await withCheckedContinuation({ continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url = item as? URL ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:))
                continuation.resume(returning: url)
            }
        }) else { return nil }
        return url
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                continuation.resume(returning: item as? URL)
            }
        }
    }

    private static func loadData(from provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: SharedImportError.emptyPayload)
                }
            }
        }
    }
}

/// Share Extension 主控制器 — 导入前预览确认（US-SRC-003 AC-2），确认后 App Group 原子入队。
final class ShareViewController: UIViewController {

    private let queue = SharedImportQueueActor.shared
    private var pendingEnvelopes: [SharedImportEnvelope] = []

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let noteField = UITextField()
    private let importButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        extractAndPreview()
    }

    // MARK: - Extraction + Preview (AC-2)

    private func extractAndPreview() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem else {
            finishWithError(nil)
            return
        }
        let providers = item.attachments ?? []
        // CodeRabbit #5: Bundle.main.bundleIdentifier 在扩展进程内返回扩展自身 ID
        // （com.echo.Echo.ShareExtension），iOS 公开 API 无 host app bundle ID 获取方式，
        // 故 note/voice 来源标记在此不可达（恒为 thirdParty）。host 识别并入 3F.5
        // （DEF-51-002/DEF-51-003 合并处理）。
        let host = Bundle.main.bundleIdentifier ?? ""
        Task {
            do {
                let envelopes = try await ShareContentExtractor.envelopes(
                    from: providers,
                    sourceAppBundleId: host
                )
                pendingEnvelopes = envelopes
                updatePreview(envelopes)
            } catch {
                finishWithError(error)
            }
        }
    }

    private func updatePreview(_ envelopes: [SharedImportEnvelope]) {
        guard !envelopes.isEmpty else {
            finishWithError(nil)
            return
        }
        let kinds = envelopes.map(\.contentKind.rawValue).joined(separator: ", ")
        titleLabel.text = "Import to Echo"
        detailLabel.text = "\(envelopes.count) item(s) · \(kinds)\nYour content stays on this device."
    }

    // MARK: - Actions

    @objc private func importTapped() {
        guard !pendingEnvelopes.isEmpty else {
            finishWithError(nil)
            return
        }
        let label = noteField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let envelopes = pendingEnvelopes
        Task {
            do {
                for var envelope in envelopes {
                    if let label, !label.isEmpty {
                        envelope = SharedImportEnvelope(
                            envelopeId: envelope.envelopeId,
                            contentKind: envelope.contentKind,
                            sourceType: envelope.sourceType,
                            payload: envelope.payload,
                            sourceAppBundleId: envelope.sourceAppBundleId,
                            createdAt: envelope.createdAt,
                            optionalLabel: label
                        )
                    }
                    _ = try await queue.enqueue(envelope)
                }
                completeRequest()
            } catch {
                finishWithError(error)
            }
        }
    }

    @objc private func cancelTapped() {
        completeRequest()
    }

    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func finishWithError(_ error: Error?) {
        detailLabel.text = error == nil ? "Nothing to share." : "Unable to import this content."
        importButton.isEnabled = pendingEnvelopes.isEmpty == false
    }

    // MARK: - UI

    private func setupUI() {
        titleLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        detailLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        noteField.placeholder = "Add a label (optional)"
        noteField.borderStyle = .roundedRect
        importButton.setTitle("Import", for: .normal)
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.secondaryLabel, for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, noteField, importButton, cancelButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }
}
