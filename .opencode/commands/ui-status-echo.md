---
description: Phase 3 UI 状态查询 — 严格只读展示双状态（项目账本 + UI 运行）、证据摘要和下一合法动作
agent: build
---

## 📊 Phase 3 UI 状态查询

> **上游权威**：`Echo SwiftUI UI Agent 自动化 Bootstrap 与执行规范.md` §22.5
> **权限**：严格只读。不改变任务状态，不写运行状态，不触发 Git。

---

### 第一步：读取双状态

1. 读取 `docs/05-planning/task-status.json`（项目账本 — 唯一权威）
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

### Simulator
- Owner：[mcpbridge/cli_xctest]
- Device：[UDID]
- Runtime：[iOS version]
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
| `awaiting_delivery_approval` | 查看 Simulator → 批准或修改 |
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
