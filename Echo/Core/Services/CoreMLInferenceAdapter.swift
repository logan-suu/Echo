// ==========================================
// 文件: CoreMLInferenceAdapter.swift
// 对应规格: docs/decisions/ADR-009-offline-model-runtime.md → 决策 2/3/5/6
// 任务: 3F.3 - E5、SigLIP2、Whisper 与离线生成决策落地
// AC 覆盖: Core ML 模型加载/编译、int32/float 输入装配、Float16/Float32 输出读取、
//          损坏/缺失工件 L3 恢复（US-RES-004）
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载),
//           R-007 (禁止 @unchecked Sendable)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-06
// ==========================================

import Foundation
@preconcurrency import CoreML

// MARK: - Core ML Inference Adapter

/// 通用 Core ML 推理适配器（3F.3）— 封装模型加载、输入装配与输出读取。
///
/// 解决两个跨层问题：
/// 1. `MLModel` 非 Sendable，不能跨 Actor 返回 → 适配器持锁串行访问
/// 2. `MLMultiArray` 在 iOS 26 SDK 的 subscript 为 async → 统一用同步
///    `withUnsafeMutableBytes` 装配、`withUnsafeBytes` 读取
///
/// ## 输入契约
/// - `[String: MLTensorInput]`，值类型为 `[Int32]`（token id）或 `[Float]`（像素/采样）
/// - 输出按 `featureName` 读取，自动处理 Float16（E5 输出）与 Float32
public actor CoreMLInferenceAdapter {

    // MARK: - Error

    /// Core ML 推理错误
    public nonisolated enum InferenceError: Error, LocalizedError, Sendable {
        /// 模型文件缺失或无法编译（L3）
        case modelLoadFailed(modelName: String, underlying: String)
        /// 输入装配失败
        case inputBuildFailed(reason: String)
        /// 模型推理失败
        case predictionFailed(underlying: String)
        /// 输出特征不存在或类型不匹配
        case outputUnavailable(featureName: String)
        /// 输出维度与预期不符
        case dimensionMismatch(expected: Int, got: Int)

        public nonisolated var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let name, let underlying):
                return "CoreML model load failed: \(name) — \(underlying)"
            case .inputBuildFailed(let reason):
                return "Input build failed: \(reason)"
            case .predictionFailed(let underlying):
                return "Prediction failed: \(underlying)"
            case .outputUnavailable(let name):
                return "Output feature unavailable: \(name)"
            case .dimensionMismatch(let expected, let got):
                return "Output dimension mismatch: expected \(expected), got \(got)"
            }
        }
    }

    // MARK: - Input

    /// 单条模型输入特征。
    public nonisolated enum InputFeature: Sendable {
        case intArray([Int32])
        case floatArray([Float])

        public nonisolated var count: Int {
            switch self {
            case .intArray(let a): return a.count
            case .floatArray(let a): return a.count
            }
        }
    }

    // MARK: - Properties

    private var cachedModel: MLModel?

    // MARK: - Initialization

    public init() {}

    // MARK: - Model Loading

    /// 从 Bundle 加载并编译模型。
    ///
    /// - Parameters:
    ///   - resourceName: Bundle 资源名（不含扩展名）
    ///   - extensionName: 扩展名（`mlmodelc` 或 `mlpackage`）
    /// - Throws: `InferenceError.modelLoadFailed`（L3）
    public func loadModel(resourceName: String, extensionName: String = "mlmodelc") async throws {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: extensionName) else {
            throw InferenceError.modelLoadFailed(
                modelName: "\(resourceName).\(extensionName)",
                underlying: "resource not found in bundle"
            )
        }
        try await loadModel(at: url)
    }

    /// 从显式 URL 加载并编译模型（测试注入用）。
    public func loadModel(at url: URL) async throws {
        do {
            let compiledURL: URL
            if url.pathExtension == "mlpackage" {
                compiledURL = try await MLModel.compileModel(at: url)
            } else {
                compiledURL = url
            }
            // 3F.3: 强制 CPU 推理 —— ML Program fp16 模型在模拟器 GPU/ANE 上输出全零
            // （macOS 实测正常），CPU-only 保证确定性真实推理，代价是可接受的延迟。
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            let model = try await MLModel.load(contentsOf: compiledURL, configuration: config)
            for (k, v) in model.modelDescription.inputDescriptionsByName {
            }
            for (k, v) in model.modelDescription.outputDescriptionsByName {
            }
            cachedModel = model
        } catch {
            throw InferenceError.modelLoadFailed(
                modelName: url.lastPathComponent,
                underlying: String(describing: error)
            )
        }
    }

    /// 是否已加载模型。
    public func isLoaded() -> Bool {
        cachedModel != nil
    }

    // MARK: - Prediction

    /// 执行一次预测并读取指定输出特征为 `[Float]`。
    ///
    /// - Parameters:
    ///   - inputs: 特征名 → 输入数组
    ///   - outputName: 目标输出特征名
    ///   - expectedCount: 期望输出长度（校验，默认不校验）
    /// - Returns: 输出浮点数组（Float16 自动转换）
    public func predict(
        inputs: [String: InputFeature],
        outputName: String,
        expectedCount: Int? = nil
    ) async throws -> [Float] {
        guard let model = cachedModel else {
            throw InferenceError.modelLoadFailed(
                modelName: "unknown",
                underlying: "model not loaded — call loadModel first"
            )
        }

        // 装配输入
        let provider = try buildProvider(inputs: inputs)

        // 推理
        let output: any MLFeatureProvider
        do {
            output = try await model.prediction(from: provider)
        } catch {
            throw InferenceError.predictionFailed(underlying: String(describing: error))
        }

        // 读取输出
        guard let feature = output.featureValue(for: outputName) else {
            throw InferenceError.outputUnavailable(featureName: outputName)
        }
        guard let multiArray = feature.multiArrayValue else {
            throw InferenceError.outputUnavailable(featureName: outputName)
        }
        let values = try readFloatArray(multiArray)
        if let expectedCount, values.count != expectedCount {
            throw InferenceError.dimensionMismatch(expected: expectedCount, got: values.count)
        }
        return values
    }

    // MARK: - Input Build

    private func buildProvider(inputs: [String: InputFeature]) throws -> any MLFeatureProvider {
        var features: [String: MLFeatureValue] = [:]
        for (name, input) in inputs {
            let array: MLMultiArray
            do {
                switch input {
                case .intArray(let ids):
                    array = try MLMultiArray(
                        shape: [NSNumber(value: 1), NSNumber(value: ids.count)],
                        dataType: .int32
                    )
                    try array.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer, _) in
                        let bp = raw.bindMemory(to: Int32.self)
                        for (i, v) in ids.enumerated() { bp[i] = v }
                    }
                    var readback = [Int32](repeating: 0, count: ids.count)
                    try array.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        let bp = raw.bindMemory(to: Int32.self)
                        for i in 0..<ids.count { readback[i] = bp[i] }
                    }
                case .floatArray(let floats):
                    array = try MLMultiArray(
                        shape: [NSNumber(value: 1), NSNumber(value: floats.count)],
                        dataType: .float32
                    )
                    try array.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer, _) in
                        let bp = raw.bindMemory(to: Float.self)
                        for (i, v) in floats.enumerated() { bp[i] = v }
                    }
                }
            } catch {
                throw InferenceError.inputBuildFailed(
                    reason: "feature \(name): \(String(describing: error))"
                )
            }
            features[name] = MLFeatureValue(multiArray: array)
        }
        return try MLDictionaryFeatureProvider(dictionary: features)
    }

    // MARK: - Output Read

    /// 读取 MLMultiArray 为 Float 数组（Float16 自动提升）。
    private func readFloatArray(_ array: MLMultiArray) throws -> [Float] {
        var result = [Float](repeating: 0, count: array.count)
        try array.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            switch array.dataType {
            case .float16:
                let bp = raw.bindMemory(to: UInt16.self)
                for i in 0..<array.count {
                    result[i] = Float(Float16(bitPattern: bp[i]))
                }
            case .float32, .double:
                let bp = raw.bindMemory(to: Float.self)
                for i in 0..<array.count {
                    result[i] = bp[i]
                }
            default:
                throw InferenceError.outputUnavailable(
                    featureName: "multiArray (\(array.dataType.rawValue))"
                )
            }
        }
        return result
    }
}
