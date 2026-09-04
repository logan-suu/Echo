// ==========================================
// 文件: AwakeningPipeline.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-001 (地理围栏情境记忆唤醒)
//                                                       → US-AWK-003 (情绪感知记忆唤醒)
//            docs/02-architecture/数据流全链路技术说明文档.md §5.1 (地理围栏唤醒), §5.2 (情绪唤醒)
//            docs/02-architecture/架构设计文档.md §2.1 (AwakeningPipeline)
// 任务: 2.11 - AwakeningPipeline：地理围栏（US-AWK-001）
//       2.12 - AwakeningPipeline：情绪唤醒（US-AWK-003）
//       4.0f - HealthKit read-request outcome contract（US-AWK-003）
// AC 覆盖: US-AWK-001 AC-1 ✅ (仅didEnter触发), AC-2 ✅ (离开重置, 永不重复推送),
//          AC-3 🔮 Phase 3 (余弦≥0.7过滤已实现, GeoFilter依赖SearchPipeline Phase 3), AC-4 ✅ (回忆卡片生成接口),
//          AC-5 ✅ (定位权限关闭静默禁用), AC-6 ✅ (审计记录.contextualAwakening)
//          US-AWK-003 AC-1 ✅ (HealthKit心率变异推断情绪), AC-2 ✅ (文本情感分析+24h缓存+防抖30s),
//          AC-3 ✅ (mood→tag映射), AC-4 ✅ (温和回忆卡片), AC-5 ✅ (审计.emotionalAwakening)
//          4.0f AC-6 ✅ (request lifecycle + readable-sample state; no inferred read authorization)
// PR Review fix: SwiftLint implicit_optional_initialization, Search L1 3 retries + backoff, i18n Phase 3 comment
// PR Review fix: writeAwakeningAudit 移除冗余 validate(), 接收已有 checkpoint.policyVersion
// CodeRabbit fix: PrivacyCheckpoint 移至 state read 之前, 新增 claimForProcessing() 原子操作, search 失败增加审计
// 架构约束: AGENTS.md §4.1 (Pipeline 契约 — 纯函数、无状态、审计强制、错误分级),
//           R-006 (PrivacyCheckpoint 强制注入), R-008 (跨 Actor await),
//           AGENTS.md §4.4 (L1~L4 统一错误分级),
//           PIPE-010 (持有不可变 actor 引用时 actor 声明为合法模式)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-07-12
// ==========================================

import Foundation

// MARK: - Geofence State

/// 单个地理围栏的推送状态（AC-2: 离开重置, 永不重复推送）。
///
/// 持久化于 UserDefaults，通过 ``GeofenceStateStore`` 管理。
public struct GeofenceState: Sendable, Equatable {
    /// 是否已推送过
    public nonisolated let hasBeenPushed: Bool
    /// 自上次推送后是否已离开围栏（exit → 可再次推送）
    public nonisolated let hasExited: Bool

    public nonisolated init(hasBeenPushed: Bool = true, hasExited: Bool = false) {
        self.hasBeenPushed = hasBeenPushed
        self.hasExited = hasExited
    }

    /// 序列化为 JSON Data（使用 JSONSerialization 避免 Codable 的 MainActor 隔离）
    public nonisolated func encode() -> Data? {
        let dict: [String: Any] = [
            "hasBeenPushed": hasBeenPushed,
            "hasExited": hasExited
        ]
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    /// 从 JSON Data 反序列化
    public nonisolated static func decode(from data: Data) -> GeofenceState? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hasBeenPushed = dict["hasBeenPushed"] as? Bool,
              let hasExited = dict["hasExited"] as? Bool else {
            return nil
        }
        return GeofenceState(hasBeenPushed: hasBeenPushed, hasExited: hasExited)
    }
}

// MARK: - Geofence State Store

/// 地理围栏推送状态持久化存储。
///
/// 封装 UserDefaults，提供 actor 隔离的线程安全访问。
/// 用于跟踪每个围栏是否已推送、是否已离开（AC-2）。
public actor GeofenceStateStore {
    private let defaults: UserDefaults
    private let keyPrefix = "awakening.geofence."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 获取指定围栏的推送状态
    public func getState(for regionId: String) -> GeofenceState? {
        let key = keyPrefix + regionId
        guard let data = defaults.data(forKey: key) else { return nil }
        return GeofenceState.decode(from: data)
    }

    /// 标记围栏已推送（hasBeenPushed=true, hasExited=false）
    public func markPushed(regionId: String) {
        let state = GeofenceState(hasBeenPushed: true, hasExited: false)
        save(state, for: regionId)
    }

    /// 标记围栏已离开（hasExited=true, 保留 hasBeenPushed 状态）。
    /// 若该围栏从未被推送过，则为无操作。
    public func markExited(regionId: String) {
        guard getState(for: regionId) != nil else { return }
        let state = GeofenceState(hasBeenPushed: true, hasExited: true)
        save(state, for: regionId)
    }

    /// 重置指定围栏的状态（退出围栏重新进入时）
    public func reset(regionId: String) {
        let key = keyPrefix + regionId
        defaults.removeObject(forKey: key)
    }

    /// 原子操作：检查围栏是否已被推送（未离开），若否，则标记为已推送。
    ///
    /// - Returns: `true` 表示成功 claimed（可继续处理），`false` 表示已被 claimed（跳过）。
    /// - 同时返回 `resetByExit` 标志：`true` = 上次离开后重新进入。
    public func claimForProcessing(regionId: String) -> (claimed: Bool, resetByExit: Bool) {
        if let existing = getState(for: regionId) {
            if existing.hasBeenPushed && !existing.hasExited {
                // Already pushed, never exited → skip
                return (false, false)
            }
            // Has exited → reset, allow re-enter
            let resetByExit = existing.hasExited
            let state = GeofenceState(hasBeenPushed: true, hasExited: false)
            save(state, for: regionId)
            return (true, resetByExit)
        }
        // First time → claim it
        let state = GeofenceState(hasBeenPushed: true, hasExited: false)
        save(state, for: regionId)
        return (true, false)
    }

    /// 清除所有围栏状态
    public func clearAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Private

    private func save(_ state: GeofenceState, for regionId: String) {
        let key = keyPrefix + regionId
        guard let data = state.encode() else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Awakening Error

/// AwakeningPipeline 统一错误类型（L1~L4 分级，AGENTS.md §4.4）
public enum AwakeningError: Error, LocalizedError, Sendable, Equatable {
    /// 隐私校验拒绝 — 用户未授权唤醒功能
    case privacyDenied(sourceTypes: [String])
    /// 搜索失败 — 下游 SearchPipeline 错误
    case searchFailed(underlying: Error)
    /// 情绪检测失败 — HealthKit 或情感分析出错
    case emotionDetectionFailed(underlying: Error)
    /// 审计日志写入失败（L1 瞬态，非阻断）
    case auditLogFailed(underlying: Error)

    /// L1~L4 错误分级
    public nonisolated var errorLevel: Int {
        switch self {
        case .privacyDenied:          return 2
        case .searchFailed:           return 1
        case .emotionDetectionFailed: return 1
        case .auditLogFailed:         return 1
        }
    }

    public nonisolated var errorDescription: String? {
        switch self {
        case .privacyDenied:
            return "隐私校验拒绝：用户未授权唤醒功能"
        case .searchFailed(let e):
            return "搜索失败：\(e.localizedDescription)"
        case .emotionDetectionFailed(let e):
            return "情绪检测失败：\(e.localizedDescription)"
        case .auditLogFailed(let e):
            return "审计日志写入失败：\(e.localizedDescription)"
        }
    }

    // Explicit nonisolated Equatable (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor)
    public nonisolated static func == (lhs: AwakeningError, rhs: AwakeningError) -> Bool {
        switch (lhs, rhs) {
        case (.privacyDenied(let a), .privacyDenied(let b)): return a == b
        case (.searchFailed, .searchFailed): return true
        case (.emotionDetectionFailed, .emotionDetectionFailed): return true
        case (.auditLogFailed, .auditLogFailed): return true
        default: return false
        }
    }
}

// MARK: - Awakening Enter Result

/// 地理围栏进入事件的处理结果（AC-1, AC-2, AC-5）
public enum AwakeningEnterResult: Sendable, Equatable {
    /// 已处理 — 触发了唤醒流程
    case processed(card: AwakeningCard)
    /// 已推送过且未离开 — 跳过（AC-2: 永不重复推送）
    case alreadyPushed
    /// 无匹配记忆（AC-3: 匹配度 < 0.7）
    case noMemories
    /// 权限被拒绝（AC-5: 定位关闭时静默禁用）
    case permissionDenied
}

// MARK: - Awakening Card

/// 交互式回忆卡片模型（AC-4, 对应 US-AWK-005）。
///
/// Phase 2 阶段为接口占位 — 卡片 UI 由 Phase 3 实现。
public struct AwakeningCard: Sendable, Equatable {
    /// 卡片唯一标识符
    public nonisolated let cardId: UUID
    /// 关联的记忆 ID 列表
    public nonisolated let memoryIds: [UUID]
    /// 触发类型
    public nonisolated let triggerType: String
    /// 触发的地理围栏 ID
    public nonisolated let regionId: String
    /// 卡片生成时间
    public nonisolated let createdAt: Date

    public nonisolated init(
        cardId: UUID = UUID(),
        memoryIds: [UUID],
        triggerType: String = "geofenceOnly",
        regionId: String,
        createdAt: Date = Date()
    ) {
        self.cardId = cardId
        self.memoryIds = memoryIds
        self.triggerType = triggerType
        self.regionId = regionId
        self.createdAt = createdAt
    }
}

// MARK: - Awakening Audit Metadata

/// 唤醒审计元数据 — 编码为 JSON 存储于 AuditLogEntry.sourceLanguage 字段（AC-6）。
public struct AwakeningAuditMetadata: Sendable, Equatable {
    public nonisolated let triggerType: String
    public nonisolated let memoryIds: [UUID]
    public nonisolated let resetByExit: Bool

    public nonisolated init(
        triggerType: String = "geofenceOnly",
        memoryIds: [UUID],
        resetByExit: Bool
    ) {
        self.triggerType = triggerType
        self.memoryIds = memoryIds
        self.resetByExit = resetByExit
    }

    /// 序列化为 JSON 字符串（使用 JSONSerialization 避免 Codable 的 MainActor 隔离）
    public nonisolated func encode() -> String? {
        let dict: [String: Any] = [
            "triggerType": triggerType,
            "memoryIds": memoryIds.map(\.uuidString),
            "resetByExit": resetByExit
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// 从 JSON 字符串反序列化
    public nonisolated static func decode(from jsonString: String) -> AwakeningAuditMetadata? {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let triggerType = dict["triggerType"] as? String,
              let idStrings = dict["memoryIds"] as? [String],
              let resetByExit = dict["resetByExit"] as? Bool else {
            return nil
        }
        return AwakeningAuditMetadata(
            triggerType: triggerType,
            memoryIds: idStrings.compactMap(UUID.init),
            resetByExit: resetByExit
        )
    }
}

// MARK: - Mood State (US-AWK-003 AC-1~3)

/// 情绪状态枚举（AC-2: positive/negative/neutral 三分类）。
public enum MoodState: String, Sendable, Equatable, CustomStringConvertible {
    case positive
    case negative
    case neutral

    public nonisolated var description: String { rawValue }
}

// MARK: - Emotional Awakening Source (US-AWK-003 AC-1, AC-5)

/// 情绪检测来源（AC-5: source=healthKit|textSentiment）。
public enum EmotionalAwakeningSource: String, Sendable, Equatable {
    case healthKit
    case textSentiment
}

// MARK: - Emotion Cache (US-AWK-003 AC-2b: 24h TTL)

/// 情绪分析缓存（AC-2: 缓存有效期 24 小时）。
///
/// 每天分析一次并缓存结果。`isExpired` 基于 createdAt 与当前时间比较。
public struct EmotionCache: Sendable, Equatable {
    /// 检测到的情绪状态
    public nonisolated let mood: MoodState
    /// 检测来源
    public nonisolated let source: EmotionalAwakeningSource
    /// 缓存创建时间
    public nonisolated let createdAt: Date
    /// 缓存有效期（秒），默认 24 小时 = 86400
    public nonisolated static let ttlSeconds: TimeInterval = 24 * 3600

    public nonisolated init(
        mood: MoodState,
        source: EmotionalAwakeningSource,
        createdAt: Date = Date()
    ) {
        self.mood = mood
        self.source = source
        self.createdAt = createdAt
    }

    /// 缓存是否已过期（AC-2: 有效期为 24 小时，严格过期，≥24h 即为过期）。
    public nonisolated var isExpired: Bool {
        Date().timeIntervalSince(createdAt) >= EmotionCache.ttlSeconds
    }
}

// MARK: - Emotional Awakening Result (US-AWK-003 AC-3)

/// 情绪唤醒处理结果（AC-3: positive→noTrigger, negative/neutral→card）。
public enum EmotionalAwakeningResult: Sendable, Equatable {
    /// 已处理 — 生成了唤醒卡片
    case processed(card: AwakeningCard)
    /// 积极情绪 — 不触发推送（避免过度打扰）
    case noTrigger(mood: MoodState)
    /// 权限被拒绝
    case permissionDenied
}

// MARK: - HealthKit Provider Protocol (US-AWK-003 AC-1)

/// HealthKit 情绪推断提供者协议（AC-1: 心率变异性 → 情绪状态）。
///
/// Phase 2 使用 stub 实现；Phase 3 集成真实 HealthKit。
/// `@unchecked Sendable` 允许测试 stub 持有 mutable state。
public protocol HealthKitProvider: AnyObject, Sendable {
    /// 设备是否支持 HealthKit
    func isHealthDataAvailable() -> Bool
    /// Requests the HealthKit sheet without claiming an observable read grant.
    func requestReadAuthorization() async -> HealthAuthorizationRequestResult
    /// 从 HRV 数据推断情绪状态。返回 nil 表示数据不足/不确定。
    func inferMoodFromHRV() async -> MoodState?
}

// MARK: - Sentiment Provider Protocol (US-AWK-003 AC-2)

/// 情感分析提供者协议（AC-2: 查询字符串 + 感受 → positive/negative/neutral）。
///
/// Phase 2 使用 stub 实现；Phase 3 集成本地情感分类模型（Core ML）。
/// `@unchecked Sendable` 允许测试 stub 持有 mutable state。
public protocol SentimentProvider: AnyObject, Sendable {
    /// 分析文本情感。
    /// - Parameters:
    ///   - queries: 最近 7 天内的查询字符串
    ///   - feelings: 最近 7 天内记录的感受（US-AWK-005）
    /// - Returns: 分类结果，nil 表示文本不足无法判断
    func analyzeSentiment(queries: [String], feelings: [String]) async -> MoodState?
}

// MARK: - Awakening Pipeline

/// 主动唤醒管线 — 地理围栏唤醒（US-AWK-001）。
///
/// 监听 Core Location 地理围栏进入/离开事件，通过 ``SearchPipeline`` 检索
/// 位置关联记忆，匹配度 ≥ 0.7 时生成回忆卡片并推送本地通知。
///
/// AC 覆盖:
/// - AC-1: 仅 ``handleGeofenceEnter(regionId:traceID:)`` 触发唤醒
/// - AC-2: 同一围栏离开重置；未离开则永不重复推送
/// - AC-3: 记忆匹配度 ≥ 0.7 过滤
/// - AC-4: 生成 ``AwakeningCard``（Phase 3 UI 实现）
/// - AC-5: 权限关闭时静默禁用，重开后不立即推送
/// - AC-6: 审计记录 `.contextualAwakening`
///
/// 遵循 AGENTS.md §4.1 Pipeline 契约：actor 声明仅持有不可变 actor 引用,
/// 通过 PrivacyCheckpoint + L1~L4 错误分级保护。
///
/// 情绪唤醒（US-AWK-003）：HealthKit HRV → 情绪推断 → 无数据时文本情感分析（24h 缓存 + 30s 防抖）。
public actor AwakeningPipeline {

    // MARK: - Dependencies

    private let privacyActor: PrivacyActor
    private let searchPipeline: SearchPipeline
    private let stateStore: GeofenceStateStore
    private let healthKitProvider: HealthKitProvider?
    private let sentimentProvider: SentimentProvider?
    /// 3F.8: 系统适配器 — 定位服务（地理围栏事件流）
    private let locationProvider: (any LocationProviding)?
    /// 3F.8: 本地通知调度（US-AWK-005 投递；与响应路由分离）
    private let notificationScheduler: (any NotificationScheduling)?
    /// 3F.8: 唤醒卡片持久化存储（ADR-012 决策-5）
    private let cardRepository: AwakeningCardRepositoryActor?

    // MARK: - Emotion State (US-AWK-003)

    /// 情绪分析缓存（AC-2: 24h TTL）
    private var emotionCache: EmotionCache?
    /// 防抖 Task — 每次新请求取消旧 Task 并启动新的 30s 延迟 Task
    private var debouncedRefreshTask: Task<Void, Never>?
    /// 待分析的最新查询（防抖累积）
    private var pendingEmotionQueries: [String] = []
    /// 待分析的最新感受（防抖累积）
    private var pendingEmotionFeelings: [String] = []

    // MARK: - Configuration

    /// 记忆匹配度阈值（AC-3: 推送内容与该地理位置关联的记忆匹配度 ≥ 0.7）
    private let matchThreshold: Float = 0.7

    /// 搜索返回的记忆数量
    private let searchK: Int = 10

    /// 防抖延迟（AC-2: 30 秒）
    private let debounceDelayNanos: UInt64 = 30_000_000_000

    // MARK: - Initialization

    public init(
        privacyActor: PrivacyActor = .shared,
        searchPipeline: SearchPipeline,
        stateStore: GeofenceStateStore = GeofenceStateStore(),
        healthKitProvider: HealthKitProvider? = nil,
        sentimentProvider: SentimentProvider? = nil,
        locationProvider: (any LocationProviding)? = nil,
        notificationScheduler: (any NotificationScheduling)? = nil,
        cardRepository: AwakeningCardRepositoryActor? = nil
    ) {
        self.privacyActor = privacyActor
        self.searchPipeline = searchPipeline
        self.stateStore = stateStore
        self.healthKitProvider = healthKitProvider
        self.sentimentProvider = sentimentProvider
        self.locationProvider = locationProvider
        self.notificationScheduler = notificationScheduler
        self.cardRepository = cardRepository
    }

    // MARK: - Public API

    /// 处理地理围栏进入事件（AC-1: 触发条件仅为 didEnter）。
    ///
    /// - Parameters:
    ///   - regionId: 地理围栏标识符（CLRegion.identifier）
    ///   - traceID: 审计追溯 ID
    /// - Returns: ``AwakeningEnterResult`` 表示处理结果
    public func handleGeofenceEnter(
        regionId: String,
        traceID: String = UUID().uuidString
    ) async -> AwakeningEnterResult {
        // Step 1: PrivacyCheckpoint (R-006) — must run FIRST, before any state read
        let checkpoint = await privacyActor.validate(
            operation: .awakening,
            traceID: traceID,
            sourceTypes: ["geofence"]
        )
        guard checkpoint.isAllowed else {
            return .permissionDenied
        }

        // Step 2: Atomically claim the geofence (AC-2)
        // claimForProcessing checks + marks pushed in one actor-isolated operation,
        // preventing race conditions on concurrent enters for the same region.
        let claim = await stateStore.claimForProcessing(regionId: regionId)
        guard claim.claimed else {
            return .alreadyPushed
        }
        let resetByExit = claim.resetByExit

        // Step 3: Search for location-associated memories (AC-3)
        // Use regionId as query text for semantic search
        let searchResults: [SearchResultItem]
        do {
            searchResults = try await searchPipeline.search(
                query: regionId,
                k: searchK,
                filter: nil,
                traceID: traceID
            )
        } catch {
            // Search failed — L1 transient, audit and skip
            await writeAwakeningAudit(
                traceID: traceID,
                regionId: regionId,
                memoryIds: [],
                resetByExit: resetByExit,
                success: false,
                policyVersion: checkpoint.policyVersion
            )
            return .noMemories
        }

        // Step 4: Filter by threshold ≥ 0.7 (AC-3)
        let matching = filterByThreshold(searchResults, threshold: matchThreshold)
        guard !matching.isEmpty else {
            // Audit: no matching memories (AC-6)
            await writeAwakeningAudit(
                traceID: traceID,
                regionId: regionId,
                memoryIds: [],
                resetByExit: resetByExit,
                success: true,
                policyVersion: checkpoint.policyVersion
            )

            return .noMemories
        }

        // Step 5: Generate card (AC-4)
        let card = generateCard(for: matching, regionId: regionId)

        // Step 5.5: 3F.8 — 持久化卡片 + 调度通知（best-effort，失败不阻断唤醒返回）
        await persistCard(card)
        await scheduleCardNotification(card)

        // Step 6: Audit (AC-6)
        let memoryIds = matching.map(\.id)
        await writeAwakeningAudit(
            traceID: traceID,
            regionId: regionId,
            memoryIds: memoryIds,
            resetByExit: resetByExit,
            success: true,
            policyVersion: checkpoint.policyVersion
        )

        return .processed(card: card)
    }

    /// 处理地理围栏离开事件（AC-2: 标记已离开，允许下次进入时重新推送）。
    ///
    /// - Parameter regionId: 地理围栏标识符
    /// - Returns: `true` 表示成功标记
    @discardableResult
    public func handleGeofenceExit(regionId: String) async -> Bool {
        await stateStore.markExited(regionId: regionId)
        return true
    }

    // MARK: - Filtering (AC-3)

    /// 按余弦相似度阈值过滤搜索结果（AC-3: 匹配度 ≥ 0.7）。
    ///
    /// - Parameters:
    ///   - items: 搜索结果列表
    ///   - threshold: 最小余弦相似度（默认 0.7）
    /// - Returns: 符合阈值的结果列表
    public nonisolated func filterByThreshold(
        _ items: [SearchResultItem],
        threshold: Float = 0.7
    ) -> [SearchResultItem] {
        items.filter { $0.cosineSimilarity >= threshold }
    }

    // MARK: - Card Generation (AC-4)

    /// 生成交互式回忆卡片（AC-4, Phase 2 接口占位）。
    ///
    /// Phase 3 将实现完整卡片 UI（US-AWK-005）。
    public nonisolated func generateCard(
        for memories: [SearchResultItem],
        regionId: String
    ) -> AwakeningCard {
        AwakeningCard(
            cardId: UUID(),
            memoryIds: memories.map(\.id),
            triggerType: "geofenceOnly",
            regionId: regionId,
            createdAt: Date()
        )
    }

    // MARK: - Audit (AC-6)

    /// 写入唤醒审计日志（AC-6: 审计记录 .contextualAwakening）。
    ///
    /// 审计元数据（triggerType, memoryIds, resetByExit）编码为 JSON
    /// 存储于 `sourceLanguage` 字段。
    public func writeAwakeningAudit(
        traceID: String,
        regionId: String,
        memoryIds: [UUID],
        resetByExit: Bool,
        success: Bool,
        policyVersion: Int
    ) async {
        let metadata = AwakeningAuditMetadata(
            triggerType: "geofenceOnly",
            memoryIds: memoryIds,
            resetByExit: resetByExit
        )
        let metadataJSON = metadata.encode() ?? "{}"

        try? await privacyActor.writeAuditLog(
            eventType: .contextualAwakening,
            traceID: traceID,
            policyVersion: policyVersion,
            success: success,
            sourceType: "geofence",
            affectedCount: memoryIds.count,
            sourceLanguage: metadataJSON
        )
    }

    /// 解析唤醒审计元数据（从 sourceLanguage JSON 字段反序列化）。
    public nonisolated func parseAwakeningMetadata(from jsonString: String) -> AwakeningAuditMetadata? {
        return AwakeningAuditMetadata.decode(from: jsonString)
    }

    // =========================================================================
    // MARK: - Card Persistence & Notification (3F.8, ADR-012 决策-5/3)
    // =========================================================================

    /// 持久化唤醒卡片（ADR-012 决策-5: 卡片持久化 + 重启去重）。
    ///
    /// best-effort：cardRepository 未注入或写入失败时静默跳过（不阻断唤醒返回）。
    public func persistCard(_ card: AwakeningCard) async {
        guard let cardRepository else { return }
        try? await cardRepository.save(card)
    }

    /// 调度本地通知（US-AWK-005 投递；与响应路由分离 — ADR-012 决策-3）。
    ///
    /// best-effort：notificationScheduler 未注入或通知权限 denied 时静默跳过。
    /// 通知内容最小化（决策-7）：标题 + 温和正文 + memoryId（路由用），不含原文。
    public func scheduleCardNotification(_ card: AwakeningCard) async {
        guard let notificationScheduler else { return }
        // DEF-60-001 (3F.10): notification bodies resolve from the String Catalog for the
        // user's preferred language (AGENTS.md §6.4 degradation/prompt copy contract).
        let locale = Locale(identifier: (await privacyActor.getPolicy()).preferredLanguage)
        let body: String
        switch card.triggerType {
        case "geofenceOnly":
            body = String(format: EchoLocalization.localized("A memory from %@", locale: locale), card.regionId)
        case "emotionNegative":
            body = EchoLocalization.localized("A bright moment from the past", locale: locale)
        case "emotionNeutral":
            body = EchoLocalization.localized("A quiet moment to reflect", locale: locale)
        case "anniversary":
            body = EchoLocalization.localized("Memories from years past on this day", locale: locale)
        default:
            body = EchoLocalization.localized("A memory surfaced for you", locale: locale)
        }
        let content = EchoNotificationContent(
            title: EchoLocalization.localized("Echo Memory", locale: locale),
            body: body,
            memoryId: card.memoryIds.first,
            triggerType: card.triggerType
        )
        _ = await notificationScheduler.schedule(content, at: Date().addingTimeInterval(1))
    }

    // =========================================================================
    // MARK: - Date / Anniversary Awakening (US-AWK-002, ADR-012 决策-1)
    // =========================================================================

    /// 处理日期/纪念日唤醒（US-AWK-002 AC-1/AC-3/AC-4）。
    ///
    /// ADR-012 决策-1：放弃精确 9:00 保证，采用 best-effort 窗口 — 由调用方在
    /// 系统允许的最早可用机会触发本方法；无匹配记忆时不推送（AC-4）。
    ///
    /// - Parameters:
    ///   - dateMonthDay: 检查的月/日（如 "0607" 表示 6 月 7 日）；默认当前日期
    ///   - matchedMemoryIDs: 匹配 dateMonthDay 的记忆 ID 列表（由调用方按日期检索）
    ///   - traceID: 审计追溯 ID
    /// - Returns: 处理结果（processed 含卡片 / noMemories 不推送）
    public func handleAnniversaryAwakening(
        dateMonthDay: String? = nil,
        matchedMemoryIDs: [UUID],
        traceID: String = UUID().uuidString
    ) async -> AwakeningEnterResult {
        // Step 1: PrivacyCheckpoint (R-006)
        let checkpoint = await privacyActor.validate(
            operation: .awakening,
            traceID: traceID,
            sourceTypes: ["anniversary"]
        )
        guard checkpoint.isAllowed else {
            return .permissionDenied
        }

        // Step 2: AC-4 — 无匹配记忆时不推送
        guard !matchedMemoryIDs.isEmpty else {
            await writeDateAwakeningAudit(
                traceID: traceID,
                dateMonthDay: dateMonthDay ?? Self.currentMonthDay(),
                yearsAgo: [],
                memoryIDs: [],
                policyVersion: checkpoint.policyVersion,
                success: true
            )
            return .noMemories
        }

        // Step 3: 生成卡片（AC-3）
        let card = AwakeningCard(
            cardId: UUID(),
            memoryIds: matchedMemoryIDs,
            triggerType: "anniversary",
            regionId: dateMonthDay ?? Self.currentMonthDay(),
            createdAt: Date()
        )

        // Step 4: 3F.8 — 持久化 + 调度通知（best-effort）
        await persistCard(card)
        await scheduleCardNotification(card)

        // Step 5: AC-5 审计（.dateAwakening）
        await writeDateAwakeningAudit(
            traceID: traceID,
            dateMonthDay: card.regionId,
            yearsAgo: [1, 3, 5],
            memoryIDs: matchedMemoryIDs,
            policyVersion: checkpoint.policyVersion,
            success: true
        )

        return .processed(card: card)
    }

    /// 写入日期唤醒审计（US-AWK-002 AC-5: .dateAwakening, triggerType=anniversary, yearsAgo）。
    public func writeDateAwakeningAudit(
        traceID: String,
        dateMonthDay: String,
        yearsAgo: [Int],
        memoryIDs: [UUID],
        policyVersion: Int,
        success: Bool
    ) async {
        let metadataDict: [String: Any] = [
            "triggerType": "anniversary",
            "dateMonthDay": dateMonthDay,
            "yearsAgo": yearsAgo,
            "memoryIds": memoryIDs.map(\.uuidString)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: metadataDict),
              let json = String(data: data, encoding: .utf8) else { return }

        try? await privacyActor.writeAuditLog(
            eventType: .dateAwakening,
            traceID: traceID,
            policyVersion: policyVersion,
            success: success,
            sourceType: "anniversary",
            affectedCount: memoryIDs.count,
            sourceLanguage: json
        )
    }

    /// 当前月/日（MMdd 格式，如 0607），用于 anniversary 默认检查。
    public nonisolated static func currentMonthDay(
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> String {
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)
        return String(format: "%02d%02d", month, day)
    }

    // =========================================================================
    // MARK: - Emotional Awakening (US-AWK-003 AC-1~5)
    // =========================================================================

    // MARK: AC-1+2: Emotion Detection (HealthKit first, text sentiment fallback)

    /// 检测当前情绪状态（AC-1 优先 HealthKit，AC-2 降级文本情感分析）。
    ///
    /// - Parameters:
    ///   - healthKitAvailable: 是否优先 HealthKit
    ///   - queries: 近 7 天查询字符串（HealthKit 无数据时使用）
    ///   - feelings: 近 7 天感受（HealthKit 无数据时使用）
    ///   - traceID: 审计追溯 ID
    /// - Returns: 检测到的情绪状态，nil 表示无法检测
    public func detectEmotion(
        healthKitAvailable: Bool,
        queries: [String] = [],
        feelings: [String] = [],
        traceID: String = UUID().uuidString
    ) async -> MoodState? {
        // AC-1: Try HealthKit first
        if healthKitAvailable, let hk = healthKitProvider {
            if await hk.isHealthDataAvailable() {
                if let mood = await hk.inferMoodFromHRV() {
                    let cache = EmotionCache(mood: mood, source: .healthKit)
                    await setEmotionCache(cache)
                    return mood
                }
            }
        }

        // AC-2: Fallback to text sentiment with cache
        // Check cache first (24h TTL)
        if let cache = await getCachedEmotionCache(), !cache.isExpired {
            return cache.mood
        }

        // Analyze text sentiment
        if !queries.isEmpty || !feelings.isEmpty {
            return await analyzeTextSentiment(queries: queries, feelings: feelings)
        }

        return nil
    }

    /// 使用文本情感分析模型推断情绪（AC-2: 7 天窗口内的查询+感受）。
    public func analyzeTextSentiment(
        queries: [String],
        feelings: [String]
    ) async -> MoodState? {
        guard let provider = sentimentProvider else { return nil }
        guard !queries.isEmpty || !feelings.isEmpty else { return nil }

        if let mood = await provider.analyzeSentiment(queries: queries, feelings: feelings) {
            let cache = EmotionCache(mood: mood, source: .textSentiment)
            await setEmotionCache(cache)
            return mood
        }
        return nil
    }

    // MARK: AC-2b: Emotion Cache (24h TTL)

    /// 获取缓存情绪（不检查是否过期）。
    public func getCachedMood() async -> MoodState? {
        return emotionCache?.mood
    }

    /// 获取完整缓存对象。
    public func getCachedEmotionCache() async -> EmotionCache? {
        return emotionCache
    }

    /// 设置情绪缓存（testable）。
    public func setEmotionCache(_ cache: EmotionCache?) async {
        self.emotionCache = cache
    }

    // MARK: AC-2c: Debounce (30s)

    /// 请求刷新情绪缓存（AC-2: 新增查询/感受触发异步更新，30s 防抖）。
    ///
    /// 多次调用在 30s 内会合并为一次分析。
    public func requestEmotionCacheRefresh(queries: [String], feelings: [String]) async {
        pendingEmotionQueries = queries
        pendingEmotionFeelings = feelings

        // Cancel existing debounce task
        debouncedRefreshTask?.cancel()

        // Start new debounced task (30s delay)
        debouncedRefreshTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.debounceDelayNanos
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            let qs = await self.pendingEmotionQueries
            let fs = await self.pendingEmotionFeelings
            _ = await self.analyzeTextSentiment(queries: qs, feelings: fs)
        }
    }

    /// 立即执行防抖队列（测试辅助 — 绕过 30s 延迟）。
    public func flushDebouncedEmotionRefresh() async {
        debouncedRefreshTask?.cancel()
        let qs = pendingEmotionQueries
        let fs = pendingEmotionFeelings
        _ = await analyzeTextSentiment(queries: qs, feelings: fs)
    }

    // MARK: AC-3: Mood → Search Tag Mapping

    /// 根据情绪状态返回检索查询列表（AC-3）。
    ///
    /// - negative → 检索 `positiveEmotion` 标签记忆
    /// - neutral → 检索 `reflective` / `introspective` 标签记忆
    /// - positive → 不推送（返回空列表）
    public func searchQueriesForMood(_ mood: MoodState) async -> [String] {
        switch mood {
        case .negative:
            return [
                "happy memories joyful celebration",
                "best moments favorite times",
                "cherished memories warmth comfort"
            ]
        case .neutral:
            return [
                "reflective thoughtful introspective",
                "quiet moments peaceful contemplation",
                "meaningful experience personal growth"
            ]
        case .positive:
            return []  // AC-3: 不触发额外推送
        }
    }

    // MARK: AC-4: Emotion Card Generation

    /// 生成情绪唤醒回忆卡片（AC-4: 文案温和不评判）。
    public func generateEmotionCard(
        mood: MoodState,
        memoryIds: [UUID],
        triggerType: String
    ) async -> AwakeningCard {
        AwakeningCard(
            cardId: UUID(),
            memoryIds: memoryIds,
            triggerType: triggerType,
            regionId: "emotion",
            createdAt: Date()
        )
    }

    /// 获取情绪卡片文案（AC-4: 温和不评判）。
    /// 🔮 Phase 3: localize via UserPolicy.preferredLanguage (zh-Hans/en-US).
    public func emotionCardCopy(for mood: MoodState) async -> String {
        switch mood {
        case .negative:
            return "Here are some bright moments from the past — you've been through a lot, and these memories are here for you."
        case .neutral:
            return "A quiet moment to reflect on where you've been and what matters."
        case .positive:
            return ""  // AC-3: 不推送
        }
    }

    // MARK: AC-5: Emotional Audit

    /// 写入情绪唤醒审计日志（AC-5: .emotionalAwakening + detectedMood + source + cachedResultUsed）。
    public func writeEmotionalAudit(
        traceID: String,
        mood: MoodState,
        source: EmotionalAwakeningSource,
        cachedResultUsed: Bool,
        memoryIds: [UUID],
        policyVersion: Int,
        success: Bool
    ) async {
        let metadataDict: [String: Any] = [
            "detectedMood": mood.rawValue,
            "source": source.rawValue,
            "cachedResultUsed": cachedResultUsed,
            "triggerType": "emotion",
            "memoryIds": memoryIds.map(\.uuidString)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: metadataDict),
              let json = String(data: data, encoding: .utf8) else { return }

        try? await privacyActor.writeAuditLog(
            eventType: .emotionalAwakening,
            traceID: traceID,
            policyVersion: policyVersion,
            success: success,
            sourceType: source.rawValue,
            affectedCount: memoryIds.count,
            sourceLanguage: json
        )
    }

    // MARK: Handle Emotional Awakening (Orchestration)

    /// 处理情绪唤醒（AC-1~5 全流程编排）。
    ///
    /// - Parameters:
    ///   - queries: 近 7 天查询字符串
    ///   - feelings: 近 7 天感受
    ///   - traceID: 审计追溯 ID
    /// - Returns: 处理结果
    public func handleEmotionalAwakening(
        queries: [String] = [],
        feelings: [String] = [],
        traceID: String = UUID().uuidString
    ) async -> EmotionalAwakeningResult {
        // Step 1: PrivacyCheckpoint (R-006)
        let checkpoint = await privacyActor.validate(
            operation: .awakening,
            traceID: traceID,
            sourceTypes: ["healthKit", "sentiment"]
        )
        guard checkpoint.isAllowed else {
            return .permissionDenied
        }

        // Step 2: Check cache (AC-2b)
        var cachedResultUsed = false
        let mood: MoodState
        if let cache = await getCachedEmotionCache(), !cache.isExpired {
            mood = cache.mood
            cachedResultUsed = true
        } else {
            // Step 3: Detect emotion (AC-1 + AC-2)
            let hkAvailable = await healthKitProvider?.isHealthDataAvailable() ?? false
            guard let detected = await detectEmotion(
                healthKitAvailable: hkAvailable,
                queries: queries,
                feelings: feelings,
                traceID: traceID
            ) else {
                // No emotion detected → audit and return
                await writeEmotionalAudit(
                    traceID: traceID,
                    mood: .neutral,
                    source: .textSentiment,
                    cachedResultUsed: false,
                    memoryIds: [],
                    policyVersion: checkpoint.policyVersion,
                    success: true
                )
                return .noTrigger(mood: .neutral)
            }
            mood = detected
        }

        // Step 4: AC-3 — positive → no push
        if mood == .positive {
            let source = await getEmotionSource() ?? .textSentiment
            await writeEmotionalAudit(
                traceID: traceID,
                mood: mood,
                source: source,
                cachedResultUsed: cachedResultUsed,
                memoryIds: [],
                policyVersion: checkpoint.policyVersion,
                success: true
            )
            return .noTrigger(mood: mood)
        }

        // Step 5: Search by mood tag (AC-3)
        // L1 transient: retry 3x per query before giving up on that query
        let queriesForSearch = await searchQueriesForMood(mood)
        var matchedMemories: [SearchResultItem] = []
        let maxRetries = 3

        for query in queriesForSearch {
            var retriesRemaining = maxRetries
            var lastError: Error?

            while retriesRemaining > 0 {
                do {
                    let results = try await searchPipeline.search(
                        query: query,
                        k: searchK,
                        filter: nil,
                        traceID: traceID
                    )
                    // Filter by threshold
                    let filtered = filterByThreshold(results, threshold: matchThreshold)
                    matchedMemories.append(contentsOf: filtered)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    retriesRemaining -= 1
                    if retriesRemaining > 0 {
                        // L1: exponential backoff (1s/2s/4s)
                        let delayNanos = UInt64(pow(2.0, Double(maxRetries - retriesRemaining - 1)) * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: delayNanos)
                    }
                }
            }

            // L1→L2 escalation: all retries exhausted, log failure
            if let error = lastError {
                try? await privacyActor.writeAuditLog(
                    eventType: .emotionalAwakening,
                    traceID: traceID,
                    policyVersion: checkpoint.policyVersion,
                    success: false,
                    sourceType: "sentiment",
                    affectedCount: 0,
                    sourceLanguage: "{\"error\":\"searchExhaustedRetries\",\"query\":\"\(query)\"}"
                )
                _ = error  // Silenced but audit-logged — L2 recovery via user retry
            }
        }

        // Deduplicate by ID
        var seen: Set<UUID> = []
        matchedMemories = matchedMemories.filter { seen.insert($0.id).inserted }

        // Step 6: Generate card (AC-4)
        let memoryIds = matchedMemories.map(\.id)
        var card: AwakeningCard?
        if !memoryIds.isEmpty {
            let triggerType = mood == .negative ? "emotionNegative" : "emotionNeutral"
            card = await generateEmotionCard(mood: mood, memoryIds: memoryIds, triggerType: triggerType)
        }

        // Step 7: Audit (AC-5)
        let source = await getEmotionSource() ?? .textSentiment
        await writeEmotionalAudit(
            traceID: traceID,
            mood: mood,
            source: source,
            cachedResultUsed: cachedResultUsed,
            memoryIds: memoryIds,
            policyVersion: checkpoint.policyVersion,
            success: true
        )

        // Step 8: 3F.8 — 卡片持久化 + 通知调度（best-effort，失败不阻断唤醒返回）
        if let card {
            await persistCard(card)
            await scheduleCardNotification(card)
        }

        if let card {
            return .processed(card: card)
        } else {
            return .noTrigger(mood: mood)
        }
    }

    // MARK: - Private Helpers (Emotion)

    private func getEmotionSource() async -> EmotionalAwakeningSource? {
        return emotionCache?.source
    }
}
