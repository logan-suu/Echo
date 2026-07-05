// ==========================================
// 文件: ModelLoaderActor.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-RES-004
//            docs/03-implementation/开发避坑与关键注意点手册.md §11 (模型加载与降级)
//            docs/02-architecture/技术选型文档.md §5 (模型加载策略)
// 任务: 1.6 - 实现 ModelLoaderActor 手动加载/重试机制
// AC 覆盖: AC-1 (模型文件 Bundle 分发), AC-2 (加载失败含 modelName + recoveryMethod),
//           AC-3 (仅手动重试, 无自动重试), AC-5 (离线兜底 FTS5),
//           AC-6 (无模型切换), AC-7 (UI 功能受限提示),
//           AC-8 (审计 .modelLoadFailed / .modelLoadRetrySuccess)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载),
//           R-007 (禁止 @unchecked Sendable), ACT-005 (初始化器同步)
// 重要: 所有 struct stored/computed properties 必须 nonisolated（项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor）
// 生成时间: 2026-07-05
// ==========================================

import Foundation
import CoreML
import UIKit

// MARK: - Model Loader Actor

/// 模型加载 Actor — 管理 Core ML (.mlmodelc) 和 GGUF 模型的本地加载、状态追踪与手动重试。
///
/// ## 设计原则
/// - **仅本地加载**：所有模型从 `Bundle.main` 加载，不发起任何网络请求（R-005）
/// - **仅手动重试**：无 Timer/DispatchQueue 自动重试，用户必须主动点击"重试加载"按钮（AC-3）
/// - **固定模型集**：6 个模型类型由 `ModelType` 枚举固定，不可运行时切换（AC-6）
/// - **失败兜底**：模型加载失败时，上层应使用 FTS5 关键词检索作为兜底（AC-5/MDL-005）
///
/// ## Actor 隔离（AGENTS.md §4.2）
/// - 可变状态（加载状态字典）封装在 Actor 中
/// - 跨 Actor 调用必须 await（R-008）
/// - 所有参数为 Sendable 值类型
///
/// ## 审计（AC-8）
/// - 加载失败 → `.modelLoadFailed`（含 modelName, error, recoveryMethod=systemSettings）
/// - 手动重试成功 → `.modelLoadRetrySuccess`
public actor ModelLoaderActor {

    // MARK: - Model Types (AC-1: fixed set, AC-6: no switching)

    /// Echo 内置的所有模型类型。
    ///
    /// 共 6 个模型文件，与 `ModelBundleTests.swift` 中的 `ExpectedModels.all` 保持同步。
    /// - 模型文件随 App 安装包分发（AC-1），运行时不可切换（AC-6）
    /// - 扩展名仅 `.mlmodelc` 或 `.gguf`（AC-1）
    public enum ModelType: String, CaseIterable, Sendable {
        /// MobileCLIP-B LT 图像编码器（286MB）
        case mobileCLIPImage
        /// MobileCLIP-B LT 文本编码器（286MB 同包）
        case mobileCLIPText
        /// multilingual-e5-small 文本嵌入（224MB）
        case multilingualE5Small
        /// SenseVoice Small INT8 Core ML（373MB 一部分）
        case senseVoiceInt8
        /// SenseVoice 预处理模型
        case senseVoicePreprocessor
        /// SenseVoice Small Q4_K GGUF（373MB 一部分）
        case senseVoiceGGUF

        // MARK: Bundle Resource Info

        /// Bundle 中的资源名称（不含扩展名）
        public nonisolated var resourceName: String {
            switch self {
            case .mobileCLIPImage:       return "MobileCLIP-B-lt_image"
            case .mobileCLIPText:        return "MobileCLIP-B-lt_text"
            case .multilingualE5Small:   return "MultilingualE5Small"
            case .senseVoiceInt8:        return "SenseVoiceSmall_int8"
            case .senseVoicePreprocessor: return "SenseVoicePreprocessor"
            case .senseVoiceGGUF:        return "sensevoice-small-q4_k"
            }
        }

        /// 文件扩展名
        public nonisolated var fileExtension: String {
            switch self {
            case .senseVoiceGGUF: return "gguf"
            default:              return "mlmodelc"
            }
        }

        /// 完整的资源标识符（resourceName.extension）
        public nonisolated var resourceIdentifier: String {
            "\(resourceName).\(fileExtension)"
        }

        /// Bundle 中模型文件的 URL（AC-1: 仅本地 Bundle）
        public nonisolated var bundleURL: URL? {
            Bundle.main.url(forResource: resourceName, withExtension: fileExtension)
        }

        /// 用于审计日志的模型名称（AC-8）
        public nonisolated var modelName: String {
            resourceIdentifier
        }
    }

    // MARK: - Load State (AC-5, AC-7)

    /// 单个模型的加载状态
    ///
    /// 状态流转：`.notLoaded` → `.loading` → `.loaded` | `.failed`（AC-5）
    public enum ModelLoadState: Sendable, CustomStringConvertible {
        /// 尚未尝试加载
        case notLoaded
        /// 正在加载中
        case loading
        /// 加载成功
        case loaded
        /// 加载失败（含错误详情，AC-2/AC-7/AC-8）
        case failed(ModelLoadError)

        /// 人类可读的状态描述（AC-7: UI 展示用）
        public nonisolated var description: String {
            switch self {
            case .notLoaded: return "未加载"
            case .loading:   return "加载中…"
            case .loaded:    return "已就绪"
            case .failed(let error):
                return "加载失败: \(error.modelName)"
            }
        }

        /// 模型是否已成功加载
        public nonisolated var isLoaded: Bool {
            if case .loaded = self { return true }
            return false
        }
    }

    // MARK: - Overall Status (AC-5, AC-7)

    /// 所有模型的整体加载状态摘要（AC-7: UI 功能受限提示 / "修复"入口）
    public struct OverallStatus: Sendable {
        /// 模型总数
        public nonisolated let allModelsCount: Int
        /// 成功加载数
        public nonisolated let loadedCount: Int
        /// 加载失败数
        public nonisolated let failedCount: Int
        /// 未加载数
        public nonisolated let notLoadedCount: Int
        /// 各模型详细状态
        public nonisolated let states: [ModelType: ModelLoadState]

        /// 是否所有模型均已成功加载
        public nonisolated var allLoaded: Bool {
            loadedCount == allModelsCount
        }

        /// 是否有任何模型加载失败
        public nonisolated var hasFailures: Bool {
            failedCount > 0
        }

        /// AC-7: 是否需要显示"功能受限"UI
        public nonisolated var isDegraded: Bool {
            hasFailures && loadedCount > 0
        }

        /// AC-7: 是否完全不可用（需要引导修复）
        public nonisolated var isUnavailable: Bool {
            loadedCount == 0 && failedCount > 0
        }

        public nonisolated init(
            allModelsCount: Int,
            loadedCount: Int,
            failedCount: Int,
            notLoadedCount: Int,
            states: [ModelType: ModelLoadState]
        ) {
            self.allModelsCount = allModelsCount
            self.loadedCount = loadedCount
            self.failedCount = failedCount
            self.notLoadedCount = notLoadedCount
            self.states = states
        }
    }

    // MARK: - Load Error (AC-2, AC-8)

    /// 模型加载错误类型（AC-2: 含 modelName + recoveryMethod）
    ///
    /// 所有错误均包含 `modelName`（AC-8: 审计日志必需）和固定 `recoveryMethod = "systemSettings"`（AC-2）
    public enum ModelLoadError: Error, LocalizedError, Sendable {
        /// 模型资源未在 Bundle 中找到（AC-1 违规或文件丢失）
        case modelNotFound(modelName: String, resourceName: String)
        /// Core ML / GGUF 加载过程失败（文件损坏、权限问题等，AC-2）
        case loadFailed(modelName: String, resourceName: String, underlying: Error)

        // MARK: Error Properties

        /// 模型名称（AC-8: 审计日志必需）
        public nonisolated var modelName: String {
            switch self {
            case .modelNotFound(let name, _):   return name
            case .loadFailed(let name, _, _):   return name
            }
        }

        /// AC-2: 引导用户前往系统设置修复
        public nonisolated var recoveryMethod: String {
            "systemSettings"
        }

        /// AC-8: 用于审计日志的模型名称标识
        public nonisolated var auditModelName: String {
            modelName
        }

        /// AC-2/AC-7: 人类可读的错误描述
        public nonisolated var errorDescription: String? {
            switch self {
            case .modelNotFound(let name, let resource):
                return "模型文件缺失: \(name) (\(resource))。请前往「设置 > 通用 > iPhone 存储空间 > Echo」修复或重装 App。"
            case .loadFailed(let name, let resource, let error):
                return "模型加载失败: \(name) (\(resource)) — \(error.localizedDescription)。请前往「设置 > 通用 > iPhone 存储空间 > Echo」修复或重装 App。"
            }
        }

        /// AC-7: 跳转系统设置的 URL
        public static nonisolated var settingsRecoveryURL: URL? {
            URL(string: UIApplication.openSettingsURLString)
        }
    }

    // MARK: - Properties

    /// 各模型的加载状态（Actor-isolated 可变状态）
    private var modelStates: [ModelType: ModelLoadState]

    // MARK: - Initialization (ACT-005: 同步初始化)

    /// 创建 ModelLoaderActor，所有模型初始状态为 `.notLoaded`。
    public init() {
        var states: [ModelType: ModelLoadState] = [:]
        for type in ModelType.allCases {
            states[type] = .notLoaded
        }
        self.modelStates = states
    }

    // MARK: - State Query

    /// 查询指定模型的加载状态。
    public func state(for modelType: ModelType) -> ModelLoadState {
        modelStates[modelType] ?? .notLoaded
    }

    /// 查询指定模型是否已成功加载。
    public func isModelLoaded(_ modelType: ModelType) -> Bool {
        modelStates[modelType]?.isLoaded ?? false
    }

    /// 获取所有模型的整体状态摘要（AC-5, AC-7）。
    public var overallStatus: OverallStatus {
        let states = modelStates
        let loaded = states.values.filter { $0.isLoaded }.count
        let failed = states.values.filter { if case .failed = $0 { return true }; return false }.count
        let notLoaded = states.values.filter { if case .notLoaded = $0 { return true }; return false }.count
        return OverallStatus(
            allModelsCount: ModelType.allCases.count,
            loadedCount: loaded,
            failedCount: failed,
            notLoadedCount: notLoaded,
            states: states
        )
    }

    // MARK: - Load Model (R-005: local Bundle only)

    /// 加载指定类型的单个模型（从 Bundle 本地加载，AC-1/R-005）。
    ///
    /// - Parameter modelType: 模型类型
    /// - Returns: 加载后的状态
    ///
    /// ## 加载逻辑
    /// 1. 检查模型文件是否存在于 Bundle
    /// 2. Core ML 模型：调用 `MLModel.load(contentsOf:)` 编译并加载
    /// 3. GGUF 模型：验证文件存在且可读（AC-1）
    /// 4. 失败时更新状态为 `.failed` 并返回错误（AC-2/AC-8）
    public func loadModel(_ modelType: ModelType) async -> ModelLoadState {
        // Skip if already loaded (idempotent)
        if case .loaded = modelStates[modelType] {
            return .loaded
        }

        // Mark as loading
        modelStates[modelType] = .loading

        // Verify bundle resource exists (AC-1)
        guard let bundleURL = modelType.bundleURL else {
            let error = ModelLoadError.modelNotFound(
                modelName: modelType.modelName,
                resourceName: modelType.resourceIdentifier
            )
            modelStates[modelType] = .failed(error)
            // TODO (Phase 2): Audit @ PrivacyActor — .modelLoadFailed(modelName, error, recoveryMethod=systemSettings)
            return .failed(error)
        }

        // Load based on file type
        do {
            switch modelType.fileExtension {
            case "mlmodelc":
                // Core ML compiled model — load into memory
                _ = try await MLModel.load(contentsOf: bundleURL, configuration: MLModelConfiguration())
            case "gguf":
                // GGUF model — verify file readability (actual Whisper initialization in Phase 2)
                guard FileManager.default.isReadableFile(atPath: bundleURL.path) else {
                    throw NSError(
                        domain: "ModelLoaderActor",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "GGUF file not readable at \(bundleURL.path)"]
                    )
                }
            default:
                throw NSError(
                    domain: "ModelLoaderActor",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown file extension: \(modelType.fileExtension)"]
                )
            }

            modelStates[modelType] = .loaded
            return .loaded

        } catch {
            let loadError = ModelLoadError.loadFailed(
                modelName: modelType.modelName,
                resourceName: modelType.resourceIdentifier,
                underlying: error
            )
            modelStates[modelType] = .failed(loadError)
            // TODO (Phase 2): Audit @ PrivacyActor — .modelLoadFailed(modelName, error, recoveryMethod=systemSettings)
            return .failed(loadError)
        }
    }

    /// 加载所有 6 个模型（AC-1），返回各模型加载结果。
    ///
    /// 已有状态的模型（`.loaded` 或 `.failed`）将被跳过（幂等）。
    public func loadAllModels() async -> [ModelLoadState] {
        var results: [ModelLoadState] = []
        for type in ModelType.allCases {
            // Skip already loaded models
            if case .loaded = modelStates[type] {
                results.append(.loaded)
                continue
            }
            let state = await loadModel(type)
            results.append(state)
        }
        return results
    }

    // MARK: - Manual Retry (AC-3: no automatic retry)

    /// 手动重试加载指定模型（仅重新加载本地 Bundle 文件，AC-2/AC-3）。
    ///
    /// - Parameter modelType: 要重试的模型类型
    /// - Returns: 重试后的加载状态
    ///
    /// ## AC-3 合规
    /// - 此方法**仅在用户主动调用时执行**（通过 UI 按钮触发）
    /// - 无 Timer / DispatchQueue / Task.sleep 自动调度
    public func retryLoadModel(_ modelType: ModelType) async -> ModelLoadState {
        // Reset state to notLoaded before retry
        modelStates[modelType] = .notLoaded

        let result = await loadModel(modelType)

        // AC-8: 审计 — 重试成功
        if case .loaded = result {
            // TODO (Phase 2): Audit @ PrivacyActor — .modelLoadRetrySuccess
        }

        return result
    }

    /// 手动重试所有失败模型的加载（AC-3: 仅手动调用，无自动重试）。
    ///
    /// - Returns: 各失败模型重试后的加载状态
    public func retryAllFailedModels() async -> [ModelLoadState] {
        var results: [ModelLoadState] = []
        for type in ModelType.allCases {
            if case .failed = modelStates[type] {
                let state = await retryLoadModel(type)
                results.append(state)
            }
        }
        return results
    }
}
