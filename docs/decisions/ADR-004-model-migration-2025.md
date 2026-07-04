# ADR-004: 端侧模型选型刷新 — 2026-07 全面升级

**状态**: 已接受（v5.1b 最终可用方案）
**日期**: 2026-07-04
**决策人**: AI 架构师 (Agent)
**更新**: v5.1b — 基于 HuggingFace Core ML 模型实际可用性调整

## 背景

Echo v4.6 技术选型文档中的四个端侧模型选型基于 2024 年技术栈。经全面调研后，v5.1 提出 MobileCLIP2-S4 + Qwen3-Embedding-0.6B + SenseVoice 方案。实际操作中发现 MobileCLIP2-S4 和 Qwen3-Embedding-0.6B 均无公共 Core ML 导出，按实际可用性调整为 v5.1b 最终方案。

## 最终决策 (v5.1b)

### 视觉编码：MobileCLIP-B LT（`apple/coreml-mobileclip`）

- Apple 官方 Core ML 导出，IN-1k 77.2%，512d 嵌入
- Image 165MB + Text 121MB = 286MB
- MobileCLIP2-S4 (IN-1k 81.9%, 768d) 标记为 Phase 2 优化目标（待 `ml-mobileclip` 仓库更新 v2 架构）

### ASR：SenseVoice Small（保持不变）

- CoreML INT8 226MB + GGUF Q4_K 144MB + Preprocessor 2.9MB
- 中文 CER 8.0%，已验证可用

### 文本嵌入：multilingual-e5-small（`tamikisg/multilingual-e5-small-coreml`）

- **唯一公共可用的 Core ML 文本嵌入模型**，224MB，384d 嵌入
- 100+ 语言支持（zh/en/ja/ko 等）
- Qwen3-Embedding-0.6B 标记为 Phase 2 优化目标（需 PyTorch → Core ML 转换；`tooktang` 仓库实为 ExecuTorch/CoreAI 格式）
- BGE 等模型仅有 ONNX 导出，coremltools 9.0 已移除 ONNX 转换支持
- 384d 维度：纯文本检索无影响；跨模态检索需分离索引或零填充对齐

## 最终模型清单

| 模型 | 格式 | 体积 | 维度 |
|------|------|------|:---:|
| MobileCLIP-B LT (image) | Core ML | 165MB | 512d |
| MobileCLIP-B LT (text) | Core ML | 121MB | 512d |
| multilingual-e5-small | Core ML | 224MB | 384d |
| SenseVoice Small INT8 | Core ML | 226MB | - |
| SenseVoice Preprocessor | Core ML | 2.9MB | - |
| SenseVoice Small Q4_K | GGUF | 144MB | - |
| **总计** | | **883MB** | |

## Phase 2 优化目标

| 当前 | 目标 | 预期改进 |
|------|------|------|
| MobileCLIP-B LT (512d, 77.2%) | MobileCLIP2-S4 (768d, 81.9%) | 精度 +4.7%, 统一 768d |
| multilingual-e5-small (384d) | Qwen3-Embedding-0.6B (768d) | 中文 CMTEB +5pts, 统一 768d |

## 参考

- `docs/02-architecture/技术选型文档.md` v5.1b
- `apple/coreml-mobileclip` — https://huggingface.co/apple/coreml-mobileclip
- `tamikisg/multilingual-e5-small-coreml` — https://huggingface.co/tamikisg/multilingual-e5-small-coreml
- `FluidInference/sensevoice-small-coreml` — https://huggingface.co/FluidInference/sensevoice-small-coreml
