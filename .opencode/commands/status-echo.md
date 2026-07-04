---
description: 快速查看 Echo 项目当前状态（阶段、任务、进度）
agent: build
---

## 📊 项目状态速览

请读取 `docs/05-planning/task-status.json`，输出以下信息：

### 全局概览
- 当前阶段：Phase X - [阶段名称]
- 整体进度：已完成 X / 总任务数（所有阶段）— XX%
- 当前阶段状态：[in_progress/completed/not_started]

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