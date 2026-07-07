---
description: 找到并执行下一个 ready 任务，按 AGENTS.md 流程完成开发
agent: build
---

## 📋 任务：执行下一个 ready 任务

请严格按照 Echo 项目 AGENTS.md 的任务执行流程规范（第 11.2 节）执行：

### 前置检查：Git 状态
0. 执行 `git status --porcelain`，检查是否有未提交的变更。
   - 如果有未提交的变更，输出：“检测到未提交的变更，请先处理（提交或暂存）。”
   - 建议执行 `commit-pr-echo` 提交当前变更，或 `git stash` 暂存后继续。

### 第一步：定位任务
1. 读取 `docs/05-planning/task-status.json`
2. **跨阶段阻断检查（AGENTS.md §12.6）**：
   - 获取 `current_phase`（如 2）。
   - 如果 `current_phase > 1`，找到阶段 `current_phase - 1` 的最后一个任务（该阶段的集成测试任务，如 Phase 1→1.9）。
   - 检查该集成测试任务的状态是否为 `done`。
   - 如果不是 `done`，**阻断**并输出：
     ```
     ⛔ 阶段 [N-1] 的集成测试任务 [任务ID] 尚未完成（当前状态：[status]）。
     请先执行 `do-task-echo [任务ID]` 完成该阶段的集成测试，再继续阶段 N 的任务。
     ```
   - 如果前一阶段所有任务（包括集成测试）均为 `done`，继续下一步。
3. 找到当前阶段中第一个 `status: ready` 的任务
3. 如果找不到 ready 任务：
   - 输出：“✅ 当前没有待执行的任务。”
   - 检查是否有 `in_progress` 的任务：如果有，询问是否继续该任务。
   - 检查是否有 `blocked` 的任务：如果有，询问是否执行 `retry-task-echo` 重试。
   - 列出当前阶段的所有任务状态摘要（已完成/进行中/待执行/被阻断）。
   - 提示：“是否要执行 `do-task-echo 任务ID` 指定任务？”
4. 确认所有依赖已标记为 `done`
5. 输出任务信息：
   ```
   找到下一个 ready 任务：
   - 任务 ID：[任务ID]
   - 标题：[任务标题]
   - 关联用户故事：[US-XXX]
   - 依赖状态：全部已完成 ✅
   ```
6. **等待用户确认**：“是否开始执行该任务？（回复 y/n）”
7. 用户确认后，将任务状态更新为 `in_progress`

### 第二步：查阅文档
1. 根据任务特征匹配类型：
   - 任务标题包含 "Actor" → 匹配“实现新 Actor”
   - 任务标题包含 "Pipeline" → 匹配“实现新 Pipeline”
   - 任务包含 "US-XXX" → 匹配“实现用户故事 US-XXX”
   - 无法确定 → 读取 `docs/INDEX.md` 辅助定位
2. 查阅 AGENTS.md §0.2 的任务类型映射表
3. 使用 `read_file` 读取相关文档章节
4. 在回复中**逐字粘贴**相关 AC/规则原文
5. 如果发现文档问题（矛盾、模糊、不可测、依赖缺失、技术过时）：
   - **必须暂停**，执行文档问题报告流程（AGENTS.md §12.4）
   - 不要继续编码，等待人类决策

### 第三步：执行开发
1. **编写测试用例**：
   - 使用 `write_to_file` 在 `EchoTests/Phase{N}/` 中创建测试文件（N 为当前阶段编号）
   - 命名格式：`[任务ID]_[功能名]Tests.swift`
   - 测试方法命名含 AC 编号（如 `test_AC1_ExcludedAssetsWriteCondition`）
2. **增量实现（TDD 循环）**：
   - 一次实现一个测试用例
   - 运行测试确认失败（Red）→ 编写代码 → 运行测试确认通过（Green）
   - 重构代码（保持测试通过）
   - 重复循环直到所有 AC 实现完成
3. **运行单元测试**：
   - 执行 `swift test --filter [任务ID]`
   - **测试通过后才进入下一步**
   - 如果测试失败，修复代码后重新运行

### 第四步：交付
1. 更新 `task-status.json`：
   - 将任务 `status` 从 `in_progress` 改为 `review`
   - 更新 `last_updated` 时间戳
2. 生成 AC 覆盖对照表（从规格书提取 AC，对比代码变更标记状态）
3. 创建分支并提交代码：
   - 分支命名：`{type}/{description}-US-XXX`
   - Commit message 遵循 §3.2 格式
4. **自动创建 PR**：
   - PR 标题：`{type}({scope}): {description} [US-XXX]`
   - PR 描述：包含 AC 覆盖对照表（§3.3）
5. 输出 PR 链接，提示执行 `pr-review-echo`


