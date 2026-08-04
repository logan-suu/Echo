---
description: Phase 3 UI 状态查询 — 严格只读展示双状态（项目账本 + UI 运行）、证据摘要和下一合法动作
agent: build
---

## 📊 Phase 3 UI 状态查询

> **上游权威**：`Echo SwiftUI UI Agent 自动化 Bootstrap 与执行规范.md` §22.5
> **权限**：严格只读。不改变任务状态，不写运行状态，不触发 Git。
> **阶段判定**：本命令针对 UI 阶段，即 phase id **精确等于** `"3"`（用 `^3$` 匹配，**不得**捕获 `"3F"`）。当 `current_phase` 为 `"3F"`（Phase 3F 生产集成）时，本命令只用于查看遗留的 phase `"3"` UI run 状态，不参与 phase `"3F"` 任务的执行与状态修改。

---

### 第一步：读取双状态

1. 读取 `docs/05-planning/task-status.json`（项目账本 — 唯一权威）和 `docs/05-planning/deferred-items.json`（延期任务追踪）
2. 读取 `.ui-automation/state.json`（若存在 — 单次运行状态）

---

### 第二步：报告项目账本状态

3. 输出项目概览：

```
## 📋 项目账本状态

**Current Phase**：3 — UI 与集成
**Phase 3 状态**：[not_started / 进行中]

### Phase 3 任务
| ID | 标题 | 生命周期 | 依赖 | UI Run |
|----|------|---------|------|--------|
| 3.1 | HomeView + HomeViewModel | ready | 2.11 ✅ | — |
| 3.2 | SearchView + SearchViewModel | ready | 2.6 ✅ | — |
| … | … | … | … | … |
```

---

### 第三步：报告 UI 运行状态（若存在）

4. 若 `.ui-automation/state.json` 存在：

```
## 🔄 UI 运行状态

**Run ID**：[runId]
**Task ID**：[task_id]
**Commit**：[sourceRevision] [clean/dirty]
**自动化阶段**：[automation_phase]
**阶段状态**：[completed/in_progress/failed]

### 已通过阶段
- [✅] repo_discovery
- [✅] materialize_structure
- [⏳] readiness_check — [blocker 描述]

### Artifacts
- Manifest：[路径] (hash: [hash])
- Build log：[路径]
- Test summary：[路径]

### Blocker（若存在）
- [类型]：[描述]

### Simulator（双设备审查）
- Owner：[mcpbridge/cli_xctest]
- Device 1（主审查）：[iPhone 17 Pro] [UDID] — [iOS 26.5]
- Device 2（最低版本）：[iPhone 16 Pro] [UDID] — [iOS 18.x]
```

---

### 第四步：下一合法动作

5. 基于双状态分析，输出下一合法动作：

| 当前状态 | 下一动作 |
|---------|---------|
| 无 UI run | `/next-task-echo` 选择任务 → `/ui-bootstrap-build-echo <task-id>` |
| `automation_phase: selected` | `/ui-bootstrap-build-echo <task-id>` |
| 运行中（非阻塞阶段） | `/ui-bootstrap-build-echo <task-id>`（resume） |
| 失败（可重试） | `/ui-retry-echo <task-id>` |
| `awaiting_delivery_approval` | 查看两台 Simulator（17 Pro iOS 26 + 16 Pro iOS 18）→ 依据报告中的「UI 审查指南」（页面清单/导航路径/未实现说明）逐页审查 → 批准或修改 |
| `accepted` | `/commit-pr-echo <task-id>`（交付） |
| `failed`/`stopped` | 检查 blocker → 人工决策 |

---

### 第五步：设计 Profile 验证

6. 读取 `docs/ui/echo-memory-canvas-style.md`，验证：
   - `profileId == "echo-memory-canvas"` ✅/❌
   - 批准记录存在 ✅/❌

---

### 约束

- 严格只读，幂等
- 不写 `.ui-automation/state.json`
- 不改变 `task-status.json`
- 不运行 Git
