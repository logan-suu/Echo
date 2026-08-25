# ADR-015: 自然语言照片检索——配对 SigLIP2 双塔契约与多通道路由事实统一

**状态**: 提议中（等待 Gate A：Product 与 Architecture 批准；七类责任人共同签署 release evidence manifest）
**日期**: 2026-08-25
**决策人**: AI 架构师（起草）；待 Product / Model / QA / iOS / Privacy / Release / Legal 会签
**来源**: 《Echo 自然语言照片检索实施交接计划》（2231 行）§2/§5/§6；漂移核验账本 `.omo/evidence/photo-text-search/EVIDENCE_LEDGER.md` E-DRIFT-001/002/003（21/21 声明 HOLDS @ HEAD 18784ea）

---

## 背景

照片无法被自然语言文本检索命中。根因树（交接计划 §4，六项必须联合修复）：

| 根因 | 已证事实（本仓库逐字核验） |
| --- | --- |
| A 无对齐视觉查询 | E5(384d) 与 SigLIP2(768d) 空间分离（troubleshooting 文档 §2）；`SigLIP2Embedder.embedText` 故意 throw（SigLIP2Embedder.swift:81-85） |
| B 生产不调多通道 | `searchMultiChannel` 唯一 caller 是测试（SearchPipeline.swift:803-867；3F.6 测试 :338），生产 UI 仅组装活跃文本 store（SearchViewModel.swift:221-310 / LiveAppAdapters.swift:24-42） |
| C 多通道契约不安全 | 所有 dense 通道共享一个 optional queryVector（SearchPipeline.swift:821,831-832）；缺失向量变零向量（SearchChannelAdapters.swift:246）；hydration 只解码 legacy MemoryEntry 且解码失败静默丢命中（同文件 :265） |
| D 视觉转换不等价官方 | convert_siglip2.py forward(:161-207) 存在多余 probe residual（:197 `probe_out = probe_out + probe`）且用精确 `F.gelu`（:200）而非 checkpoint 的 tanh 近似；参考向量由同一自定义图生成（:289-326 循环验证），其 `"revision": "main"` 未固定 commit hash |
| E 身份与生命周期缺陷 | 视频帧 vector ID ≠ representationId（IngestPipeline.swift:1313 vs CanonicalMemory.swift:116 默认随机 UUID）；删除只按父 memoryId 删向量（CanonicalMemoryRepositoryActor.swift:244/256）；回滚只记 previousTextGeneration（ActiveRouteSet.swift:38；GenerationRegistryActor.swift:403/411）；设备迁移只重建文本向量（DeviceMigrationActor.swift:445-449） |
| F 门禁产生假信心 | ci.yml:73 `continue-on-error: true` 容忍模型准备失败；3F.3a 八处 guard+bare-return 静默跳过真实推理测试；IndexGeneration.init 维度默认 512（IndexGeneration.swift:77）且 AppDelegate 三处硬编码 512d（:130/:144/:180）、DB 列 DEFAULT 512（DatabaseManager.swift:261） |

## 决策

### D-1 每通道原生查询表示 【native-per-channel-queries】

每个检索通道只接受其声明的原生查询 payload：

- `text_dense` / `ocr_text`：E5 384d，显式 `.query` context（协议层暴露 query/passage 区分；生产搜索不得再默认 passage）
- `vision_dense`：由与图像塔**同一 checkpoint、同一对齐空间**的配对 SigLIP2 **文本塔**生成 768d 查询向量
- `lexical`：原始查询文本 + locale

禁止把 E5 向量 padding/截断/投影进视觉空间；E5 继续独占文本记忆嵌入。

### D-2 canonical 身份融合 【canonical-id-fusion-before-rrf】

RRF 融合 key 必须是 canonical `memoryId`，绝不使用裸 vector ID。每个原始命中先经 `vectorId → Representation → memoryId` 映射并批量 hydrate；映射缺失或歧义时 fail-closed 排除该命中并写入 hash-only 计数审计。禁止跨通道相加 cosine/BM25/规则分数。

### D-3 完整路由快照回滚 【complete-route-snapshot-rollback】

路由发布以完整快照为原子单位：全部通道 generation + 查询模型 manifest + 对齐空间 ID + 融合策略 + schema version + 前序快照引用。持久化使用按 `SearchChannel.rawValue` 排序的 array（拒绝重复 channel）与 canonical encoder，digest 为 canonical bytes 的 SHA-256（排除递归 validationDigest 字段）。回滚恢复完整前序快照，而非仅文本 generation。替换 ActiveRouteSet 仅含 `previousTextGeneration` 的部分回滚模型。

### D-4 修正视觉计算图并强制重建索引 【corrected-vision-graph-mandatory-reindex】

当前 Echo 视觉计算图（h = LN(A + probe)；out = A + probe + MLP(h)；精确 GELU）不等于 pinned 上游官方链（h = LN(A)；out = A + MLP(h)；tanh 近似 GELU）。因此：

1. 当前所有视觉向量（照片、视频帧）一律不具备复用资格；
2. 转换脚本必须修正为官方链后重新导出双塔；
3. 照片与视频帧必须在 shadow generation 中全量重建；
4. 参考向量必须改由 pinned revision（非 "main"）的上游独立实现生成，消除循环验证。

精确固定候选：`google/siglip2-base-patch32-256@94dffa8cb1179de3e03f091dbc3917e5d5a9ae84`（词表 256,000；文本塔参数量 282,303,744）。禁止替换为 32k 词表近似 checkpoint。

### D-5 仅离线工件 【offline-only-model-artifacts】

模型、tokenizer、索引、数据集全部随包本地分发或本地生成；运行时零下载、零遥测（R-001/R-005 红线不变）。FP16 文本塔原始 payload ≈538.45 MiB 是权重测量值，禁止冒充 App 包体结论；包体/延迟/内存/热/能耗结论只能来自 Release archive 与物理设备实测。

### D-6 类型化通道隔离（不变量）

通道结果只能是 `.success/.empty/.skipped/.timedOut/.failed` 之一；payload 缺失返回 `.skipped(.payloadUnavailable)`，绝不做零向量搜索；单个不健康通道不得抹除健康通道结果。

### D-7 新向量身份绑定（不变量)

新建向量强制 `vectorId == representationId`，每个 Representation 一对一映射到 canonical memoryId；迁移前 legacy 向量无歧义可映射者才可参与，否则 fail-closed。

### D-8 能力禁用直至发布门禁通过 【capability-disabled-until-release-gates】

在 WP7 全部门禁（质量/设备/法律/CI/回滚演练）获批并由七类责任人签署 route snapshot + artifact hash 之前：能力保持 feature-disabled，产品文案不得声明支持，troubleshooting 文档的限制状态不得更改。

---

## 备选方案

- **Caption-to-E5（VLM 配文入文本空间）**：保留为备选，需单独批准运行时与质量契约（计划 §1.2 非目标）。
- **E5→SigLIP 投影网络**：无已批准成对训练数据，禁止未经训练的 projection（§11 禁止捷径 3/4）。
- **仅接通 RRF 即宣布修复**：不成立——视觉通道缺有效文本查询，B 单修无效（根因 A-F 必须联合）。
- **CLIP 风格联合模型整体替换**：推翻既有技术选型与已交付 SigLIP2 资产，代价高于配对文本塔路径（troubleshooting 文档「未来路径」对比）。

## 后果

正面：自然语言→照片检索成为可达能力；身份/删除/回滚缺陷一次性补齐；CI 假信心通道关闭；三份台账（规格正文 / 故事矩阵 / 证据索引）与代码现实一致。

负面/风险：文本塔 FP16 payload 约 538 MiB 需量化候选评估；全量视觉重建是长任务（TaskQueueActor 串行 + ProgressActor 断点续传）；legacy AuditLog 无法确定性关联 subject 的记录须按 Privacy/Legal 批准 fail-closed 清理（禁止猜测回填）；所有数值门禁均为临时提议，生效需责任人批准。

## 参考

- 交接计划 §2.3 固定上游 URL（config.json / modeling_siglip.py L1114-L1135 / big_vision README / coremltools 指南 ×2）
- docs/06-troubleshooting/照片文本搜索架构限制-跨模态对齐缺失.md（WP7 门禁通过后方可变更限制状态）
- ADR-006/ADR-009/ADR-010（空间分离原则、离线模型运行时、canonical generation 生命周期——本 ADR 为其修订扩展而非推翻）
- deferred-items.json：DEF-35-001（revision 未固定）、DEF-54-001（CI 静默跳过）由本 ADR 关联工作正式关闭
