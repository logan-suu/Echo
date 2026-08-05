// ==========================================
// 文件: AppDelegate.swift
// 对应规格: AGENTS.md §10.1 强制目录结构
//            docs/decisions/ADR-008-source-import-boundaries.md §决策-1 (PhotoKit 授权与变更观察),
//            §决策-3 (App Group 队列消费)
// 任务: 1.1 - 创建 Xcode 项目，配置 Swift 6 并发严格模式
//       3F.1 - Production composition root (ADR-007 §决策-1)
//       3F.2 - PhotoKit、Share Extension 与真实来源 (US-SRC-001 AC-1/AC-5, US-SRC-012 AC-1)
// 用途: BGTask 注册 (US-SYS-001 后台任务面板) + 来源边界装配
// 架构约束: 遵循 AGENTS.md §9 (后台任务与断点续传), deny-by-default (ADR-007 §决策-2)
// 生成时间: 2026-07-04, 2026-08-05 (3F.2 来源装配)
// ==========================================

import UIKit
import Photos
import PhotosUI

/// Echo 应用代理 — 负责后台任务注册与生命周期管理
/// 后台任务包括：定时扫描、数据同步、索引构建（US-SYS-001）
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// 相册变更同步管线（US-SRC-012 AC-1）— 持有防释放
    private var syncPipeline: SyncPipeline?
    /// Share 队列摄入管线（ADR-008 §决策-3）— 持有防释放
    private var ingestPipeline: IngestPipeline?
    /// PhotoKit 来源适配器（iOS 26 limited 选择器主动弹出）— 持有防释放
    private var photoSourceAdapter: PhotoKitSourceAdapter?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 生产装配：确保 composition root 已初始化（幂等，主装配在 EchoApp.task）
        _ = AppComposition.shared
        Task { @MainActor in
            await configureSources()
        }
        // iOS 26 limited 适配：系统不再自动弹照片选择器，回前台时主动呈现（3F.2 review fix）
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.presentLimitedLibraryPickerIfNeeded()
            }
        }
        return true
    }

    /// 来源边界装配（3F.2）：相册变更监听 + Share 队列排空。
    ///
    /// - deny-by-default：仅已同意状态下装配来源（ADR-007 §决策-2）
    /// - 相册变更经 `PhotoKitChangeObserver` 去重后驱动 `SyncPipeline.sync`
    /// - Share 队列经 `IngestPipeline.drainSharedImports` 恰好一次消费
    /// - 推理服务（E5/SigLIP2/Whisper）为运行时服务实现，模型工件由 3F.3 接入；
    ///   当前未加载模型时摄入在嵌入阶段失败并回滚，3F.3 接入后自动产生真实向量
    private func configureSources() async {
        let composition = AppComposition.shared
        await composition.bootstrap()
        guard composition.startupState == .ready
                || composition.startupState == .modelUnavailable
                || composition.startupState == .indexUnavailable else {
            return
        }

        // 相册变更监听（US-SRC-012 AC-1, ADR-008 §决策-1）
        let vectorStore = VectorStoreActor(dimension: 512)
        let sync = SyncPipeline(
            embedder: SigLIP2Embedder(),
            privacyActor: composition.privacyActor,
            vectorStore: vectorStore,
            excludedAssets: .shared,
            progressActor: .shared
        )
        await sync.registerPhotoLibraryObserver()
        syncPipeline = sync        // Share 队列排空（US-SRC-001/003, ADR-008 §决策-3）— 恰好一次消费
        let ingest = IngestPipeline(
            embedder: E5Embedder(),
            asrEngine: WhisperASREngine(),
            privacyActor: composition.privacyActor,
            vectorStore: vectorStore,
            excludedAssets: .shared
        )
        ingestPipeline = ingest
        _ = try? await ingest.drainSharedImports(from: .shared)

        // PhotoKit 来源适配器（iOS 26 limited 选择器主动弹出；3F.2 review fix）
        photoSourceAdapter = PhotoKitSourceAdapter(
            library: RealPhotoLibrary(),
            privacyActor: composition.privacyActor,
            configuration: .production
        )
    }

    /// iOS 26 limited 适配：授权为 limited 且尚无已选照片时，主动呈现系统照片选择器
    /// （iOS 26 起系统在点「Limit Access」后不再自动弹出，需 App 调用 presentLimitedLibraryPicker）。
    ///
    /// 仅在 iOS 26+ 生效：iOS 18/19 系统会自动弹出选择器，若在此主动调用会叠弹第二个，
    /// 且用户选照片后 becomeActive 时资产已非空，本检查天然返回 false。
    @MainActor
    private func presentLimitedLibraryPickerIfNeeded() async {
        guard #available(iOS 26, *) else { return }
        guard let adapter = photoSourceAdapter else { return }
        guard await adapter.shouldPresentLimitedLibraryPicker() else { return }
        guard let rootVC = await Self.keyWindowRootViewController() else { return }
        await PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: rootVC)
        await adapter.markLimitedLibraryPickerPresented()
    }

    /// 获取当前活跃 window 的 rootViewController（presentLimitedLibraryPicker 需要 presenter）。
    @MainActor
    private static func keyWindowRootViewController() -> UIViewController? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState == .foregroundActive else { continue }
            for window in windowScene.windows where window.isKeyWindow {
                return window.rootViewController
            }
        }
        return nil
    }
}
