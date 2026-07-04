# ADR-004: 端侧模型选型刷新 — 2026-07 全面升级

**状态**: 已接受
**日期**: 2026-07-04
**决策人**: AI 架构师 (Agent)

## 背景

Echo v4.6 技术选型文档中的四个端侧模型选型基于 2024 年技术栈：
- 视觉编码：SigLIP-SO400M (INT4) 主力 + MobileCLIP-B 降级
- 语音转写：Whisper.cpp base INT4
- 文本嵌入：GTE-Qwen2-1.5B-Instruct INT4

2025-2026 年期间，三个领域均出现了显著更优的替代方案。经 librarian Agent 全面调研（2026-07-04），确认当前选型已全面过时。

## 决策

### 视觉编码：SigLIP-SO400M + MobileCLIP-B → MobileCLIP2-S4（单模型）

**理由**：
- MobileCLIP2-S4 (Apple, TMLR 2025-08) IN-1k 81.9% 与 SigLIP-SO400M 82.0% 持平
- 参数量 445M（SigLIP 878M 的 50%），iPhone 12 Pro Max 实测延迟 19.6ms
- 单模型同时满足质量+速度需求，取消双模型策略
- 嵌入维度从 1152d → 768d，需重建 ProximaKit HNSW 索引（一次性成本）
- SigLIP 2 因 Gemma2 词表导致文本编码器 708M 参数，不适配端侧打包

### 语音转写：Whisper.cpp base INT4 → SenseVoice Small GGUF

**理由**：
- 中文 CER 从 31.3% 降至 8.0%（提升 3.9×）
- 体积从 150MB 降至 129MB（更小）
- 使用 SenseVoice.cpp（ggml + Metal），集成模式与 whisper.cpp 一致
- 内置语言检测、情感识别、50+ 语言支持
- Apple SpeechAnalyzer 因首次启动需网络下载模型（违反 R-005）被排除
- 许可：SenseVoice Model License（需生产部署前确认兼容性）

### 文本嵌入：GTE-Qwen2-1.5B-Instruct → Qwen3-Embedding-0.6B

**理由**：
- 同一团队（阿里巴巴 Qwen）的自然升级，训练哲学一致
- 参数从 1.5B 降至 0.6B（-60%），体积从 900MB 降至 ~400-500MB
- 中文 CMTEB-R 从 ~65-67 提升至 71.02
- Matryoshka 原生支持 1024d → 768d 截断（GTE-Qwen2 无此能力）
- Core ML 社区导出已验证存在
- EmbeddingGemma-300M 为备选（2K 上下文限制不利）

## 影响

| 维度 | 旧方案 | 新方案 | Δ |
|------|--------|--------|:---:|
| 模型总数 | 4 个 | 3 个 | -1 |
| 预估总体积 | ~1,600MB | ~1,000MB | **-37%** |
| 视觉模型数量 | 2 (主+降级) | 1 | -1 |
| 中文 ASR CER | 31.3% | 8.0% | **-74%** |
| 文本嵌入尺寸 | 900MB | 450MB | **-50%** |
| 视觉嵌入维度 | 1152d | 768d | 需迁移索引 |
| 运行时引擎 | Core ML + Whisper.cpp | Core ML + SenseVoice.cpp | 替换 |

## 后果

### 正面
- App 体积显著缩小（-600MB），用户体验更佳
- 中文 ASR 准确率质的飞跃（31%→8% CER）
- 架构简化：取消视觉双模型策略，减少复杂性
- 推理速度全面优化（SenseVoice 非自回归编码器）

### 需处理
- 向量索引维度迁移（1152d→768d），需在 Phase 1 完成
- SenseVoice 许可协议确认（FunASR Model License vs MIT）
- SenseVoice.cpp 集成替代 whisper.cpp 需要适度工程投入
- 规格书 AC 中引用的旧模型名称需后续同步更新（如 US-RES-002 引用的 MobileCLIP-B）

## 参考

- `docs/02-architecture/技术选型文档.md` v5.1
- MobileCLIP2 论文 (TMLR 2025-08): https://arxiv.org/abs/2508.20691
- Qwen3-Embedding: https://huggingface.co/Qwen/Qwen3-Embedding-0.6B
- SenseVoice.cpp: https://github.com/lovemefan/SenseVoice.cpp
- Echo AGENTS.md v5.7 §1.2 绝对红线 R-005
