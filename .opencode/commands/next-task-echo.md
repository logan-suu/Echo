---
description: 找到并执行下一个 ready 任务，按 AGENTS.md 流程完成开发。Phase 3 UI 时进入 handoff mode，只建立 selected checkpoint 并打印 /ui-bootstrap-build-echo
agent: build
---

## 📋 任务：执行下一个 ready 任务

请严格按照 Echo 项目 AGENTS.md 的任务执行流程规范（第 11.2 节）执行。

---

### 前置检查：Git 状态

0. 执行 `git status --porcelain`，检查是否有未提交的变更。
   - 如果有未提交的变更，输出：「检测到未提交的变更，请先处理（提交或暂存）。」
   - 建议执行 `commit-pr-echo` 提交当前变更，或 `git stash` 暂存后继续。

---

### 第一步：定位任务

1. 读取 `docs/05-planning/task-status.json` 和 `docs/05-planning/deferred-items.json`
2. **跨阶段阻断检查（AGENTS.md §12.6）**：
   - 获取 `current_phase`（字符串，如 `"3F"`），用 `phase_order` 定位该 phase 对象。
   - 若该 phase 的 `previous_phase_id` 非空：读取前一 phase 对象（按精确字符串 ID 查找），用其 `integration_task_id` 字段得到集成测试任务 ID（**禁止**用「ID 最大」或数值推断），检查该任务状态是否为 `done`。
   - 如果不是 `done`，**阻断**并输出：
     ```
     ⛔ 阶段 [previous_phase_id] 的集成测试任务 [集成任务ID] 尚未完成（当前状态：[status]）。
     请先执行 do-task-echo [集成任务ID] 完成该阶段的集成测试，再继续阶段 [当前阶段ID] 的任务。
     ```
   - 如果前一阶段所有任务（包括集成测试）均为 `done`，继续下一步。
3. **级联更新 backlog → ready**（AGENTS.md §12.1）：按 `phase_order` 遍历每个 phase，对其 `tasks` 中 `status: backlog` 的任务，若其 `dependencies` 全部为 `done`/`merged`，则翻转为 `ready`。此操作为**幂等操作**，必须在搜索 ready 任务之前执行。
   - **Phase 入口门禁（`entry_gate`）**：对声明了 `entry_gate` 的 phase（如 phase `"4"` 的 `entry_gate: "3F.11"`），仅当该 gate 任务（按精确字符串 ID 查找）为 `done`/`merged` 时，才允许级联该 phase 的 backlog→ready；否则该 phase 视为锁定，跳过其全部任务的级联。
4. 找到当前 phase（`current_phase` 指向的 phase 对象）的 `tasks` 中第一个 `status: ready` 的任务（任务所属 phase 由 `tasks` 数组**包含关系**确定）。phase `"4"` 在 `entry_gate`（`"3F.11"`）未满足前视为锁定，**不得**从中选取任务。

   **若用户指定了 task ID**（原命令已支持显式 task 参数），选择该参数指定的 ready 任务。
5. 如果找不到 ready 任务：
   - 输出：「✅ 当前没有待执行的任务。」
   - 检查是否有 `in_progress` 的任务。
   - 检查是否有 `blocked` 的任务。
   - 列出当前阶段的所有任务状态摘要。
   - 提示：「是否要执行 `do-task-echo 任务ID` 指定任务？」

---

### 第二步：Phase 3 UI 分支判定

6. 检查 `current_phase` 与选中的任务：
   - **若 `current_phase` 精确等于 `"3"`**（用 `^3$` 精确匹配，**不得**捕获 `"3F"`）**且**选中任务属于 phase `"3"`（通过 `tasks` 数组包含关系确定）且非该 phase 的 `integration_task_id`：进入「Phase 3 UI Handoff Mode」，按以下规则执行。
   - **否则**（含 `current_phase` 为 `"3F"`、`"4"`、`"5"` 等）：进入「标准任务模式」，按原流程（第三步-第四步）执行。

---

## 🎨 Phase 3 UI Handoff Mode

> **核心规则**：next 只选择一个 ready UI 任务，验证依赖和冲突门禁，执行 `ready → in_progress` 转换，创建最小 `selected` checkpoint，打印 `/ui-bootstrap-build-echo <task-id>`。**不实现代码、不测试、不物化完整结构、不运行写入性 Git。只允许 `git rev-parse HEAD` 和 `git status --porcelain` 只读查询。**

### A. Handoff 前置验证
1. 逐项验证：
   - 任务属于 phase `"3"`（`tasks` 数组包含关系确定）✅
   - `status == ready` ✅
   - 全部 `dependencies` 为 `done` ✅
   - **不存在任何 Phase 3 UI `in_progress` 任务**（一个 Phase 3 只能有一个 UI 任务在执行）
   - **不存在未终止的活动 UI run**（`.ui-automation/state.json` 中无未完成 run）
2. 任一条件不满足 → 只报告证据并停止，不自动修复或猜测。

### B. Handoff 执行
3. 将选中任务 `status` 从 `ready` 更新为 `in_progress`。
   - 不得改变其他任务
   - 不得标记 `review`、`approved/merged` 或 `done`
4. 获取 source revision：
   - 使用 `git rev-parse HEAD` 获取当前 commit SHA
   - 使用 `git status --porcelain` 记录 dirty state
   - **禁止 commit、push、branch mutation 或 PR 操作**
5. 创建 `.ui-automation/state.json`（原子写入），**仅包含**：
   ```json
   {
     "schemaVersion": "1.0.0",
     "task_id": "<任务ID>",
     "runId": "<UUID v4>",
     "sourceRevision": "<git rev-parse HEAD>",
     "sourceDirty": false,
     "automation_phase": "selected"
   }
   ```
   - **不得**复制 title、项目 phase、dependencies、task status、test file、PR 或 merge evidence
   - **不得**提前写 inventory、migration map、contract、fixture、artifact 或 simulator 字段

### C. Handoff 输出
6. 成功 handoff 后输出：
   ```
   ✅ Handoff 完成：任务 [taskID] ready → in_progress

   📋 Run 信息
   - Task ID：[taskID]
   - Run ID：[runId]
   - Commit：[sourceRevision]
   - 状态文件：.ui-automation/state.json → automation_phase: selected

   🚀 下一步：执行 /ui-bootstrap-build-echo [taskID]
   ```

### D. 幂等规则
7. 重复调用 `/next-task-echo` 时：
   - 只要已有 Phase 3 UI 任务 `in_progress` → **不得选择第二个任务**
   - 若账本任务、manifest `task_id` 和 active run 唯一且匹配 → 幂等地重印同一 resume 命令，不重写 run ID，不重复账本转换
   - 若不匹配、manifest 缺失或多个 active run → 停止并报告冲突，不自动修复或覆盖

### E. 约束
- **不实现代码或测试**
- **不运行测试**
- **不物化完整 `docs/ui`、`UIAutomation` 或 UI target 结构**
- **不进入 readiness**
- **不调用 Git 写操作**
- **不创建 PR**

---

## 📋 标准任务模式（非 Phase 3 UI）

> **注意**：phase `"3"` 的 UI 任务禁止走此路径。此路径保留给 phase `"1"`、`"2"`、`"3F"`、`"4"`、`"5"` 的任务使用（phase id 均为字符串，如 `"3F"`）。phase `"3"` 的 UI 任务必须通过 `/ui-bootstrap-build-echo` 执行。

### 第三步：查阅文档
1. 根据任务特征匹配类型：
   - 任务标题包含 "Actor" → 匹配「实现新 Actor」
   - 任务标题包含 "Pipeline" → 匹配「实现新 Pipeline」
   - 任务包含 "US-XXX" → 匹配「实现用户故事 US-XXX」
   - 无法确定 → 读取 `docs/INDEX.md` 辅助定位
2. 查阅 AGENTS.md §0.2 的任务类型映射表
3. 使用 `read` 读取相关文档章节
4. 在回复中**逐字粘贴**相关 AC/规则原文
5. 如果发现文档问题，**必须暂停**并执行文档问题报告流程（AGENTS.md §12.4）

### 第四步：执行开发
1. **编写测试用例**：
   - 使用 `write` 在 `EchoTests/Phase${phase.id}/` 中创建测试文件（`phase.id` 为字符串，如 `"3F"` → `EchoTests/Phase3F/`）
   - 命名格式：`[任务ID]_[功能名]Tests.swift`
   - 测试方法命名含 AC 编号
2. **增量实现（TDD 循环）**：
   - 一次实现一个测试用例 → 运行测试 → 通过后继续
3. **运行单元测试**：执行 `swift test --filter [任务ID]`，测试通过才进入下一步

### 第五步：交付
1. 更新 `task-status.json`：任务 `status` 改为 `review`，更新 `last_updated`
2. 生成 AC 覆盖对照表
3. 创建分支并提交代码（遵循 §3.1 分支命名、§3.2 Commit Message）
4. 自动创建 PR（§3.3 规范）
5. 输出 PR 链接，提示执行 `pr-review-echo`
