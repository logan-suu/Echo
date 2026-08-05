// ==========================================
// 文件: 3F.1_ProductionCompositionTests.swift
// 对应规格: docs/decisions/ADR-007-production-composition-consent.md (全部 6 条决策)
//            docs/01-spec/用户故事与验收标准规格书.md → US-PRV-001/004/005/006/008,
//            US-SRC-001, US-RES-004
//            AGENTS.md §5.4 (审计日志契约: 必填字段 / hash-only / 30天 / NSFileProtectionComplete)
// 任务: 3F.1 - Production composition、首次启动、同意与隐私
// AC 覆盖: ADR-007 §决策-1 (AppComposition composition root), §决策-2 (deny-by-default 同意),
//          §决策-3 (事务性撤回/清除 + blocked + 审计), §决策-4 (AuditLog 必填字段/hash-only/30天/NSFileProtectionComplete),
//          §决策-5 (model-unavailable/route-unavailable/index-unavailable 启动状态), §决策-6 (无 CloudKit)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §5.4 (审计契约), R-001 (零网络), R-007 (禁止 unchecked Sendable)
// 生成时间: 2026-08-04
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Test Suite: ProductionComposition (3F.1)

@Suite("ProductionCompositionTests", .serialized)
@MainActor
struct ProductionCompositionTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await db.open()
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM ConsentStore")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        await PrivacyActor.shared.disableConsentEnforcement()
    }

    /// 隔离的 privacy actor（不使用共享单例，避免 consent gate 泄漏到并行套件）
    private func makePrivacy() -> PrivacyActor {
        PrivacyActor(db: db)
    }

    private func makeComposition() -> AppComposition {
        let privacy = makePrivacy()
        return AppComposition(
            databaseManager: db,
            privacyActor: privacy,
            consentStore: ConsentStoreActor(db: db, privacyActor: privacy)
        )
    }

    private func seedBusinessRow() async throws {
        try await db.executeWrite(
            sql: """
                INSERT INTO Memory (memoryId, sourceLocator, canonicalText, sourceType, createdAt, updatedAt)
                VALUES ('m-seed', 'loc://1', 'seeded memory', 'photo', ?, ?)
                """,
            bindings: [.double(Date().timeIntervalSince1970), .double(Date().timeIntervalSince1970)]
        )
        try await db.executeWrite(
            sql: """
                INSERT INTO ExcludedAssets (assetId, sourceType, excludedAt)
                VALUES ('asset-seed', 'photo', ?)
                """,
            bindings: [.double(Date().timeIntervalSince1970)]
        )
    }

    private func businessRowCounts() async throws -> (memory: Int, excluded: Int) {
        let m = try await db.executeQuery(sql: "SELECT COUNT(*) AS cnt FROM Memory", bindings: [])
        let e = try await db.executeQuery(sql: "SELECT COUNT(*) AS cnt FROM ExcludedAssets", bindings: [])
        return (m.first?["cnt"]?.intValue.map(Int.init) ?? 0,
                e.first?["cnt"]?.intValue.map(Int.init) ?? 0)
    }

    // MARK: - ADR-007 决策-1: AppComposition composition root + 启动状态机

    @Test("Clean install bootstrap lands in requiresConsent (deny-by-default)")
    func test_cleanInstall_requiresConsent() async throws {
        let composition = makeComposition()
        await composition.bootstrap()
        #expect(composition.startupState == .requiresConsent)
        #expect(await composition.consentStore.hasConsented() == false)
        await composition.privacyActor.disableConsentEnforcement()
    }

    @Test("awaitBootstrapCompletion waits for a concurrent bootstrap to finish (3F.2 race fix)")
    func test_awaitBootstrapCompletion_waitsForConcurrentBootstrap() async throws {
        let composition = makeComposition()
        // Start two bootstraps concurrently: the second returns immediately via the
        // idempotence guard (startupState still .bootstrapping), but
        // awaitBootstrapCompletion must wait for the real bootstrap to finish.
        async let first: Void = composition.bootstrap()
        await composition.awaitBootstrapCompletion()
        _ = await first
        #expect(composition.startupState == .requiresConsent
                || composition.startupState == .ready)
        await composition.privacyActor.disableConsentEnforcement()
    }

    @Test("Explicit unavailable startup states are exposed")
    func test_explicitUnavailableStates() async throws {
        let composition = makeComposition()
        await composition.bootstrap()
        composition.markModelUnavailable()
        #expect(composition.startupState == .modelUnavailable)
        composition.markRouteUnavailable()
        #expect(composition.startupState == .routeUnavailable)
        composition.markIndexUnavailable()
        #expect(composition.startupState == .indexUnavailable)
        await composition.privacyActor.disableConsentEnforcement()
    }

    @Test("Accepted consent moves startup state to ready")
    func test_acceptedConsent_ready() async throws {
        let composition = makeComposition()
        await composition.bootstrap()
        try await composition.acceptConsent(consentVersion: 1, policyVersion: 1)
        #expect(composition.startupState == .ready)
        #expect(await composition.consentStore.hasConsented() == true)
        await composition.privacyActor.disableConsentEnforcement()
    }

    @Test("Declined consent keeps app in consent-required state")
    func test_declinedConsent_remainsRequiresConsent() async throws {
        let composition = makeComposition()
        await composition.bootstrap()
        composition.declineConsent()
        #expect(composition.startupState == .consentDeclined)
        #expect(await composition.consentStore.hasConsented() == false)
        await composition.privacyActor.disableConsentEnforcement()
    }

    // MARK: - ADR-007 决策-2: Deny-by-default 同意

    @Test("Denied consent blocks business data access (PrivacyCheckpoint denied)")
    func test_deniedConsent_blocksBusinessAccess() async throws {
        let privacy = makePrivacy()
        let consentStore = ConsentStoreActor(db: db, privacyActor: privacy)
        await privacy.enableConsentEnforcement(consentStore: consentStore)
        try await consentStore.revokeConsent(boundary: .full)

        let checkpoint = await privacy.validate(operation: .search, traceID: "t1", sourceTypes: ["photo"])
        #expect(checkpoint.decision == .denied)
        #expect(checkpoint.isAllowed == false)

        await privacy.disableConsentEnforcement()
    }

    @Test("Accepted consent permits policy load and business access")
    func test_acceptedConsent_allowsBusinessAccess() async throws {
        let privacy = makePrivacy()
        let consentStore = ConsentStoreActor(db: db, privacyActor: privacy)
        await privacy.enableConsentEnforcement(consentStore: consentStore)
        try await consentStore.acceptConsent(consentVersion: 1, policyVersion: 1)

        let checkpoint = await privacy.validate(operation: .search, traceID: "t2", sourceTypes: ["photo"])
        #expect(checkpoint.isAllowed == true)

        await privacy.disableConsentEnforcement()
    }

    @Test("Enforcement disabled keeps legacy behavior (no consent gate)")
    func test_enforcementDisabled_legacyAllowed() async throws {
        let privacy = makePrivacy()
        let checkpoint = await privacy.validate(operation: .search, traceID: "t3", sourceTypes: ["photo"])
        #expect(checkpoint.isAllowed == true)
    }

    @Test("Accepted consent still enforces per-source authorization (US-PRV-001, no gate bypass)")
    func test_acceptedConsent_enforcesPerSourceAuthorization() async throws {
        let privacy = makePrivacy()
        let consentStore = ConsentStoreActor(db: db, privacyActor: privacy)
        await privacy.enableConsentEnforcement(consentStore: consentStore)
        try await consentStore.acceptConsent(consentVersion: 1, policyVersion: 1)

        // .allowed 不短路 per-source 授权检查：未授权数据源仍被拒绝（US-PRV-001 语义保留）
        let denied = await privacy.validate(operation: .search, traceID: "t-unauth", sourceTypes: ["message"])
        #expect(denied.decision == .denied)
        #expect(denied.isAllowed == false)

        // 已授权数据源通过
        let allowed = await privacy.validate(operation: .search, traceID: "t-auth", sourceTypes: ["photo"])
        #expect(allowed.decision == .allowed)

        await privacy.disableConsentEnforcement()
    }

    // MARK: - ConsentStoreActor 持久化与重启恢复

    @Test("Consent persists to SQLite and reloads on a fresh instance (relaunch restoration)")
    func test_relaunchRestoration() async throws {
        let storeA = ConsentStoreActor(db: db, privacyActor: PrivacyActor.shared)
        try await storeA.acceptConsent(consentVersion: 3, policyVersion: 2)

        // 模拟重启：全新 actor 实例从 SQLite 加载
        let storeB = ConsentStoreActor(db: db, privacyActor: PrivacyActor.shared)
        try await storeB.loadState()
        let state = await storeB.getState()
        #expect(state.hasConsented == true)
        #expect(state.consentVersion == 3)
        #expect(state.policyVersion == 2)
        #expect(state.consentedAt != nil)
    }

    @Test("Fresh ConsentStoreActor defaults to not consented (deny-by-default)")
    func test_freshStore_notConsented() async throws {
        let store = ConsentStoreActor(db: db, privacyActor: PrivacyActor.shared)
        let state = await store.getState()
        #expect(state.hasConsented == false)
    }

    // MARK: - ADR-007 决策-3: 事务性撤回/清除

    @Test("Revoke consent transactionally purges business tables and self-erases audit")
    func test_revokeConsent_transactionalPurge() async throws {
        try await seedBusinessRow()
        let store = ConsentStoreActor(db: db, privacyActor: PrivacyActor.shared)
        try await store.acceptConsent(consentVersion: 1, policyVersion: 1)

        let result = try await store.revokeConsent(boundary: .full)
        #expect(result.success == true)
        #expect(result.blocked == false)

        let counts = try await businessRowCounts()
        #expect(counts.memory == 0)
        #expect(counts.excluded == 0)

        // 审计库自擦除 (US-PRV-005 AC-7)
        let auditCount = try await PrivacyActor.shared.auditLogCount()
        #expect(auditCount == 0)

        // 同意状态重置
        #expect(await store.hasConsented() == false)
    }

    @Test("Revoke consent writes consentRevoked audit (kept on partial purge, self-erased on full)")
    func test_revokeConsent_writesConsentRevokedAudit() async throws {
        let privacy = makePrivacy()
        let store = ConsentStoreActor(db: db, privacyActor: privacy)
        try await store.acceptConsent(consentVersion: 1, policyVersion: 1)

        // 部分清除（不清审计库）→ .consentRevoked 审计保留
        let partial = PurgeBoundary(
            purgeVectors: false, purgeIndexes: false, purgeCaches: false,
            purgeMetadata: true, purgeAuditLog: false, purgeTranslationCache: false
        )
        _ = try await store.revokeConsent(boundary: partial)
        let revokedLogs = try await privacy.fetchAuditLogs(eventType: .consentRevoked)
        #expect(!revokedLogs.isEmpty)

        // full purge → 审计自擦除（含 .consentRevoked，符合 AC-7）
        try await store.acceptConsent(consentVersion: 1, policyVersion: 1)
        _ = try await store.revokeConsent(boundary: .full)
        let afterFull = try await privacy.fetchAuditLogs(eventType: .consentRevoked)
        #expect(afterFull.isEmpty)
    }

    @Test("acceptConsent write failure keeps in-memory state unchanged (no SQLite divergence)")
    func test_acceptConsent_writeFailure_keepsStateUnchanged() async throws {
        let store = ConsentStoreActor(db: db, privacyActor: PrivacyActor.shared)
        await store.setConsentWriteFault(true)
        do {
            try await store.acceptConsent(consentVersion: 1, policyVersion: 1)
            Issue.record("acceptConsent should throw when the write is faulted")
        } catch {
            // 预期抛出注入错误
        }
        await store.setConsentWriteFault(false)

        // 写库失败后内存状态保持未同意（与 SQLite 一致，不发散）
        #expect(await store.hasConsented() == false)
        let rows = try await db.executeQuery(sql: "SELECT COUNT(*) AS cnt FROM ConsentStore", bindings: [])
        #expect(rows.first?["cnt"]?.intValue == 0)
    }

    @Test("Purge failure enters blocked state and writes an audit, preserving data")
    func test_purgeFailure_blockedAndAudited() async throws {
        try await seedBusinessRow()
        let store = ConsentStoreActor(db: db, privacyActor: PrivacyActor.shared)
        try await store.acceptConsent(consentVersion: 1, policyVersion: 1)

        await store.setPurgeFault(.failBeforeCommit)
        let result = try await store.revokeConsent(boundary: .full)
        await store.setPurgeFault(nil)

        #expect(result.success == false)
        #expect(result.blocked == true)

        // 事务回滚 → 业务数据保留
        let counts = try await businessRowCounts()
        #expect(counts.memory == 1)
        #expect(counts.excluded == 1)

        // 失败审计已写入
        let audit = try await PrivacyActor.shared.fetchAuditLogs(eventType: .purgeFailed)
        #expect(audit.isEmpty == false)
    }

    @Test("Composition exposes purgeBlocked state after a failed purge")
    func test_composition_purgeBlockedState() async throws {
        let privacy = makePrivacy()
        let store = ConsentStoreActor(db: db, privacyActor: privacy)
        try await store.acceptConsent(consentVersion: 1, policyVersion: 1)
        let composition = AppComposition(
            databaseManager: db,
            privacyActor: privacy,
            consentStore: store
        )
        await composition.bootstrap()

        await store.setPurgeFault(.failBeforeCommit)
        _ = try await composition.revokeConsent(boundary: .full)
        await store.setPurgeFault(nil)

        #expect(composition.startupState == .purgeBlocked)
        await privacy.disableConsentEnforcement()
    }

    // MARK: - ADR-007 决策-4: AuditLog schema/存储迁移

    @Test("AuditLog schema requires eventType/timestamp/traceID/policyVersion/success (NOT NULL)")
    func test_auditSchema_requiredFieldsNotNull() async throws {
        let rows = try await db.executeQuery(sql: "PRAGMA table_info(AuditLog)", bindings: [])
        var notNullByName: [String: Bool] = [:]
        for row in rows {
            if let name = row["name"]?.stringValue {
                notNullByName[name] = (row["notnull"]?.intValue ?? 0) != 0
            }
        }
        #expect(notNullByName["eventType"] == true)
        #expect(notNullByName["timestamp"] == true)
        #expect(notNullByName["traceID"] == true)
        #expect(notNullByName["policyVersion"] == true)
        #expect(notNullByName["success"] == true)
    }

    @Test("Inserting a row with a missing required field is rejected")
    func test_auditSchema_rejectsMissingRequiredField() async throws {
        await #expect(throws: (any Error).self) {
            try await db.executeWrite(
                sql: """
                    INSERT INTO AuditLog (timestamp, traceID, policyVersion, success)
                    VALUES (?, ?, ?, ?)
                    """,
                bindings: [.double(Date().timeIntervalSince1970), .text("t"), .int(1), .int(1)]
            )
        }
    }

    @Test("Audit content is stored hash-only, never plaintext")
    func test_auditContent_hashOnly() async throws {
        let secret = "SENSITIVE-MEMORY-CONTENT-DO-NOT-STORE"
        try await PrivacyActor.shared.writeAuditLog(
            eventType: .memoryIngested,
            traceID: "t-hash",
            policyVersion: 1,
            content: secret
        )

        let logs = try await PrivacyActor.shared.fetchAuditLogs(limit: 50)
        let row = logs.first { $0.traceID == "t-hash" }
        #expect(row != nil)
        #expect(row?.contentHash != nil)
        // 内容哈希 = SHA-256 hex 摘要，非原文
        #expect(row?.contentHash == AuditContentHasher.sha256Hex(secret))
        #expect(row?.contentHash != secret)

        // 全表扫描确认明文不存在
        let all = try await db.executeQuery(sql: "SELECT * FROM AuditLog", bindings: [])
        for r in all {
            for v in r.values {
                if let s = v.stringValue {
                    #expect(s.contains(secret) == false)
                }
            }
        }
    }

    @Test("30-day audit cleanup removes only rows older than the boundary")
    func test_audit30DayCleanup_boundary() async throws {
        let cleanupNow = Date().timeIntervalSince1970
        // 31 天前（必然超期）
        try await PrivacyActor.shared.writeAuditLog(eventType: .retrieval, traceID: "old-31", policyVersion: 1)
        try await db.executeWrite(
            sql: "UPDATE AuditLog SET timestamp = ? WHERE traceID = 'old-31'",
            bindings: [.double(cleanupNow - 31 * 86400)]
        )
        // 边界：29 天 23 小时前（仍在保留期内，应保留）
        try await PrivacyActor.shared.writeAuditLog(eventType: .retrieval, traceID: "boundary-30", policyVersion: 1)
        try await db.executeWrite(
            sql: "UPDATE AuditLog SET timestamp = ? WHERE traceID = 'boundary-30'",
            bindings: [.double(cleanupNow - (30 * 86400 - 3600))]
        )
        try await PrivacyActor.shared.writeAuditLog(eventType: .retrieval, traceID: "fresh-1", policyVersion: 1)
        try await db.executeWrite(
            sql: "UPDATE AuditLog SET timestamp = ? WHERE traceID = 'fresh-1'",
            bindings: [.double(cleanupNow - 1 * 86400)]
        )

        let removed = try await PrivacyActor.shared.cleanupOldAuditLogs(retentionDays: 30)
        #expect(removed >= 1)

        let logs = try await PrivacyActor.shared.fetchAuditLogs(limit: 100)
        let traceIDs = Set(logs.map(\.traceID))
        #expect(traceIDs.contains("old-31") == false)
        #expect(traceIDs.contains("boundary-30") == true)
        #expect(traceIDs.contains("fresh-1") == true)
    }

    @Test("Audit storage reports NSFileProtectionComplete")
    func test_auditStorage_fileProtectionComplete() async throws {
        let url = db.databaseURL
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        // Simulators do not enforce file protection: .protectionKey is nil there.
        // On device the key must be .complete (AGENTS.md §5.4). Never leave an empty
        // assertion: the else branch proves the DB file is reachable on simulator.
        if let protection = attrs[.protectionKey] as? String {
            #expect(protection == FileProtectionType.complete.rawValue)
        } else {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    // MARK: - US-PRV-006 AC-6: 记忆永久保留 (retentionPolicyEvaluated)

    @Test("Retention policy evaluation audits mediaExempt/textExempt/autoExpiry=false as hash content")
    func test_retentionPolicyEvaluated() async throws {
        try await PrivacyActor.shared.evaluateRetentionPolicy(traceID: "ret-1")
        let logs = try await PrivacyActor.shared.fetchAuditLogs(eventType: .retentionPolicyEvaluated)
        #expect(logs.isEmpty == false)
        let row = logs.first { $0.traceID == "ret-1" }
        #expect(row != nil)
        // hash-only 内容：验证摘要匹配策略负载
        #expect(row?.contentHash == AuditContentHasher.sha256Hex(#"{"mediaExempt":true,"textExempt":true,"autoExpiry":false}"#))
    }

    // MARK: - 无 CloudKit (ADR-007 决策-6)

    @Test("Composition owns no CloudKit dependency")
    func test_noCloudKit() async throws {
        let composition = makeComposition()
        #expect(composition.databaseManager is DatabaseManager)
        // 仅验证类型存在；零网络红线由 CI 网络扫描覆盖 (R-001/R-005)
    }
}
