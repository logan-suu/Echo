// ==========================================
// 文件: AppComposition.swift
// 对应规格: docs/decisions/ADR-007-production-composition-consent.md §决策-1 (composition root),
//            §决策-2 (deny-by-default 同意), §决策-3 (事务性撤回/清除), §决策-5 (不可用启动状态)
//            docs/01-spec/用户故事与验收标准规格书.md → US-PRV-001, US-PRV-008, US-RES-004
// 任务: 3F.1 - Production composition、首次启动、同意与隐私
// AC 覆盖: ADR-007 §决策-1 (唯一依赖图 + 启动状态机), §决策-2 (同意闸门装配),
//          §决策-3 (撤回 → 事务清除 → blocked), §决策-5 (model/route/index-unavailable/bootstrap-failed)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §8.1 (@MainActor @Observable), R-007 (禁止 unchecked Sendable)
// 生成时间: 2026-08-04, 2026-08-05 (PR review 修复: bootstrapFailed 独立状态)
// ==========================================

import Foundation
import Observation

// MARK: - Startup State

/// App 启动状态机 (ADR-007 §决策-5)
public enum AppStartupState: Sendable, Equatable {
    /// 未初始化
    case idle
    /// 正在装配（打开数据库、加载策略与同意状态）
    case bootstrapping
    /// deny-by-default：新装用户未同意，需展示引导 (US-PRV-008)
    case requiresConsent
    /// 用户拒绝 PIPL 同意（US-PRV-008 AC-3）
    case consentDeclined
    /// 已同意、策略已加载、数据库可访问
    case ready
    /// 模型不可用（US-RES-004 / ADR-007 §决策-5）
    case modelUnavailable
    /// 活跃路由不可用（ADR-007 §决策-5）
    case routeUnavailable
    /// 索引不可用（ADR-007 §决策-5）
    case indexUnavailable
    /// 撤回/清除失败，进入 blocked 状态（ADR-007 §决策-3）
    case purgeBlocked
    /// 启动装配失败（数据库打开/同意/策略加载），与 purge 失败语义分离
    case bootstrapFailed
}

// MARK: - App Composition Root

/// 应用自有 composition root — 持有唯一依赖图并驱动启动状态机 (ADR-007 §决策-1)。
///
/// 默认 App 从 composition root 构造；fixtures 仅限测试/预览。
@MainActor
@Observable
public final class AppComposition {

    public static let shared = AppComposition()

    // MARK: - Dependency Graph

    public let databaseManager: DatabaseManager
    public let privacyActor: PrivacyActor
    public let consentStore: ConsentStoreActor
    public let modelLoader: ModelLoaderActor
    public let generationRegistry: GenerationRegistryActor
    /// 文本嵌入器（E5）— 生产摄入/检索文本路径（CR-10）
    public let textEmbedder: any EmbedderProtocol
    /// 视觉嵌入器（SigLIP2）— 图片/视频帧生产路径（CR-10）
    public let visionEmbedder: any EmbedderProtocol
    /// ASR 引擎（Whisper）— 语音转写生产路径（CR-10）
    public let asrEngine: (any ASREngineProtocol)?

    // MARK: - Startup State

    public private(set) var startupState: AppStartupState = .idle

    // MARK: - Initialization

    public init(
        databaseManager: DatabaseManager = .shared,
        privacyActor: PrivacyActor = .shared,
        consentStore: ConsentStoreActor = .shared,
        modelLoader: ModelLoaderActor = .shared,
        generationRegistry: GenerationRegistryActor = .shared,
        textEmbedder: any EmbedderProtocol = E5Embedder(),
        visionEmbedder: any EmbedderProtocol = SigLIP2Embedder(),
        asrEngine: (any ASREngineProtocol)? = WhisperASREngine()
    ) {
        self.databaseManager = databaseManager
        self.privacyActor = privacyActor
        self.consentStore = consentStore
        self.modelLoader = modelLoader
        self.generationRegistry = generationRegistry
        self.textEmbedder = textEmbedder
        self.visionEmbedder = visionEmbedder
        self.asrEngine = asrEngine
    }

    // MARK: - Bootstrap

    /// 装配依赖图并确定启动状态 (ADR-007 §决策-1/2/5)。
    ///
    /// 1. 打开 SQLite（NSFileProtectionComplete）
    /// 2. 加载同意状态（deny-by-default）
    /// 3. 加载 UserPolicy
    /// 4. 启用同意闸门（生产 deny-by-default）
    /// 5. 确定启动状态
    public func bootstrap() async {
        // Idempotence guard: a second call must not re-open the DB or leak the prior connection handle
        guard startupState == .idle else { return }
        startupState = .bootstrapping
        do {
            try await databaseManager.open()
            try await consentStore.loadState()
            try await privacyActor.loadPolicy()
            // UI tests/previews (DEBUG only): -ui-skip-consent bypasses the deny-by-default
            // gate and lands in .ready (fixture-driven XCUITest relies on the ungated path)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-skip-consent") {
                startupState = .ready
                return
            }
            #endif
            // Production wiring enables the deny-by-default consent gate
            await privacyActor.enableConsentEnforcement(consentStore: consentStore)

            let consented = await consentStore.hasConsented()
            startupState = consented ? .ready : .requiresConsent
        } catch {
            // DB open / consent / policy load failure (L3): enter a dedicated bootstrapFailed
            // state, separated from purge failures so the UI does not misreport "cleanup incomplete"
            startupState = .bootstrapFailed
        }
    }

    /// Waits for bootstrap to actually finish (for AppDelegate source wiring).
    ///
    /// 3F.2 review fix: `bootstrap()`'s idempotence guard returns immediately for concurrent
    /// callers while state is `.bootstrapping`, so AppDelegate.configureSources could check
    /// startupState too early and get intercepted (observer never registered, photo auth
    /// prompt never shown). Waits until startupState leaves idle/bootstrapping.
    public func awaitBootstrapCompletion() async {
        while startupState == .idle || startupState == .bootstrapping {
            // 显式处理取消：Task.sleep 抛出 CancellationError 时退出，避免 try? 吞错后忙等
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return
            }
        }
    }

    /// 用户同意后更新启动状态（US-PRV-008）
    public func acceptConsent(consentVersion: Int, policyVersion: Int) async throws {
        try await consentStore.acceptConsent(consentVersion: consentVersion, policyVersion: policyVersion)
        startupState = .ready
    }

    /// 用户拒绝同意（US-PRV-008 AC-3）
    public func declineConsent() {
        startupState = .consentDeclined
    }

    /// 撤回同意 = 注销清除（ADR-007 §决策-3）
    public func revokeConsent(boundary: PurgeBoundary = .full) async throws -> PurgeResult {
        let result = try await consentStore.revokeConsent(boundary: boundary)
        startupState = result.success ? .requiresConsent : .purgeBlocked
        return result
    }

    // MARK: - Unavailable State Transitions (ADR-007 §决策-5)

    public func markModelUnavailable() {
        startupState = .modelUnavailable
    }

    public func markRouteUnavailable() {
        startupState = .routeUnavailable
    }

    public func markIndexUnavailable() {
        startupState = .indexUnavailable
    }
}
