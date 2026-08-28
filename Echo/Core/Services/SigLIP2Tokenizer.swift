// ==========================================
// 文件: SigLIP2Tokenizer.swift
// 对应规格: 交接计划 §WP4 步骤 1c/1d（visionDense 原生 payload 的分词前置）+ WP2 §7.2 精确 tokenizer
// 任务: WP4 5c/5d - SigLIP2 文本塔生产接线
// 架构约束: nonisolated Sendable 值类型；与基准 harness 同源契约
//           （SigLIP2TextBasePatch32.mlmodelc 输入 int32[1,64]，fixture 交叉验证
//            "red flower" → [854, 10377, 1] + <pad> 补齐）
// 生成时间: 2026-08-25
// ==========================================

import Foundation

/// SigLIP2 Gemma 式 BPE 分词器（tokenizer.json: model.type=BPE + byte_fallback + fuse_unk，无 UNK）。
///
/// 流程：空格→▁ 归一化 → Unicode scalar BPE 合并（merges 列表序即优先级）→
/// 词表查 id（未命中走 <0xXX> byte fallback）→ 追加 <eos>=1 → 截断/补齐 64。
/// 与 Python 侧 pytest fixture 交叉验证：`"red flower"` → `[854, 10377, 1]`。
public nonisolated struct SigLIP2Tokenizer: Sendable {

    /// Core ML 输入序列长度（int32[1,64] 固定形状）
    public nonisolated static let maxLength = 64
    public nonisolated static let padTokenID: Int32 = 0
    public nonisolated static let eosTokenID: Int32 = 1

    /// piece → id
    private nonisolated let vocab: [String: Int32]
    /// UTF-8 字节 → byte-fallback token id（<0xXX>）
    private nonisolated let byteTokenIDs: [UInt8: Int32]
    /// merge 对 → 优先级（列表序，越小越先合并）
    private nonisolated let mergeRanks: [String: Int32]

    public init(tokenizerJSON: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: tokenizerJSON) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let vocabRaw = model["vocab"] as? [String: Any],
              let mergesRaw = model["merges"] as? [[Any]] else {
            throw SigLIP2TokenizerError.malformedTokenizer("missing model/vocab/merges")
        }

        var vocab: [String: Int32] = [:]
        vocab.reserveCapacity(vocabRaw.count)
        var bytes: [UInt8: Int32] = [:]
        for (piece, idValue) in vocabRaw {
            let id: Int32
            if let n = idValue as? Int {
                id = Int32(n)
            } else if let d = idValue as? Double {
                id = Int32(d)
            } else {
                continue
            }
            vocab[piece] = id
            if piece.hasPrefix("<0x"), piece.hasSuffix(">"), piece.count == 6 {
                let hex = piece.dropFirst(3).dropLast()
                if let byte = UInt8(hex, radix: 16) {
                    bytes[byte] = id
                }
            }
        }
        guard !vocab.isEmpty else {
            throw SigLIP2TokenizerError.malformedTokenizer("empty vocab")
        }
        self.vocab = vocab
        self.byteTokenIDs = bytes

        var ranks: [String: Int32] = [:]
        ranks.reserveCapacity(mergesRaw.count)
        for (index, pair) in mergesRaw.enumerated() {
            guard pair.count == 2,
                  let first = pair[0] as? String,
                  let second = pair[1] as? String else { continue }
            ranks[first + "\u{1}" + second] = Int32(index)
        }
        self.mergeRanks = ranks
    }

    /// 编码为固定 64 长度序列：内容 token + <eos>，<pad> 补齐（超长截断保留 <eos> 尾）。
    public func encode(_ text: String) -> [Int32] {
        var ids = encodeContent(text)
        ids.append(Self.eosTokenID)
        if ids.count > Self.maxLength {
            ids = Array(ids[0..<(Self.maxLength - 1)]) + [Self.eosTokenID]
        }
        while ids.count < Self.maxLength {
            ids.append(Self.padTokenID)
        }
        return ids
    }

    /// 内容编码：归一化 → BPE → 词表/byte fallback。
    nonisolated func encodeContent(_ text: String) -> [Int32] {
        let normalized = text.replacingOccurrences(of: " ", with: "\u{2581}")
        let symbols = bpe(normalized.unicodeScalars.map { String($0) })
        var ids: [Int32] = []
        ids.reserveCapacity(symbols.count)
        for symbol in symbols {
            if let id = vocab[symbol] {
                ids.append(id)
            } else {
                for byte in symbol.utf8 {
                    if let id = byteTokenIDs[byte] {
                        ids.append(id)
                    }
                }
            }
        }
        return ids
    }

    /// 标准 BPE：反复合并 rank 最小（merges 序最靠前）的相邻符号对。
    private func bpe(_ scalars: [String]) -> [String] {
        guard scalars.count > 1 else { return scalars }
        var symbols = scalars
        while symbols.count > 1 {
            var bestRank = Int32.max
            var bestIndex = -1
            for index in 0..<(symbols.count - 1) {
                let key = symbols[index] + "\u{1}" + symbols[index + 1]
                if let rank = mergeRanks[key], rank < bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { break }
            symbols[bestIndex] = symbols[bestIndex] + symbols[bestIndex + 1]
            symbols.remove(at: bestIndex + 1)
        }
        return symbols
    }
}

/// 分词器错误（fail-closed 语义）。
public enum SigLIP2TokenizerError: Error, Equatable, Sendable {
    case malformedTokenizer(String)
}
