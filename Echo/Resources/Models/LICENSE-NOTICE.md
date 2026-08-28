# Echo · 回响 — 第三方模型许可声明（License Notice）

本应用随安装包分发以下端侧模型工件。所有推理在设备本地完成，任何模型数据不离开设备（R-005）。

## SigLIP2（视觉/文本双塔）

- 来源：google/siglip2-base-patch32-256 @ `94dffa8cb1179de3e03f091dbc3917e5d5a9ae84`（不可变 pin，DEF-35-001）
- 许可：**Apache License 2.0**
- 本应用的 `.mlmodelc` 工件为该 checkpoint 的衍生转换（`Scripts/convert_siglip2.py`）
- 依据 Apache-2.0 再分发：随附许可原文、保留 NOTICE 与变更声明

## multilingual-e5-small（文本嵌入）

- 来源：intfloat/multilingual-e5-small（上游）；Core ML 工件经 `tamikisg/multilingual-e5-small-coreml` 转换（法律审查项 Q1）
- 许可：**MIT License**（上游）
- 工件：`MultilingualE5Small.mlpackage` + `tokenizer.json`

## Whisper tiny（语音识别）

- 来源：OpenAI whisper-tiny（MIT）经 ggml-org/whisper.cpp 转换（GGUF Q5_1）
- 许可：**MIT License**；运行时 vendored 于 `ThirdParty/whisper.cpp/`（随附其 LICENSE）

## 生成信息

- 本文件由 WP7 步骤 9g/9h 的 license-notice gate 引用（`manifest.requiredArtifacts.licenseNoticeFile`）
- 法律审查材料包：`.omo/evidence/photo-text-search/legal-review-package.md`
