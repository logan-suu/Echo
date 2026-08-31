// ==========================================
// 文件: PhotoSearchQualityReport.swift
// 对应规格: 交接计划 §WP7 步骤 3a-3f（R@K/nDCG/MRR）+ 5a-5d（no-match/partial-channel）+ 6a-6h（双语/macro/CI）
// 任务: WP7 - 双语质量、设备、法律、CI 与发布门禁
// 架构约束: 纯函数计算层——相同输入恒产生相同报告（发布门禁可复现）
// 生成时间: 2026-08-25
// ==========================================

import Foundation

/// 单查询评估输入（known-item：expectedMemoryID 非 nil；no-match：nil）
public struct PhotoSearchEvaluationCase: Sendable, Equatable {
    nonisolated public let queryID: String
    nonisolated public let locale: String
    nonisolated public let expectedMemoryID: UUID?
    nonisolated public let rankedIDs: [UUID]
    nonisolated public let activeChannelCount: Int
    nonisolated public let totalChannelCount: Int

    nonisolated public init(
        queryID: String,
        locale: String,
        expectedMemoryID: UUID?,
        rankedIDs: [UUID],
        activeChannelCount: Int,
        totalChannelCount: Int
    ) {
        self.queryID = queryID
        self.locale = locale
        self.expectedMemoryID = expectedMemoryID
        self.rankedIDs = rankedIDs
        self.activeChannelCount = activeChannelCount
        self.totalChannelCount = totalChannelCount
    }
}

/// 单语言质量报告（R@1/5/10、nDCG@10、MRR@10、no-match、partial-channel）
public struct PhotoSearchLanguageReport: Sendable, Equatable {
    nonisolated public let locale: String
    nonisolated public let recallAt1: Double
    nonisolated public let recallAt5: Double
    nonisolated public let recallAt10: Double
    nonisolated public let ndcgAt10: Double
    /// known-item-only；无 known-item 查询时为 nil（MRR@10 拒绝非 known-item 查询）
    nonisolated public let mrrAt10: Double?
    nonisolated public let noMatchCorrectRate: Double
    nonisolated public let partialChannelRate: Double
    nonisolated public let knownItemCount: Int
}

/// 质量指标纯函数计算层（WP7 步骤 3a-3f / 5a-5d / 6a-6h）。
public enum PhotoSearchQualityMetrics {

    nonisolated static func rank(of id: UUID, in ranked: [UUID]) -> Int? {
        ranked.firstIndex(of: id).map { $0 + 1 }
    }

    /// 单语言报告（步骤 3a-3b R@K / 3c-3d nDCG@10 / 3e-3f MRR@10 / 5a-5b no-match / 5c-5d partial-channel）
    nonisolated public static func report(
        locale: String, cases: [PhotoSearchEvaluationCase]
    ) -> PhotoSearchLanguageReport {
        let known = cases.filter { $0.expectedMemoryID != nil }
        let noMatch = cases.filter { $0.expectedMemoryID == nil }

        func recall(_ k: Int) -> Double {
            guard !known.isEmpty else { return 0 }
            let hits = known.filter { testCase in
                guard let expected = testCase.expectedMemoryID,
                      let position = rank(of: expected, in: testCase.rankedIDs) else { return false }
                return position <= k
            }.count
            return Double(hits) / Double(known.count)
        }

        // nDCG@10：单相关项 → DCG = 1/log2(rank+1)（rank ≤ 10），IDCG = 1 → nDCG = DCG
        let ndcg: Double = known.isEmpty ? 0 : known.reduce(0.0) { accumulator, testCase in
            guard let expected = testCase.expectedMemoryID,
                  let position = rank(of: expected, in: testCase.rankedIDs),
                  position <= 10 else { return accumulator }
            return accumulator + 1.0 / log2(Double(position + 1))
        } / Double(known.count)

        // MRR@10：known-item-only guard——非 known-item 查询不产生 MRR（3e）
        let mrr: Double? = known.isEmpty ? nil : known.reduce(0.0) { accumulator, testCase in
            guard let expected = testCase.expectedMemoryID,
                  let position = rank(of: expected, in: testCase.rankedIDs),
                  position <= 10 else { return accumulator }
            return accumulator + 1.0 / Double(position)
        } / Double(known.count)

        // no-match 正确率：无相关结果的查询返回空结果即正确（无文本不虚构）
        let noMatchRate: Double = noMatch.isEmpty
            ? 0
            : Double(noMatch.filter { $0.rankedIDs.isEmpty }.count) / Double(noMatch.count)

        // partial-channel：活跃通道数低于总通道数（部分降级）的查询比例
        let partial = cases.filter {
            $0.activeChannelCount < $0.totalChannelCount && $0.activeChannelCount > 0
        }.count
        let partialRate: Double = cases.isEmpty ? 0 : Double(partial) / Double(cases.count)

        return PhotoSearchLanguageReport(
            locale: locale,
            recallAt1: recall(1),
            recallAt5: recall(5),
            recallAt10: recall(10),
            ndcgAt10: ndcg,
            mrrAt10: mrr,
            noMatchCorrectRate: noMatchRate,
            partialChannelRate: partialRate,
            knownItemCount: known.count
        )
    }

    /// macro average——双语报告逐指标均值（步骤 6e/6f；MRR 忽略 nil 语言）
    nonisolated public static func macroAverage(
        _ reports: [PhotoSearchLanguageReport]
    ) -> PhotoSearchLanguageReport? {
        guard !reports.isEmpty else { return nil }
        let mrrValues = reports.compactMap(\.mrrAt10)
        func average(_ picker: (PhotoSearchLanguageReport) -> Double) -> Double {
            Double(reports.map(picker).reduce(0, +)) / Double(reports.count)
        }
        return PhotoSearchLanguageReport(
            locale: "macro",
            recallAt1: average(\.recallAt1),
            recallAt5: average(\.recallAt5),
            recallAt10: average(\.recallAt10),
            ndcgAt10: average(\.ndcgAt10),
            mrrAt10: mrrValues.isEmpty
                ? nil
                : mrrValues.reduce(0, +) / Double(mrrValues.count),
            noMatchCorrectRate: average(\.noMatchCorrectRate),
            partialChannelRate: average(\.partialChannelRate),
            knownItemCount: reports.reduce(0) { $0 + $1.knownItemCount }
        )
    }

    /// paired confidence interval——两语言 recall 差值的正态近似 95% CI（步骤 6g/6h）
    nonisolated public static func pairedConfidenceInterval(
        recallA: Double, sampleA: Int, recallB: Double, sampleB: Int
    ) -> (lower: Double, upper: Double)? {
        guard sampleA > 0, sampleB > 0 else { return nil }
        let diff = recallA - recallB
        let standardError = sqrt(
            recallA * (1 - recallA) / Double(sampleA)
                + recallB * (1 - recallB) / Double(sampleB)
        )
        guard standardError > 0 else { return (diff, diff) }
        let margin = 1.96 * standardError
        return (diff - margin, diff + margin)
    }
}
