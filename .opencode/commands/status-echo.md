---
description: 快速查看 Echo 项目当前状态（阶段、任务、进度）
agent: build
---

## 📊 项目状态速览

请读取 `docs/05-planning/task-status.json`，输出以下信息：

### 全局概览
- 当前阶段：Phase [当前阶段ID，字符串，如 "3F"] - [阶段名称]（从 `current_phase` + `phase_order` 读取，禁止数值推断）
- 整体进度：已完成 X / 总任务数（所有阶段）— XX%
- 当前阶段状态：[in_progress/completed/not_started]

### Phase 3 UI 状态（仅当 current_phase 精确等于 "3"，`^3$` 匹配，不含 "3F"）
- UI Bootstrap 物化：[✅ 已就绪 / ⚠️ 不完整]
- 推荐入口：`/init-session-echo → /next-task-echo → /ui-bootstrap-build-echo <task-id>`
- **如果存在 `.ui-automation/state.json`**：读取并报告 UI 运行状态（run ID、automation_phase、阶段进度）

### 当前阶段任务统计
| 状态 | 数量 |
| --- | --- |
| 总任务数 | X |
| ✅ 已完成 | X |
| 🔄 进行中 | X |
| ⏳ 待执行 | X |
| 🚫 阻塞 | X |
| 📝 待审查 | X |

- 进度百分比：XX%

### 下一个 ready 任务
- **如果存在**：`[任务ID] - [任务标题]`
- **如果不存在**：
  - 检查是否有 `in_progress` 任务 → 提示“当前有进行中的任务：[任务ID]”
  - 检查是否有 `blocked` 任务 → 提示“有 X 个阻塞任务，请执行 `retry-task-echo`”
  - 如果所有任务已完成 → 提示“🎉 当前阶段所有任务已完成！请执行 `test-phase-echo` 进行阶段验收”

### 阶段集成测试
- 状态：[passed / pending / failed]（从 `integration_test` 字段读取）

### 当前 Git 分支
- 执行 `git branch --show-current` 获取当前分支名
- 与任务状态对比：是否与当前任务匹配

### 最近更新
- `last_updated` 时间戳
- `deferred-items.json` 延期任务：[N] 条（执行 `/test-phase-echo` 时会自动扫描是否已可解决）

### Phase 3 UI 运行状态（额外步骤，仅当 current_phase 精确等于 "3"，`^3$` 匹配，不含 "3F"）
- 如果 `.ui-automation/state.json` 存在，读取并报告：run ID、自动化阶段、阶段进度、blocker、建议下一步动作