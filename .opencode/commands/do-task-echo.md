---
description: 执行指定的任务 ID（如 2.3），按 AGENTS.md 流程完成开发
agent: build
---

## 🎯 执行指定任务

> ⚠️ **Phase 3 UI 任务（3.1–3.9）禁止使用本命令。** Phase 3 集成测试（3.10）除外。
> Phase 3 UI 实现任务必须通过 `/ui-bootstrap-build-echo <task-id>` 执行（AGENTS.md §17.4）。

请按 Echo 项目 AGENTS.md 的任务执行流程规范（§12.2 和 §12.3）执行：

### 第一步：定位目标任务
1. 读取 `docs/05-planning/task-status.json` 和 `docs/05-planning/deferred-items.json`。
2. **如果用户指定了任务 ID**（如 `do-task-echo 2.3`），锁定该任务。
3. **如果用户未指定**：
   - 输出：“请指定要执行的任务 ID，如 `do-task-echo 2.3`。”
   - 列出当前阶段所有 `ready` 和 `backlog` 状态的任务（含 ID 和标题）。
   - 等待用户输入后继续。
4. **验证任务状态**：
   - 如果任务状态为 `done`，输出：“该任务已完成，无需重复执行。”
   - 如果任务状态为 `blocked`，输出：“该任务被阻断，请先执行 `retry-task-echo` 解决。”
   - 如果任务状态为 `in_progress`，输出：“该任务正在进行中，是否要继续？（y/n）”
5. **检查依赖**：
   - 确认该任务的所有 `dependencies` 均已标记为 `done`。
   - 如果有未完成的依赖，列出并提示：“请先完成依赖任务后再执行。”
6. **跨阶段阻断检查（AGENTS.md §12.6）**：
    - 确定目标任务所属的阶段编号（如任务 2.3 属于 Phase 2）。
    - 如果阶段编号 > 1，找到前一阶段的最后一个任务（该阶段的集成测试任务，如 Phase 1→1.9）。
    - 检查该集成测试任务的状态是否为 `done`。
    - 如果不是 `done`，**阻断**并输出：
      ```
      ⛔ 阶段 [N-1] 的集成测试任务 [任务ID] 尚未完成（当前状态：[status]）。
      跨阶段阻断规则：必须先完成前一阶段的集成测试，才能执行当前阶段任务。
      请先执行 `do-task-echo [任务ID]` 完成该集成测试。
      ```
     - 如果是 `done`，继续下一步。
7. **Phase 3 UI 任务阻断（AGENTS.md §17.4）**：
    - 检查目标任务是否属于 Phase 3（任务 ID 以 `3.` 开头）。
    - **集成测试任务（3.10）例外**：3.10 走标准 do-task-echo 流程。
    - 如果是 Phase 3 UI 实现任务（3.1–3.9），**阻断**并输出：
      ```
      ⛔ Phase 3 UI 任务禁止使用 `/do-task-echo`。
      Phase 3 UI 任务必须通过专用 UI 流水线执行。
      请使用 `/ui-bootstrap-build-echo [任务ID]` 代替。
      推荐流程：/init-session-echo → /next-task-echo → /ui-bootstrap-build-echo [任务ID]
      ```
    - 如果是非 Phase 3 任务或 3.10，继续下一步。
8. **级联更新 backlog → ready**（AGENTS.md §12.1）：遍历所有阶段中 `status: backlog` 的任务，若其 `dependencies` 全部为 `done`/`merged`，则翻转为 `ready`。此操作为**幂等操作**，确保在开始执行前所有依赖已满足的任务都处于 `ready` 状态。
9. 将任务状态更新为 `in_progress`。

### 第二步：查阅文档并引用原文
1. 查阅 `AGENTS.md` §0.2 的“任务类型 → 文档快速索引”。
2. 根据任务类型，使用 `read` 读取相关文档章节。
3. 在回复中**逐字粘贴**相关 AC 或规则原文。
4. **如果发现文档问题**（矛盾、模糊、不可测、依赖缺失、技术过时），**必须暂停**并执行文档问题报告流程（§12.4）。

### 第三步：执行开发
1. 按 TDD 流程执行：
       - 使用 `write` 在 `EchoTests/Phase{N}/` 中创建测试文件（N 为当前阶段编号），命名格式：`[任务ID]_[功能名]Tests.swift`。
   - 测试方法命名含 AC 编号（如 `test_AC1_ExcludedAssetsWriteCondition`）。
   - 一次实现一个测试用例 → 运行测试 → 通过后继续下一个。
2. 实现文件必须包含“出生证明”水印（§12.5）。
3. 执行 `swift test --filter [任务ID]`，测试通过才进入下一步。

### 第四步：交付
1. 更新 `task-status.json`：
   - 将任务 `status` 从 `in_progress` 改为 `review`。
   - 更新 `last_updated` 时间戳。
2. 输出任务完成摘要：
   - 任务 ID 和标题。
   - 已实现的 AC 列表。
   - 测试覆盖率（如有）。
3. 提示用户：“请执行 `commit-pr-echo` 提交代码并创建 PR。”