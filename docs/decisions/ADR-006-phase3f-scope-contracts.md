# ADR-006: Phase 3F 范围契约（规格无效故事修正与 AC 修订）

**状态**: 已接受
**日期**: 2026-08-04
**决策人**: Product and Architecture Lead（审批）+ Technical Program Lead（实现）

## 背景

基线审计（2026-08-03）显示 66 个故事中 **14 个为 Impossible/spec-invalid**、16 个 Partial、25 个 Stub、9 个 Absent/unmapped、2 个 Deferred、0 个生产完成。其中 14 个无效故事要求私有/不存在的 Apple API（iMessage 历史读取、自动 Notes 读取、自动语音备忘录读取、精确 09:00 后台调度、People 身份）或自相矛盾的 AC（E5 文本空间 vs CLIP 查询向量、保留已删除的人物维度、30 天导出 ≤5MB 无分页规则、5 秒级联删除时序）。这些 AC 无法在 iOS 公开 API 能力内按字面接受。

## 决策

Phase 3F 以人类批准的规格修订（本 ADR + 指令 §3F.0 checklist）冻结范围：

1. **Notes/Voice 仅 share-only**：备忘录与语音备忘录的摄入只通过用户主动的 Share Extension 分享，禁止自动读取系统 Notes/Voice Memos 存储。
2. **iMessage 自动历史与 People 身份移出 v1**：US-SRC-002、US-SRC-006 不进入 v1；SRC-006 已有 DEF-35-002 记录（v1.x 目标）。
3. **调度为 earliest-eligible/best-effort**：放弃「精确每日 09:00 后台执行」保证（iOS 无法保证），改为最早可用窗口尽力调度。
4. **E5 384d 文本与 SigLIP2 视觉保持独立 generation**：禁止文本/视觉空间对齐（删除 ING-004 的 CLIP 空间要求），每个模型空间独立 generation + VectorStoreActor。
5. **审计导出使用有界分页/分片**：替换「30 天完整导出 ≤5MB 且无限制」的不可落地 AC。
6. **Notes 交接仅用系统 share/export**：禁止 `notes://echo/...` 深链与私有 NoteStore 直写。
7. **离线 LLM 决策**：见 ADR-009——保留 grounded creation，采用不可变捆绑运行时 + Language Aligner。
8. **US-SRC-007/009/010/011 显式归属**：SRC-007→3F.7、SRC-009→3F.7+3F.10（并入 US-SYS-001）、SRC-010→3F.6+3F.8+3F.11、SRC-011→3F.3+3F.6+4.1，均不使用延期路径。

## 备选方案

| 方案 | 描述 | 结论 |
|------|------|------|
| **A（采纳）** | 按上述 8 项修订 AC 并冻结范围，66 故事全部获得显式归属或批准移除 | ✅ 每个故事可落地、可验证、可追溯 |
| B | 保留原 AC 字面要求，标注 🔮 等待未来 API | ❌ 维护不可验证的验收条件，Phase 4 无法通过 |
| C | 把 14 个无效故事全部延期到 v1 外 | ❌ 覆盖真实产品能力（Notes/Voice share、E5/SigLIP2 分离是 P0 核心），延期范围过大 |

## 后果

### 正面

- 全部 66 故事获得 owner 或批准记录（story matrix gate 66/66）。
- 消除「fixture 充当生产证据」与「不可验证 AC」两类根本缺陷。
- Phase 3F 生产闭环（同意→来源→模型→存储→摄入→检索→反馈→编辑→唤醒→翻译/创作→重启）全部可落地。

### 负面

- iMessage/People 自动能力明确不在 v1，需要产品侧接受能力边界。
- 定时唤醒为 best-effort，用户感知的精确时刻可能漂移。
- 全部 66 故事的 AC 修订必须同步到规格书、双语言文档、契约与 Golden Dataset。

## 参考

- `docs/01-spec/用户故事与验收标准规格书.md`（14 个 spec-invalid 故事 AC）
- `docs/05-planning/phase3f-execution-plan.md` §3F.0 checklist 与 §4.2.1
- `docs/05-planning/phase3f-story-matrix.md`（66-story 校准矩阵）
- `docs/05-planning/deferred-items.json` DEF-35-002（US-SRC-006 v1.0 移除）
