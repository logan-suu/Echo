---
description: Phase 3 UI 失败恢复 — 受限阶段重试，遵守两次预算、hash 失效和 blocker 证据，不重启整个任务或触发 Git
agent: build
---

## 🔄 Phase 3 UI 失败重试

> **上游权威**：`Echo SwiftUI UI Agent 自动化 Bootstrap 与执行规范.md` §22.5
> **权限**：只重试当前失败的 bootstrap phase。不重启整个任务，不触发 Git，不降低验收门禁。
> **阶段判定**：本命令只针对 phase `"3"` 的 UI 任务（`tasks` 数组包含关系确定；phase id 精确等于 `"3"`，**不得**捕获 `"3F"`）。Phase `"3F"` 任务的失败恢复走 do-task-echo 等标准路径。

---

### 第一步：读取失败状态

1. 读取 `docs/05-planning/task-status.json`
2. 读取 `docs/05-planning/deferred-items.json`，确认目标任务未被标记为延期
2. 读取 `.ui-automation/state.json`
3. 验证：
   - 任务仍为 `in_progress`
   - 运行状态 `task_id` 匹配
   - 活动 run 唯一
   - `automation_phase_status == failed`

---

### 第二步：确认重试资格

4. 检查 `retry_count`：
   - 同阶段 ≤ 2 次 → 可重试
   - 已耗尽 → 报告：「重试预算已耗尽，请人工决定」
5. 检查失败类型：
   - **环境错误**：先执行健康检查 + 清理 → 再重试 1 次
   - **契约/实现错误**：确认修复假设 → 再重试
   - **安全/范围错误**（修改 Core、生产签名等）：**不得重试**，保持 `stopped`

---

### 第三步：增量重试

6. 从最早失效阶段恢复（不重做证据完整且 hash 未变的阶段）。
7. 重试只覆盖具体失败点，**不触发全新 `repo_discovery`**。

---

### 第四步：输出结果

8. 重试后更新 `.ui-automation/state.json`（blocker 状态、retry_count）。
9. 成功 → 输出下一阶段命令。失败 → 保留所有 artifact，请求人工判断。

---

### 约束

- 不重启整个任务
- 不改变项目账本 lifecycle status
- 不触发 Git
- 不降低验收门禁
- 安全/范围停止不可重试
