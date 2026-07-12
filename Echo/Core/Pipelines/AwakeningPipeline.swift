// ==========================================
// 文件: AwakeningPipeline.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-AWK-001 (地理围栏情境记忆唤醒)
//            docs/02-architecture/数据流全链路技术说明文档.md §5.1 (地理围栏唤醒)
//            docs/02-architecture/架构设计文档.md §2.1 (AwakeningPipeline)
// 任务: 2.11 - AwakeningPipeline：地理围栏（US-AWK-001）
// AC 覆盖: US-AWK-001 AC-1 ✅ (仅didEnter触发), AC-2 ✅ (离开重置, 永不重复推送),
//          AC-3 🔮 Phase 3 (余弦≥0.7过滤已实现, GeoFilter依赖SearchPipeline Phase 3), AC-4 ✅ (回忆卡片生成接口),
//          AC-5 ✅ (定位权限关闭静默禁用), AC-6 ✅ (审计记录.contextualAwakening)
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
    /// 审计日志写入失败（L1 瞬态，非阻断）
    case auditLogFailed(underlying: Error)

    /// L1~L4 错误分级
    public nonisolated var errorLevel: Int {
        switch self {
        case .privacyDenied:  return 2
        case .searchFailed:   return 1
        case .auditLogFailed: return 1
        }
    }

    public nonisolated var errorDescription: String? {
        switch self {
        case .privacyDenied:
            return "隐私校验拒绝：用户未授权唤醒功能"
        case .searchFailed(let e):
            return "搜索失败：\(e.localizedDescription)"
        case .auditLogFailed(let e):
            return "审计日志写入失败：\(e.localizedDescription)"
        }
    }

    // Explicit nonisolated Equatable (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor)
    public nonisolated static func == (lhs: AwakeningError, rhs: AwakeningError) -> Bool {
        switch (lhs, rhs) {
        case (.privacyDenied(let a), .privacyDenied(let b)): return a == b
        case (.searchFailed, .searchFailed): return true
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
public actor AwakeningPipeline {

    // MARK: - Dependencies

    private let privacyActor: PrivacyActor
    private let searchPipeline: SearchPipeline
    private let stateStore: GeofenceStateStore

    // MARK: - Configuration

    /// 记忆匹配度阈值（AC-3: 推送内容与该地理位置关联的记忆匹配度 ≥ 0.7）
    private let matchThreshold: Float = 0.7

    /// 搜索返回的记忆数量
    private let searchK: Int = 10

    // MARK: - Initialization

    public init(
        privacyActor: PrivacyActor = .shared,
        searchPipeline: SearchPipeline,
        stateStore: GeofenceStateStore = GeofenceStateStore()
    ) {
        self.privacyActor = privacyActor
        self.searchPipeline = searchPipeline
        self.stateStore = stateStore
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
}
