// ==========================================
// 文件: PrivacyActorTests.swift
// 对应规格: docs/02-architecture/架构设计文档.md §7 (隐私校验与审计追踪)
//            docs/01-spec/用户故事与验收标准规格书.md → US-PRV-001
// 任务: 1.8 - 搭建单元测试框架，编写第一个 Actor 测试用例
// AC 覆盖: US-PRV-001 AC-1 (授权校验)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §7.1 (PrivacyCheckpoint 强制注入)
// 生成时间: 2026-07-05
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Test Suite: PrivacyActor

@Suite("PrivacyActor", .serialized)
struct PrivacyActorTests {

    let sut = PrivacyActor.shared

    // MARK: - PrivacyCheckpoint Tests

    @Test("validate returns allowed when no source types specified (no restrictions)")
    func test_validate_noSourceTypes_allowed() async {
        let traceID = UUID().uuidString
        let checkpoint = await sut.validate(
            operation: .search,
            traceID: traceID,
            sourceTypes: []
        )

        #expect(checkpoint.decision == .allowed)
        #expect(checkpoint.traceID == traceID)
        #expect(checkpoint.operation == .search)
        #expect(checkpoint.isAllowed == true)
    }

    @Test("validate returns allowed for authorized source type (photo)")
    func test_validate_authorizedSourceType_allowed() async {
        let traceID = UUID().uuidString
        let checkpoint = await sut.validate(
            operation: .ingest,
            traceID: traceID,
            sourceTypes: ["photo"]
        )

        #expect(checkpoint.decision == .allowed)
        #expect(checkpoint.operation == .ingest)
        #expect(checkpoint.sourceTypes == ["photo"])
    }

    @Test("validate returns denied for unauthorized source type")
    func test_validate_unauthorizedSourceType_denied() async {
        let traceID = UUID().uuidString
        let checkpoint = await sut.validate(
            operation: .sync,
            traceID: traceID,
            sourceTypes: ["calendar"] // not in default authorized set
        )

        #expect(checkpoint.decision == .denied)
        #expect(checkpoint.isAllowed == false)
    }

    @Test("validate returns denied when any source type among multiple is unauthorized")
    func test_validate_partialAuthorization_denied() async {
        let traceID = UUID().uuidString
        // "photo" is authorized, "calendar" is not — all must pass
        let checkpoint = await sut.validate(
            operation: .sync,
            traceID: traceID,
            sourceTypes: ["photo", "calendar"]
        )

        #expect(checkpoint.decision == .denied)
    }

    // MARK: - Policy Management Tests

    @Test("getPolicy returns policy with zh-Hans language and version 1")
    func test_getPolicy_defaultPolicy() async {
        let policy = await sut.getPolicy()

        #expect(policy.preferredLanguage == "zh-Hans")
        #expect(policy.policyVersion == 1)
    }

    @Test("updatePolicy changes authorized source types and restores defaults")
    func test_updatePolicy_changesAuthorization() async {
        let originalPolicy = await sut.getPolicy()

        var newPolicy = originalPolicy
        newPolicy.authorizedSourceTypes = ["photo"] // only photo
        await sut.updatePolicy(newPolicy)

        let updated = await sut.getPolicy()
        #expect(updated.authorizedSourceTypes == ["photo"])

        // Restore original policy to avoid polluting shared state for other tests
        await sut.updatePolicy(originalPolicy)
    }

    @Test("isSourceAuthorized returns true for default authorized type")
    func test_isSourceAuthorized() async {
        let authorized = await sut.isSourceAuthorized("photo")
        #expect(authorized == true)
    }

    @Test("isSourceAuthorized returns false for unauthorized type")
    func test_isSourceAuthorized_false() async {
        let authorized = await sut.isSourceAuthorized("calendar")
        #expect(authorized == false)
    }

    // MARK: - PrivacyCheckpoint Model Tests

    @Test("PrivacyCheckpoint.isAllowed returns true when decision is allowed")
    func test_checkpoint_isAllowed_true() {
        let checkpoint = PrivacyCheckpoint(
            traceID: "test",
            operation: .search,
            decision: .allowed
        )
        #expect(checkpoint.isAllowed == true)
    }

    @Test("PrivacyCheckpoint.isAllowed returns false when decision is denied")
    func test_checkpoint_isAllowed_false() {
        let checkpoint = PrivacyCheckpoint(
            traceID: "test",
            operation: .search,
            decision: .denied
        )
        #expect(checkpoint.isAllowed == false)
    }

    @Test("PrivacyOperation is Codable round-trip")
    func test_privacyOperation_codable() throws {
        let ops: [PrivacyOperation] = [.search, .ingest, .sync, .delete, .awakening, .feedback]
        for op in ops {
            let data = try JSONEncoder().encode(op)
            let decoded = try JSONDecoder().decode(PrivacyOperation.self, from: data)
            #expect(decoded == op)
        }
    }
}
