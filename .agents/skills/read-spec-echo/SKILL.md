---
name: read-spec-echo
description: "快速阅读并总结当前任务对应的规格文档（AC、架构约束），不写代码"
---

> Codex migration: This is a repository-scoped native skill. Follow the
> repository `AGENTS.md` as the authority. Treat any remaining GitHub API
> wording as the equivalent `gh` CLI operation supported by the current
> environment. Never weaken human-only approval, PR merge, branch retention,
> privacy, or release gates. A sandboxed `gh auth status` failure is
> inconclusive. Apply the two-stage, read-only verification in `AGENTS.md`
> §15; request re-authentication only after an explicit credential rejection.


## 📖 规格速读

请按 Echo 项目 AGENTS.md 的文档索引规范（§0.2）执行：

### 第一步：定位当前任务
1. 读取 `docs/05-planning/task-status.json`。
2. 找到当前阶段中第一个 `status: "in_progress"` 或 `status: "ready"` 的任务。
3. 如果用户指定了任务 ID，优先使用用户指定的。
4. **如果没有找到任何 `in_progress` 或 `ready` 的任务**：
   - 输出：“当前没有进行中或待执行的任务。”
   - 读取 `task-status.json`，列出当前阶段的所有任务状态概览。
   - 询问用户是否要查看特定任务（请提供任务 ID）或执行 `next-task-echo` 开始第一个任务。

### 第二步：映射文档路径
1. 查阅 `AGENTS.md` §0.2 的“任务类型 → 文档快速索引”。
2. 根据当前任务的特征，匹配最接近的任务类型：
   - **任务包含 Actor** → `架构设计文档.md` §3.2 + `避坑手册.md` §2
   - **任务包含 Pipeline** → `架构设计文档.md` §3.1 + `数据流文档.md` §2~4
   - **任务包含 US-XXX** → `规格书.md`（定位到具体故事）
   - **任务包含“调试/避坑”** → `避坑手册.md`（按关键词查找）
    - **任务包含“创新工具”** → `产品创新工具全景指南.md`（对应工具章节）
    - **任务包含“技术选型”** → `技术选型文档.md`（对应章节）
    - **任务属于 phase `"3"` 的 UI 任务**（`tasks` 数组包含关系确定，且非其 `integration_task_id`；**不得**捕获 phase `"3F"` 任务） → `docs/ui/echo-memory-canvas-style.md` + `docs/ui/architecture.md`
    - **Phase 3 UI 测试** → `docs/ui/testing-and-artifacts.md`
    - **无法确定类型** → 读取 `docs/INDEX.md` 辅助定位，然后重新判断

### 第三步：读取并摘要
1. 使用 `read` 工具，配合 `offset` 和 `limit` 参数精准读取相关章节。
2. 如果不知道具体行号，先用 `grep` 定位关键词（如 AC 编号），再读取。
3. 提取核心内容：
   - **如果是用户故事**：**逐字粘贴**相关的 AC（验收标准）。
   - **如果是架构任务**：提取涉及的核心契约（如 Actor 隔离规则、错误分级）。
   - **如果是跨语言任务**：提取跨语言检索或翻译的约束。
4. 输出结构化摘要：
   - 任务 ID
   - 关联用户故事（如有）
   - 核心 AC 列表
   - 关键架构约束
   - 参考文档路径

### 第四步：确认与行动
1. 输出完成后，询问用户：
   - “是否确认理解无误？”
   - “是否需要读取更多相关文档？”
2. **如果用户确认理解**：
   - 提示：“准备就绪。请执行 `next-task-echo` 开始编码，或执行 `do-task-echo 任务ID` 指定任务。”
3. **如果用户需要更多文档**：返回第二步重新映射。
