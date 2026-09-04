// ==========================================
// File: TaskRecovery.swift
// Spec: docs/01-spec/用户故事与验收标准规格书.md → US-SYS-001 AC-3/AC-4
// Task: 4.0g - Production task resume loop
// AC Coverage: versioned bounded resume descriptor, typed allow-list request, L2 errors
// Architecture: AGENTS.md §4.2, §4.3, §4.5
// Generated: 2026-09-04
// ==========================================

import CryptoKit
import Foundation

/// Persistable, non-executable description used to reconstruct a cancelled task.
public nonisolated struct TaskResumeDescriptor: Sendable, Codable, Equatable {
    public nonisolated static let currentSchemaVersion = 1
    public nonisolated static let maximumPayloadBytes = 64 * 1_024
    public nonisolated static let maximumEncodedBytes = 96 * 1_024

    public nonisolated let schemaVersion: Int
    public nonisolated let operation: PrivacyOperation
    public nonisolated let sourceTypes: [String]
    public nonisolated let payload: Data
    public nonisolated let payloadDigest: String

    public nonisolated init(
        schemaVersion: Int = Self.currentSchemaVersion,
        operation: PrivacyOperation,
        sourceTypes: [String],
        payload: Data
    ) {
        self.schemaVersion = schemaVersion
        self.operation = operation
        self.sourceTypes = sourceTypes.sorted()
        self.payload = payload
        self.payloadDigest = Self.digest(payload)
    }

    public nonisolated func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumEncodedBytes else {
            throw TaskResumeDescriptorError.oversized
        }
        return data
    }

    public nonisolated static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw data.isEmpty ? TaskResumeDescriptorError.malformed : TaskResumeDescriptorError.oversized
        }
        let descriptor: Self
        do {
            descriptor = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw TaskResumeDescriptorError.malformed
        }
        try descriptor.validate()
        return descriptor
    }

    public nonisolated func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TaskResumeDescriptorError.unsupportedVersion(schemaVersion)
        }
        guard payload.count <= Self.maximumPayloadBytes else {
            throw TaskResumeDescriptorError.oversized
        }
        guard payloadDigest == Self.digest(payload) else {
            throw TaskResumeDescriptorError.integrityMismatch
        }
        guard sourceTypes.allSatisfy({ !$0.isEmpty }) else {
            throw TaskResumeDescriptorError.malformed
        }
    }

    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum TaskResumeDescriptorError: Error, Sendable, Equatable {
    case malformed
    case oversized
    case unsupportedVersion(Int)
    case integrityMismatch
}

public nonisolated struct TaskRecoveryRequest: Sendable {
    public nonisolated let progress: TaskProgress
    public nonisolated let descriptor: TaskResumeDescriptor
    public nonisolated let choice: TaskRecoveryChoice

    public nonisolated init(
        progress: TaskProgress,
        descriptor: TaskResumeDescriptor,
        choice: TaskRecoveryChoice
    ) {
        self.progress = progress
        self.descriptor = descriptor
        self.choice = choice
    }
}

public enum TaskRecoveryChoice: String, Sendable, Equatable {
    case `continue`
    case restart
}

public enum TaskRecoveryOutcome: String, Sendable, Equatable {
    case resumed
    case restarted
}

public enum TaskRecoveryError: Error, Sendable, Equatable {
    case progressMissing
    case staleProgress
    case taskOwnedByCurrentSession
    case recoveryAlreadyInProgress
    case descriptorUnavailable
    case descriptorInvalid
    case unsupportedTaskType(String)
    case privacyDenied
    case launcherMismatch
    case enqueueFailed
}
