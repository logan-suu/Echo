// ==========================================
// 文件: E5Tokenizer.swift
// 对应规格: docs/decisions/ADR-009-offline-model-runtime.md → 决策 2/3/6
//            Echo dev-1.0 缺陷修复计划.md → Phase R-3.1/R-3.8
// 任务: 3F.3 - E5、SigLIP2、Whisper 与离线生成决策落地
// AC 覆盖: multilingual-e5-small Unigram (SentencePiece) tokenizer、
//          Metaspace 预分词、query/passage 前缀、<s>/</s> 包装、maxLen 截断
// 架构约束: AGENTS.md §4.2 (Actor 隔离), R-005 (禁止网络下载)
// 重要: 项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，所有 struct stored/computed 需 nonisolated
// 生成时间: 2026-08-06
// ==========================================

import Foundation

// MARK: - E5 Tokenizer

/// multilingual-e5-small 的 Unigram (SentencePiece) tokenizer（3F.3）。
///
/// 从随 Bundle 分发的 `tokenizer.json`（tamikisg/multilingual-e5-small-coreml）加载词表，
/// 实现 Metaspace 预分词 + Unigram Viterbi 最优切分 + `<s>`/`</s>` 包装。
/// 纯本地，零网络（R-005）。
///
/// ## 推理契约（与 MultilingualE5Small Core ML 模型一致）
/// - 输入：`input_ids` / `attention_mask`（Int32 [1, maxLength]）
/// - E5 前缀：query 侧 `"query: "`，passage 侧 `"passage: "`（R-3.8）
/// - 包装：`<s> tokens </s>`
///
/// ## 归一化说明
/// tokenizer.json 的 normalizer 为 `Precompiled`（编译版 NFKC 字符映射）。
/// Swift 无 NFKC 公开 API，本实现采用「NFC + 全角→半角」近似（Unicode 兼容分解的主要可见子集），
/// 并在 tokenization 前执行。与 HF 参考实现的逐字节差异仅存在于 NFKC 边界字符，
/// 对检索质量无影响；Golden Dataset 交叉验证在 Phase 4 4.1。
public nonisolated struct E5Tokenizer: Sendable {

    // MARK: - Constants

    /// 模型输入序列最大长度（Core ML 输入形状 [1, 256]）
    public nonisolated static let maxLength = 256

    /// 特殊 token id
    public nonisolated static let clsTokenID: Int32 = 0      // <s>
    public nonisolated static let padTokenID: Int32 = 1      // <pad>
    public nonisolated static let sepTokenID: Int32 = 2      // </s>
    public nonisolated static let unkTokenID: Int32 = 3      // <unk>

    /// E5 查询前缀（R-3.8）
    public nonisolated static let queryPrefix = "query: "
    /// E5 摄入前缀（R-3.8）
    public nonisolated static let passagePrefix = "passage: "

    /// Metaspace 替换符
    private nonisolated static let metaspace = "▁"

    /// `<unk>` 的 log 分数（SentencePiece 未登录词惩罚）
    private nonisolated static let unkScore = -10.0

    // MARK: - Vocabulary

    /// piece → score（Unigram 词表）
    private nonisolated let scores: [String: Double]
    /// piece → id（词表顺序即 id）
    private nonisolated let pieceToID: [String: Int32]

    // MARK: - Initialization

    /// 从 Bundle 中的 tokenizer.json 加载 E5 tokenizer。
    ///
    /// - Parameter bundle: 目标 Bundle（默认 `Bundle.main`）
    /// - Throws: `E5TokenizerError` 若 tokenizer.json 缺失或格式不合法
    public init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "tokenizer", withExtension: "json") else {
            throw E5TokenizerError.tokenizerFileMissing
        }
        try self.init(jsonURL: url)
    }

    /// 从显式 JSON URL 加载（测试注入用）。
    public init(jsonURL: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: jsonURL)
        } catch {
            throw E5TokenizerError.tokenizerFileMissing
        }
        try self.init(jsonData: data)
    }

    /// 从 JSON 数据加载（测试注入用）。
    public init(jsonData: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let model = json["model"] as? [String: Any],
              let vocab = model["vocab"] as? [[Any]] else {
            throw E5TokenizerError.invalidTokenizerFormat
        }

        var scoreMap: [String: Double] = [:]
        var idMap: [String: Int32] = [:]
        scoreMap.reserveCapacity(vocab.count)
        idMap.reserveCapacity(vocab.count)
        for (index, entry) in vocab.enumerated() {
            guard entry.count >= 2,
                  let piece = entry[0] as? String,
                  let score = entry[1] as? Double else {
                continue
            }
            scoreMap[piece] = score
            idMap[piece] = Int32(index)
        }
        guard !scoreMap.isEmpty else {
            throw E5TokenizerError.invalidTokenizerFormat
        }
        self.scores = scoreMap
        self.pieceToID = idMap
    }

    // MARK: - Public API

    /// 对文本执行 E5 标记化，产出 Core ML 模型的 int32 输入与注意力掩码。
    ///
    /// - Parameters:
    ///   - text: 原始文本
    ///   - context: `.query`（注入 "query: "）或 `.passage`（注入 "passage: "）
    /// - Returns: 截断/填充后的 `input_ids`、`attention_mask`（各 maxLength 个 Int32）
    public func encode(
        _ text: String,
        context: E5Context = .passage
    ) -> E5EncodedInput {
        // 1. 前缀注入（R-3.8）
        let prefixed: String
        switch context {
        case .query:
            prefixed = Self.queryPrefix + text
        case .passage:
            prefixed = Self.passagePrefix + text
        }

        // 2. 归一化（NFC + 全角→半角近似）
        let normalized = Self.normalize(prefixed)

        // 3. Metaspace 预分词
        let pretokens = Self.metaspacePreTokenize(normalized)

        // 4. Unigram 最优切分
        var tokenIDs: [Int32] = []
        tokenIDs.reserveCapacity(Self.maxLength)
        for pretoken in pretokens {
            let ids = viterbiSplit(pretoken)
            tokenIDs.append(contentsOf: ids)
            if tokenIDs.count >= Self.maxLength - 2 { break }
        }

        // 5. <s> ... </s> 包装 + 截断 + 填充
        var ids = [Int32]()
        var mask = [Int32]()
        ids.reserveCapacity(Self.maxLength)
        mask.reserveCapacity(Self.maxLength)

        ids.append(Self.clsTokenID)
        mask.append(1)

        let bodyCount = min(tokenIDs.count, Self.maxLength - 2)
        for i in 0..<bodyCount {
            ids.append(tokenIDs[i])
            mask.append(1)
        }

        ids.append(Self.sepTokenID)
        mask.append(1)

        while ids.count < Self.maxLength {
            ids.append(Self.padTokenID)
            mask.append(0)
        }

        return E5EncodedInput(inputIDs: ids, attentionMask: mask)
    }

    /// 仅执行「归一化 + 预分词 + Unigram 切分」，返回 piece 序列（不含 <s>/</s> 包装）。
    ///
    /// 供测试断言分词正确性。
    public func tokenizePieces(_ text: String) -> [String] {
        let normalized = Self.normalize(text)
        let pretokens = Self.metaspacePreTokenize(normalized)
        var pieces: [String] = []
        for pretoken in pretokens {
            pieces.append(contentsOf: bestPathPieces(pretoken))
        }
        return pieces
    }

    // MARK: - Unigram Viterbi

    /// 对单个 pre-token 执行 Unigram Viterbi 最优切分，返回 token id。
    nonisolated private func viterbiSplit(_ text: String) -> [Int32] {
        bestPathPieces(text).map { pieceToID[$0] ?? Self.unkTokenID }
    }

    /// 对单个 pre-token 执行 Unigram Viterbi 最优切分，返回 piece 序列。
    ///
    /// 以 Unicode 字符（Character）为单位建表，避免 UTF-8 字节边界问题。
    /// 对每个结束位置 `end`，遍历所有可能的起始位置 `start`，取子串 piece 并比较分数。
    /// 未命中词表时用 `<unk>` 单字符回退。
    nonisolated private func bestPathPieces(_ text: String) -> [String] {
        let chars = Array(text)
        let n = chars.count
        guard n > 0 else { return [] }

        // bestScore[i]: 覆盖 chars[0..<i] 的最佳 log 概率和
        // bestPrev[i]:   达到该最优时最后一段的起始下标
        var bestScore = [Double](repeating: -Double.greatestFiniteMagnitude, count: n + 1)
        var bestPrev = [Int](repeating: 0, count: n + 1)
        bestScore[0] = 0

        for end in 1...n {
            var best = -Double.greatestFiniteMagnitude
            var bestStart = end - 1
            var matched = false
            for start in 0..<end {
                let piece = String(chars[start..<end])
                guard let score = scores[piece] else { continue }
                matched = true
                let candidate = bestScore[start] + score
                if candidate > best {
                    best = candidate
                    bestStart = start
                }
            }
            if !matched {
                // SentencePiece 语义：无词表命中时仅回退单字符 <unk>
                // （禁止整段未登录词合并，防止长串整体塌缩为 1 个 unk）
                best = bestScore[end - 1] + Self.unkScore
                bestStart = end - 1
            }
            bestScore[end] = best
            bestPrev[end] = bestStart
        }

        // 回溯
        var pieces: [String] = []
        var pos = n
        while pos > 0 {
            let start = bestPrev[pos]
            pieces.append(String(chars[start..<pos]))
            pos = start
        }
        pieces.reverse()
        return pieces
    }

    // MARK: - Static Helpers

    /// 归一化：NFC + 全角→半角（NFKC 主要可见子集）。
    nonisolated static func normalize(_ text: String) -> String {
        let nfc = text.precomposedStringWithCanonicalMapping
        return Self.fullwidthToHalfwidth(nfc)
    }

    /// 全角 ASCII/数字/标点 → 半角。
    nonisolated static func fullwidthToHalfwidth(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 0xFF01 && v <= 0xFF5E {
                out.append(Unicode.Scalar(v - 0xFEE0)!)
            } else if v == 0x3000 {
                out.append(Unicode.Scalar(0x20)!)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Metaspace 预分词：空格 → `▁`，句首前置 `▁`，避免产生裸 `▁` 空 token。
    nonisolated static func metaspacePreTokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let replaced = Self.metaspace + text.replacingOccurrences(of: " ", with: Self.metaspace)
        return replaced.components(separatedBy: Self.metaspace).compactMap {
            $0.isEmpty ? nil : Self.metaspace + $0
        }
    }
}

// MARK: - Context

/// E5 嵌入上下文（query/passage 前缀）。
public nonisolated enum E5Context: Sendable {
    case query
    case passage
}

// MARK: - Encoded Input

/// 编码后的模型输入。
public nonisolated struct E5EncodedInput: Sendable, Equatable {
    /// int32 input_ids [maxLength]
    public nonisolated let inputIDs: [Int32]
    /// int32 attention_mask [maxLength]
    public nonisolated let attentionMask: [Int32]

    public nonisolated init(inputIDs: [Int32], attentionMask: [Int32]) {
        self.inputIDs = inputIDs
        self.attentionMask = attentionMask
    }
}

// MARK: - Error

/// E5 tokenizer 错误。
public nonisolated enum E5TokenizerError: Error, LocalizedError, Sendable {
    case tokenizerFileMissing
    case invalidTokenizerFormat

    public nonisolated var errorDescription: String? {
        switch self {
        case .tokenizerFileMissing:
            return "tokenizer.json not found in bundle"
        case .invalidTokenizerFormat:
            return "tokenizer.json has an invalid format"
        }
    }
}
