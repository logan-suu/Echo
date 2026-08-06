# Model Provenance Register（模型溯源登记册）

**版本**: 1.0.0
**创建**: 2026-08-06（任务 3F.3）
**维护规则**: 每个捆绑工件必须登记；manifest → bundle → register 计数 100%；哈希全部可验证；未获批模型不得进入打包（ADR-009 决策 2）。

---

## 0. 快速核对表（Manifest → Bundle → Register 100%）

| # | modelId | Bundle 文件 | SHA-256（model_checksums.sha256） | Register § | 审批状态 |
|---|---------|------------|-----------------------------------|-----------|----------|
| 1 | `e5-multilingual-small-v1` | `MultilingualE5Small.mlpackage/Manifest.json` | `af2f01cb…edca11b9` | §1 | ⚠️ 工程暂定（法律审查） |
| 2 | `e5-multilingual-small-v1`（tokenizer） | `tokenizer.json` | `cd98e569…68d932` | §1.2 | ⚠️ 工程暂定（随模型） |
| 3 | `whisper-tiny-q5_1-v1` | `whisper-tiny-q5_1.gguf` | `81871056…69c3d7` | §2 | ✅ 已批准（R-5.4） |
| 4 | `siglip2-base-patch32-256-v1` | `siglip2-base-patch32-256/model.safetensors` | `7d241bb3…a301f1` | §3 | ⚠️ 转换源待转换+审批 |

> **计数**：manifest 声明 3 个工件，bundle 实际 3 个工件（4 行含 tokenizer 附属件），register 登记 3 个主工件。**计数 100%**，`bash Scripts/prepare_models.sh --verify-only` 全部校验通过（2026-08-06）。

---

## 1. multilingual-e5-small（文本嵌入）

### 1.1 工件清单

| 字段 | 值 |
|------|-----|
| **modelId** | `e5-multilingual-small-v1` |
| **用途** | 文本语义嵌入（384d，query/passage 前缀） |
| **来源** | HuggingFace `tamikisg/multilingual-e5-small-coreml` |
| **Revision** | `main`（可变 ref，SHA-256 锁定内容完整性；不可变 commit hash 固定追踪于 DEF-35-001，网络可用时回填） |
| **Bundle 文件** | `MultilingualE5Small.mlpackage`（含 `Manifest.json`） |
| **SHA-256** | `af2f01cb5f0cbf22832c9cec2881ea730df4eb65ecd20334245cf823edca11b9`（Manifest.json） |
| **运行时** | Core ML（`.mlpackage` → 编译 `.mlmodelc`，`CoreMLInferenceAdapter`） |
| **转换 lineage** | HF `multilingual-e5-small`（intfloat）→ Core ML 导出（tamikisg 提供 `.mlpackage`）→ Xcode 编译 |
| **运行时许可证** | MIT（tamikisg/multilingual-e5-small-coreml） |
| **权重上游许可证** | 源权重来自 `intfloat/multilingual-e5-small`（MIT）——下游含义交专业法律审查 |
| **NOTICE** | 见 §4 |
| **SBOM** | 见 §4 |
| **商业分发处置** | ⚠️ 工程暂定（legal review pending）；批准前不得进入生产打包 |
| **审批人/日期** | 待 Model Legal and Privacy Approver 批准 |

### 1.2 Tokenizer（附属工件）

| 字段 | 值 |
|------|-----|
| **来源** | 同仓库 `tokenizer.json`（Unigram / SentencePiece，Metaspace 预分词） |
| **Bundle 文件** | `tokenizer.json` |
| **SHA-256** | `cd98e5698b201ba914efb8c18b6709fa8735ab71dcad8d2b431e52e8bf68d932` |
| **许可证** | 随模型仓库（MIT） |
| **消费方** | `E5Tokenizer`（`Echo/Core/Services/E5Tokenizer.swift`） |

### 1.3 参考输出

| 字段 | 值 |
|------|-----|
| **文件** | `Echo/Resources/Models/e5-reference-vectors.json` |
| **内容** | 4+ 条 384d L2 归一化参考向量（bilingual/query/passage 样本） |
| **用途** | US-SRC-011 model semantics；Golden 验证在 Phase 4 4.1 |
| **消费测试** | `ProductionModelInferenceTests.E5ReferenceVectors` |

---

## 2. Whisper tiny Q5_1（ASR）

### 2.1 工件清单

| 字段 | 值 |
|------|-----|
| **modelId** | `whisper-tiny-q5_1-v1` |
| **用途** | 语音转写（16kHz mono PCM → 文本） |
| **来源** | HuggingFace `ggml-org/whisper.cpp`（`ggml-tiny-q5_1.bin` → 重命名 `.gguf`） |
| **Revision** | `main`（R-5.4 批准 tiny；small 为挑战者不打包） |
| **Bundle 文件** | `whisper-tiny-q5_1.gguf` |
| **SHA-256** | `818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7` |
| **运行时** | whisper.cpp（C 互操作桥接 `WhisperRuntimeBridge`；运行时静态库接入前 fail-closed `runtimeNotLinked`） |
| **转换 lineage** | OpenAI Whisper tiny（MIT）→ GGML 量化 Q5_1（ggml-org 提供）→ 重命名 |
| **运行时许可证** | MIT（whisper.cpp） |
| **权重上游许可证** | MIT（OpenAI Whisper） |
| **NOTICE** | 见 §4 |
| **SBOM** | 见 §4 |
| **商业分发处置** | ✅ 已批准（R-5.4，2026-08-01） |
| **审批人/日期** | Model Legal and Privacy Approver / 2026-08-01 |

### 2.2 参考输出

| 字段 | 值 |
|------|-----|
| **文件** | `Echo/Resources/Models/whisper-reference-transcripts.json` |
| **内容** | 状态 `pending-runtime-integration`（whisper.cpp 运行时接入后回填真实转写样本） |
| **用途** | US-SRC-011 model semantics；Golden 验证在 Phase 4 4.1 |

---

## 3. SigLIP2-B/32（视觉嵌入）

### 3.1 工件清单

| 字段 | 值 |
|------|-----|
| **modelId** | `siglip2-base-patch32-256-v1` |
| **用途** | 图像语义嵌入（768d，独立 vision generation） |
| **来源** | HuggingFace `google/siglip2-base-patch32-256` |
| **Revision** | `main`（可变 ref，SHA-256 锁定内容完整性） |
| **Bundle 文件** | `siglip2-base-patch32-256/model.safetensors`（PyTorch 转换源） |
| **SHA-256** | `7d241bb3becad218f211f480487f491df4f8c0a472ecf7afdec5615815a301f1` |
| **运行时** | 目标 Core ML（`.mlmodelc`，`SigLIP2Embedder`）；当前为 PyTorch 转换源，Core ML 转换 pending |
| **转换 lineage** | Google SigLIP2-B/32（Apache-2.0）→ PyTorch checkpoint → coremltools 转换（未完成）→ Xcode 编译（未完成） |
| **运行时许可证** | Apache-2.0 |
| **NOTICE** | 见 §4 |
| **SBOM** | 见 §4 |
| **商业分发处置** | ⚠️ 转换源（`pending-conversion-and-approval`）；Core ML 转换完成 + 参考向量验证（余弦 >0.995）+ 审批后方可打包 |
| **审批人/日期** | 待 Model Legal and Privacy Approver 批准 |

### 3.2 参考输出

| 字段 | 值 |
|------|-----|
| **文件** | `Echo/Resources/Models/siglip2-reference-vectors.json` |
| **内容** | 状态 `pending-conversion`（Core ML 转换管线就绪后回填 768d 参考向量） |
| **用途** | US-SRC-011 model semantics；Golden 验证在 Phase 4 4.1 |

---

## 4. NOTICE / SBOM / 合规附件

### 4.1 NOTICE（随包分发声明）

- 位置：`Echo/Resources/Models/NOTICE.md`（随 3F.9 或打包前创建；当前模型未进入生产打包，暂缺）
- 内容要求：每个模型的版权声明、许可证全文引用、无担保声明

### 4.2 SBOM

- 位置：`Echo/Resources/Models/SBOM.json`（打包前创建；当前未进入生产打包，暂缺）
- 内容要求：工件 SHA-256、来源 URL、许可证 SPDX ID、转换工具链版本

### 4.3 合规规则（ADR-009 决策 2 强制执行）

1. 未登记工件不得进入打包
2. 未获批模型（`provenance: pending-*`）不得进入 Release 构建
3. 模型升级必须走「新 revision + 新审批」路径，禁止热替换
4. 每次 Phase 集成测试扫描本登记册，与 `model-manifest.json`、`model_checksums.sha256`、`prepare_models.sh` 三方核对

---

## 5. 变更历史

| 日期 | 变更 | 执行人 |
|------|------|--------|
| 2026-08-06 | 初始登记：E5/Whisper/SigLIP2 三工件 + tokenizer 附属件 | On-device ML Lead |
