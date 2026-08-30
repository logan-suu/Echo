---
name: test-phase-echo
description: "执行当前阶段的集成测试任务（作为正式任务，验证该阶段所有单元测试+集成测试全部通过后走分支→PR流程）"
---

> Codex migration: This is a repository-scoped native skill. Follow the
> repository `AGENTS.md` as the authority. Treat any remaining GitHub API
> wording as the equivalent `gh` CLI operation supported by the current
> environment. Never weaken human-only approval, PR merge, branch retention,
> privacy, or release gates. If `gh auth status` is invalid, stop external
> GitHub mutations and ask the user to re-authenticate.


## 🔗 阶段集成测试（正式任务）

阶段集成测试是每个 Phase 的正式任务，由该 phase 对象的 `integration_task_id` 字段标识（如 1.9、2.14、3.10、3F.11），遵循与其他任务完全相同的开发流程。**该任务的核心职责是编写该 Phase 的集成测试代码，并在提交 PR 前验证该 Phase 所有测试（单元测试 + 集成测试）全部通过。**

Agent **不得**跳过分支/PR 直接运行测试；**不得**在未验证该阶段所有单元测试通过的情况下提交集成测试 PR。

### 第一步：定位集成测试任务
1. 读取 `docs/05-planning/task-status.json`。
2. 确定目标阶段：
   - 如果用户指定了阶段 ID（如 `test-phase-echo 2`），以用户指定的为准（精确字符串匹配，如 `"3F"`）。
   - 如果未指定，使用 `current_phase`（字符串，如 `"3F"`）。
3. 用该 phase 对象的 `integration_task_id` 字段得到集成测试任务 ID（**禁止**用「ID 最大」或数值推断；如 phase `"3F"` → `"3F.11"`）。

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
2. 编写集成测试用例（`EchoTests/Phase${phase.id}/Phase${phase.id}IntegrationTests.swift`，`phase.id` 为字符串，如 `"3F"` → `EchoTests/Phase3F/Phase3FIntegrationTests.swift`）
3. TDD 增量实现
4. **运行该阶段及所有之前阶段的全部测试（累积回归检查）**：
    ```bash
    # 运行 `phase_order` 中当前 phase 及所有更早 phase 的单元测试 + 集成测试
    # （按 phase_order 顺序：如 "1","2","3","3F" → 含 Phase1/Phase2/Phase3/Phase3F）
     xcodebuild test -project Echo.xcodeproj -scheme Echo \
       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
       -parallel-testing-enabled NO \
       -only-testing:EchoTests
    ```
   验证该阶段所有单元测试 + 集成测试**全部通过**（0 失败）。
5. 更新任务状态为 `review`
6. 创建分支并提交代码
7. 创建 PR
8. 等待 CI 通过后合并
9. 更新 `task-status.json`：阶段 `status` → `done`，`current_phase` 推进到该 phase 的 `next_phase_id`（**禁止**数值加一推断）。
   - **Phase `"3F"` 例外**：Phase `"4"` 解锁只发生在 `"3F.11"` 合并后的人类触发 finalizer（见 docs/05-planning/phase3f-execution-plan.md §10.1，记录 `3F.finalize`）。`3F.11` 集成测试 PR 只提交 pre-merge gate evidence，**不得**将 `3F.11`/Phase `"3F"` 标记为 `done`，**不得**把 `current_phase` 改为 `"4"`。

### ⚠️ 质量门禁（不可跳过）
在步骤 4 中，Agent **必须**确保该阶段及所有之前阶段的任务对应的所有单元测试文件全部通过，**然后**集成测试也通过，两者缺一不可。这是累积回归检查——确保新阶段的代码变更不会破坏已交付阶段的功能。
- 列出该阶段每个任务的 `test_file`，逐一运行验证
- **同时运行所有已交付阶段（按 `phase_order` 顺序，含当前 phase 及更早的所有 phase）的全部单元测试 + 集成测试**
- 仅当**全部**通过时，才能进入步骤 5

### 🗂️ 延期任务扫描（不可跳过）
在步骤 4 测试通过后、步骤 5 更新状态前，Agent **必须**：
1. 读取 `docs/05-planning/deferred-items.json`
2. 遍历 `deferred_to_phase_*` 数组中每条延期任务：
   - 检查其 dependencies 是否已全部 `done`
   - 检查是否在实现当前 Phase 其他任务时被**顺带覆盖**
   - 检查其 blocker 是否已消除（如环境就绪、依赖可用）
3. 如果发现**可解决**的任务：
   - 在 `task-status.json` 中创建新任务或扩展现有任务范围
   - 将原条目从 `deferred_*` 移至 `resolved_deferred` 数组
   - Record in this PR commit message: "Phase N integration test: found [story] now resolvable, moved to task X"
4. 如果仍无法解决：
   - 更新 `last_checked_at` 时间戳
   - Briefly note in integration test PR description: "Scanned deferred-items.json, [N] deferred items remain unresolvable"

### 第四步：完成后
阶段集成测试通过后：
- 更新该阶段 `status` 为 `done`
- `current_phase` 推进到该 phase 的 `next_phase_id`（**禁止**数值推断）
- **Phase `"3F"`**：Phase `"4"` 解锁只通过 `"3F.11"` 合并后的人类触发 finalizer（§10.1），本命令不得自动推进
- 询问用户是否执行 `next-task-echo` 开始下一阶段
