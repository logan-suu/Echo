---
description: 执行当前阶段的集成测试任务（作为正式任务，走分支→TDD→PR流程）
agent: build
---

## 🔗 阶段集成测试（正式任务）

阶段集成测试是每个 Phase 的最后一个正式任务（如 1.9、2.14、3.10），遵循与其他任务完全相同的开发流程。Agent **不得**跳过分支/PR 直接运行测试。

### 第一步：定位集成测试任务
1. 读取 `docs/05-planning/task-status.json`。
2. 确定目标阶段：
   - 如果用户指定了阶段 ID（如 `test-phase-echo 2`），以用户指定的为准。
   - 如果未指定，使用 `current_phase`。
3. 找到该阶段任务列表中 ID 最大的那个任务——即集成测试任务（如 Phase 1 → 1.9、Phase 2 → 2.14）。

### 第二步：状态检查与分流
检查该集成测试任务的状态：

| 状态 | 行为 |
|------|------|
| `backlog` | 前置任务尚未全部完成。列出未完成的前置任务，提示用户先完成。 |
| `ready` | 前置任务全部 `done`，任务就绪。**调用 `do-task-echo {id}` 执行标准流程**（分支→TDD→PR）。 |
| `in_progress` | 任务正在执行中。显示当前进度。 |
| `review` | PR 已提交，等待 CI 通过。显示 PR 链接。 |
| `done` | 集成测试已通过。报告结果，提示阶段完成。 |
| `blocked` | 任务被阻断。显示阻断原因。 |

### 第三步：执行（仅当 status=ready）
调用 `do-task-echo {集成测试任务ID}`，按 AGENTS.md §12.3 九步法执行：
1. 查阅文档并引用原文
2. 编写集成测试用例（`EchoTests/Phase{阶段ID}IntegrationTests.swift`）
3. TDD 增量实现
4. 运行测试：`swift test --filter "Phase{阶段ID}Integration"`
5. 更新任务状态为 `review`
6. 创建分支并提交代码
7. 创建 PR
8. 等待 CI 通过后合并
9. 更新 `task-status.json`：阶段 `status` → `done`，`current_phase` 推进

### 第四步：完成后
阶段集成测试通过后：
- 更新该阶段 `status` 为 `done`
- `current_phase` 推进到下一阶段
- 询问用户是否执行 `next-task-echo` 开始下一阶段
