// ==========================================
// 文件: RealPhotoSearchEvaluationHarness.swift
// 对应规格: 交接计划 §WP7 步骤 1a-1f/2a-2d（真实工件评估 harness）
// 任务: WP7 - 双语质量、设备、法律、CI 与发布门禁
// 架构约束: 仅接受真实工件（拒绝 synthetic）；typed failures fail-closed
// 生成时间: 2026-08-25
// ==========================================

import CryptoKit
import Foundation

@testable import Echo

/// 真实工件评估 harness 的 typed 失败（fail-closed，发布门禁预检）。
public enum PhotoSearchHarnessError: Error, Equatable, Sendable {
    case missingArtifact(path: String)
    case hashMismatch(expected: String, actual: String)
    case missingRights(fixtureID: String)
    case syntheticVectorDetected(fixtureID: String)
    case routeDigestMismatch(expected: String, actual: String)
    case malformedManifest(reason: String)
}

/// 真实工件评估 harness——解析冻结的 fixture manifest 并执行
/// 存在性 / SHA-256 / 权利必填 / synthetic 拒绝 / 路由 digest 预检。
///
/// 质量门禁前提：任何 typed 失败都阻断后续质量测量（步骤 7a 的前置）。
public struct RealPhotoSearchEvaluationHarness {
    public struct Fixture: Sendable, Equatable {
        public nonisolated let id: String
        public nonisolated let file: String
        public nonisolated let sha256: String
        public nonisolated let license: String
        public nonisolated let rights: String
        /// synthetic 标记——true 的 fixture 不具备参与质量测量资格（real-artifact-only）
        public nonisolated let synthetic: Bool

        public nonisolated init(
            id: String, file: String, sha256: String, license: String, rights: String,
            synthetic: Bool = false
        ) {
            self.id = id
            self.file = file
            self.sha256 = sha256
            self.license = license
            self.rights = rights
            self.synthetic = synthetic
        }
    }

    public nonisolated let fixtures: [Fixture]

    /// 从 manifest JSON 构造（fixtures 数组必填且非空）。
    public init(manifestData: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let rawFixtures = root["fixtures"] as? [[String: Any]] else {
            throw PhotoSearchHarnessError.malformedManifest(reason: "missing fixtures array")
        }
        self.fixtures = rawFixtures.map { raw in
            Fixture(
                id: raw["id"] as? String ?? "",
                file: raw["file"] as? String ?? "",
                sha256: raw["sha256"] as? String ?? "",
                license: raw["license"] as? String ?? "",
                rights: raw["rights"] as? String ?? "",
                synthetic: raw["synthetic"] as? Bool ?? false
            )
        }
        guard !fixtures.isEmpty else {
            throw PhotoSearchHarnessError.malformedManifest(reason: "empty fixtures array")
        }
    }

    /// 步骤 1c/1d：required artifact 存在性预检——任一文件缺失即 typed 失败。
    public func validateArtifactPresence(baseDir: URL) throws {
        for fixture in fixtures {
            let url = baseDir.appendingPathComponent(fixture.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PhotoSearchHarnessError.missingArtifact(path: fixture.file)
            }
        }
    }

    /// 步骤 1d1/1d2：SHA-256 校验——磁盘字节与声明 digest 不一致即 typed 失败。
    public func validateArtifactHashes(baseDir: URL) throws {
        for fixture in fixtures {
            let url = baseDir.appendingPathComponent(fixture.file)
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == fixture.sha256 else {
                throw PhotoSearchHarnessError.hashMismatch(expected: fixture.sha256, actual: digest)
            }
        }
    }

    /// 步骤 1e/1f：权利必填校验——任一 fixture 缺 rights 即拒绝。
    public func validateRights() throws {
        for fixture in fixtures {
            guard !fixture.rights.isEmpty else {
                throw PhotoSearchHarnessError.missingRights(fixtureID: fixture.id)
            }
        }
    }

    /// 步骤 2a/2b：real-artifact-only guard——任一 fixture 标记 synthetic 即拒绝参与质量测量。
    public func validateNoSynthetic() throws {
        for fixture in fixtures where fixture.synthetic {
            throw PhotoSearchHarnessError.syntheticVectorDetected(fixtureID: fixture.id)
        }
    }

    /// 步骤 2c/2d：路由 canonical digest 预检——重算 digest 与期望比对，不一致即拒绝。
    public func validateRouteDigest(_ route: SearchRouteSnapshot, expected digest: String) throws {
        let computed = try route.computedDigest()
        guard computed == digest else {
            throw PhotoSearchHarnessError.routeDigestMismatch(expected: digest, actual: computed)
        }
    }
}