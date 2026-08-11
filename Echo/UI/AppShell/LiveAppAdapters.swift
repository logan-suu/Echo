// ==========================================
// 文件: LiveAppAdapters.swift
// 对应规格: docs/05-planning/phase3f-execution-plan.md → 3F.7 (UI 到 Core 全域接线)
//            docs/ui/architecture.md §7 (适配器契约)
// 任务: 3F.7 - UI 到 Core 全域接线
// AC 覆盖: 默认 live adapter、无 fixture fallback、真实设置值、跨 surface journey
// 架构约束: AGENTS.md §8.1 (@MainActor @Observable 薄适配器), §17.4 (Core 只读消费),
//           AGENTS.md §4.2 (仅持有不可变 actor 引用), R-007
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-11
// ==========================================

import Foundation

/// 生产 live 适配器 — 将 UI ViewModel 与 composition 持有的 live Core 依赖接线。
///
/// 设计原则（docs/ui/architecture.md §7 + AGENTS.md §17.4）：
/// - 薄适配器：仅做线程隔离、状态映射与 UI 事件转发，不复制业务规则
/// - 无 fixture fallback：默认构造使用 live 依赖；fixture 仅限 #if DEBUG / Preview
/// - 唯一依赖图：经 AppComposition.shared 装配（ADR-007 §决策-1）
@MainActor
public enum LiveAppAdapters {

    /// 从 composition 装配生产 SearchPipeline（3F.6 多通道检索 + 反馈）。
    ///
    /// - Returns: 生产 SearchPipeline（使用活跃 generation 路由 + 文本嵌入器 + 反馈重排）
    public static func makeSearchPipeline(
        composition: AppComposition = .shared
    ) async -> SearchPipeline {
        let registry = composition.generationRegistry
        let activeStore = await resolveActiveTextStore(registry: registry) ?? VectorStoreActor(dimension: 512)
        return SearchPipeline(
            embedder: composition.textEmbedder,
            privacyActor: composition.privacyActor,
            vectorStore: activeStore,
            feedbackActor: .shared
        )
    }

    /// 从 composition 装配生产 FeedbackPipeline。
    public static func makeFeedbackPipeline(
        composition: AppComposition = .shared
    ) -> FeedbackPipeline {
        FeedbackPipeline(
            feedbackActor: .shared,
            privacyActor: composition.privacyActor,
            pendingOpsActor: .shared,
            generationRegistry: composition.generationRegistry
        )
    }

    /// 装配生产 DataOverviewService。
    public static func makeDataOverviewService(
        composition: AppComposition = .shared
    ) -> DataOverviewService {
        DataOverviewService(
            db: composition.databaseManager,
            generationRegistry: composition.generationRegistry,
            modelLoader: composition.modelLoader,
            privacyActor: composition.privacyActor
        )
    }

    /// 装配生产 DeviceMigrationActor。
    public static func makeDeviceMigrationActor(
        composition: AppComposition = .shared
    ) -> DeviceMigrationActor {
        DeviceMigrationActor(
            db: composition.databaseManager,
            canonicalRepository: CanonicalMemoryRepositoryActor(
                db: composition.databaseManager,
                generationRegistry: composition.generationRegistry
            ),
            excludedAssets: .shared,
            privacyActor: composition.privacyActor,
            generationRegistry: composition.generationRegistry,
            textEmbedder: composition.textEmbedder
        )
    }

    /// 装配生产 CanonicalMemoryRepositoryActor（详情页编辑/删除）。
    public static func makeCanonicalRepository(
        composition: AppComposition = .shared
    ) -> CanonicalMemoryRepositoryActor {
        CanonicalMemoryRepositoryActor(
            db: composition.databaseManager,
            generationRegistry: composition.generationRegistry
        )
    }

    // MARK: - Private Helpers

    /// 异步解析活跃 text generation 向量存储（供需要 await 的调用方使用）。
    public static func resolveActiveTextStore(
        registry: GenerationRegistryActor
    ) async -> VectorStoreActor? {
        guard let route = try? await registry.loadActiveRoute() else { return nil }
        return await registry.vectorStore(for: route.textGeneration)
    }
}
