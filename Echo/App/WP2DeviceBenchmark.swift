// ==========================================
// 文件: WP2DeviceBenchmark.swift
// 对应规格: 自然语言照片检索交接计划 步骤 6（物理设备实证）
// 任务: WP2 - 双塔 Core ML 设备端基准（cold/warm 延迟 + 内存足迹）
// 架构约束: 仅由 launch 参数 "-wp2-benchmark" 触发；不使用 Task.detached（R 系约束）；
//           结果写入 Documents/WP2BenchmarkResult.json 供 photo_search_profile_device.py 拉取。
// 生成时间: 2026-08-25
// ==========================================

import CoreML
import Foundation

enum WP2DeviceBenchmark {
    static let launchArgument = "-wp2-benchmark"
    static let resultFileName = "WP2BenchmarkResult.json"

    static var shouldRun: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// 在 app 启动路径调用；非隔离异步执行避免阻塞主线程。
    static func runIfNeeded() {
        guard shouldRun else { return }
        Task { await run() }
    }

    struct Report: Codable {
        var deviceModel: String
        var osVersion: String
        var computeUnits: String
        var textColdMs: Double
        var textWarmAvgMs: Double
        var visionColdMs: Double
        var visionWarmAvgMs: Double
        var warmRuns: Int
        var peakFootprintMB: Double
        var textEmbeddingNorm: Double
        var visionEmbeddingNorm: Double
        var completedAtEpochMs: Int64
        var error: String?
    }

    private static func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576.0 : -1
    }

    private static func writeReport(_ report: Report) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(resultFileName)
        let data = try? JSONEncoder().encode(report)
        try? data?.write(to: url)
    }

    private static func errorMessage(_ error: Error) -> Report {
        errorMessage(String(describing: error))
    }

    private static func errorMessage(_ message: String) -> Report {
        Report(deviceModel: ProcessInfo.processInfo.machineName ?? "unknown",
               osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
               computeUnits: "all", textColdMs: -1, textWarmAvgMs: -1,
               visionColdMs: -1, visionWarmAvgMs: -1, warmRuns: 0,
               peakFootprintMB: -1, textEmbeddingNorm: -1, visionEmbeddingNorm: -1,
               completedAtEpochMs: Int64(Date().timeIntervalSince1970 * 1000),
               error: message)
    }

    /// 非隔离静态异步——运行双塔冷/热推理并输出指标文件。
    static func run() async {
        let warmRuns = 10
        var peak = physFootprintMB()
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            guard let textURL = Bundle.main.url(forResource: "SigLIP2TextBasePatch32", withExtension: "mlmodelc"),
                  let visionURL = Bundle.main.url(forResource: "SigLIP2BasePatch32", withExtension: "mlmodelc") else {
                writeReport(errorMessage("mlmodelc missing from bundle"))
                return
            }

            // 冷加载
            var t0 = Date()
            let textModel = try MLModel(contentsOf: textURL, configuration: config)
            let textCold = Date().timeIntervalSince(t0) * 1000
            peak = max(peak, physFootprintMB())
            t0 = Date()
            let visionModel = try MLModel(contentsOf: visionURL, configuration: config)
            let visionCold = Date().timeIntervalSince(t0) * 1000
            peak = max(peak, physFootprintMB())

            // 固定输入：zhHans 首例 token 序列（与 pytest fixture 同源）与纯蓝 256 归一化图
            var ids = [854, 10377, 1] + [Int](repeating: 0, count: 61)
            let _ = ids.removeLast(); ids.append(0)
            let idsArr = try MLMultiArray(shape: [1, 64], dataType: .int32)
            for (i, v) in ids.enumerated() { idsArr[i] = NSNumber(value: v) }
            let idsFeat = try MLDictionaryFeatureProvider(dictionary: ["input_ids": idsArr])

            var px = [Float](repeating: 0, count: 3 * 256 * 256)
            for i in 0..<256*256 { px[i] = -1; px[256*256 + i] = -1; px[2*256*256 + i] = 1 }
            let pxArr = try MLMultiArray(shape: [1, 3, 256, 256], dataType: .float32)
            for (i, v) in px.enumerated() { pxArr[i] = NSNumber(value: v) }
            let pxFeat = try MLDictionaryFeatureProvider(dictionary: ["pixel_values": pxArr])

            // 文本热推理
            t0 = Date()
            var textOut: MLMultiArray?
            for _ in 0..<warmRuns {
                let out = try await textModel.prediction(from: idsFeat)
                textOut = out.featureValue(for: "text_embeddings")?.multiArrayValue
            }
            let textWarm = Date().timeIntervalSince(t0) * 1000 / Double(warmRuns)

            // 视觉热推理
            t0 = Date()
            var visionOut: MLMultiArray?
            for _ in 0..<warmRuns {
                let out = try await visionModel.prediction(from: pxFeat)
                visionOut = out.featureValue(for: "embeddings")?.multiArrayValue
            }
            let visionWarm = Date().timeIntervalSince(t0) * 1000 / Double(warmRuns)
            peak = max(peak, physFootprintMB())

            func l2(_ arr: MLMultiArray?) -> Double {
                guard let arr else { return -1 }
                var s = 0.0
                for i in 0..<arr.count { let v = arr[i].doubleValue; s += v*v }
                return sqrt(s)
            }

            let report = Report(
                deviceModel: ProcessInfo.processInfo.machineName ?? "unknown",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                computeUnits: "all",
                textColdMs: textCold, textWarmAvgMs: textWarm,
                visionColdMs: visionCold, visionWarmAvgMs: visionWarm,
                warmRuns: warmRuns, peakFootprintMB: peak,
                textEmbeddingNorm: l2(textOut), visionEmbeddingNorm: l2(visionOut),
                completedAtEpochMs: Int64(Date().timeIntervalSince1970 * 1000),
                error: nil)
            writeReport(report)
        } catch {
            writeReport(errorMessage(error))
        }
    }
}

extension ProcessInfo {
    var machineName: String? {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
