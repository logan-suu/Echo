# ADR-004: 端侧模型选型刷新 — 2026-07 全面升级

**状态**: 已接受（v5.1b 最终可用方案）→ **v6.0 路线重组（2026-08-01，部分取代 v5.1b）**
**日期**: 2026-07-04（v5.1b）/ 2026-08-01（v6.0）
**决策人**: AI 架构师 (Agent)
**更新**: v5.1b — 基于 HuggingFace Core ML 模型实际可用性调整；v6.0 — 基于《端侧模型选型与升级调研报告》决策 1~4 路线重组

## v6.0 路线重组（2026-08-01，取代 v5.1b 部分决策）

经三轮 ULW 调研（《Echo 端侧模型选型与升级调研报告（2026）》决策 1~4，2026-08-01 批准），v5.1b 模型路线重组：

| 模型 | v5.1b 决策 | v6.0 决策 | 原因 |
|------|-----------|----------|------|
| MobileCLIP-B LT | ✅ 视觉模型 | ❌ **淘汰** | 公共权重禁止商业使用（许可阻断，决策 4） |
| SenseVoice Small | ✅ ASR | ❌ **保守短名单排除** | FunASR 自定义条款 + 转换来源风险（决策 4） |
| multilingual-e5-small | ✅ 文本嵌入 | 🔶 **工程暂定（法律待审）** | MS MARCO 训练来源下游含义交专业法律审查 |
| SigLIP2-B/32 | — | 🔬 **视觉候选（挑战者）** | Apache-2.0，需 Core ML 自转换 + 四类门禁 |
| Whisper (GGUF) | ❌ 已弃用 | 🔬 **ASR 路线族** | bundled 官方衍生，工件链需分别审查 |
| Apple Vision OCR | — | ✅ **OCR 通道** | 系统框架，零新增模型包 |
| JiebaFTS5 + n-gram | — | 🔬 **词法通道** | 中文分词 + FTS5 |
| 加权 RRF 融合 | — | ✅ **多通道融合** | score=Σw_i/(k+rank_i)，k=60 |

### v6.0 模型清单（暂定）

| 模型 | 格式 | 体积 | 维度 | 状态 |
|------|------|------|:---:|------|
| multilingual-e5-small | Core ML | 224MB | 384d | 🔶 工程暂定 |
| Whisper small Q4_K | GGUF | ~244MB | - | 🔬 路线族 |
| SigLIP2-B/32 checkpoint | PyTorch | ~1.5GB | 768d | 🔬 候选（转换源） |

> 原 v5.1b 决策（MobileCLIP-B LT / SenseVoice）保留于下方作为历史记录，但已被 v6.0 取代。

------

## 背景

Echo v4.6 技术选型文档中的四个端侧模型选型基于 2024 年技术栈。经全面调研后，v5.1 提出 MobileCLIP2-S4 + Qwen3-Embedding-0.6B + SenseVoice 方案。实际操作中发现 MobileCLIP2-S4 和 Qwen3-Embedding-0.6B 均无公共 Core ML 导出，按实际可用性调整为 v5.1b 最终方案。

## 最终决策 (v5.1b)（已被 v6.0 部分取代，保留为历史记录）

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
