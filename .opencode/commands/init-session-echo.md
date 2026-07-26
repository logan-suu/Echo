---
description: Echo 项目新会话初始化 — 读取规约、定位进度、锁定 AC、等待确认后开工。Phase 3 UI 时进入只读 UI-aware 模式，报告 UI bootstrap 可用性
agent: build
---

## 🚀 新会话启动：Echo 项目初始化

你好，我是 Echo 项目的开发者。这是一个全新的会话，之前的对话历史不在上下文中。

请严格按照以下步骤执行初始化（这是我的项目规约 AGENTS.md 要求的流程），在确认状态前**不要**开始编写任何代码：

---

### 第一步：读取核心规约与地图

1. 读取项目根目录下的 `AGENTS.md`（项目宪法，定义所有红线与架构）。
2. 读取 `docs/INDEX.md`（文档地图，了解所有文档的位置）。
   - 如果 `docs/INDEX.md` 不存在，尝试读取 `docs/README.md`。
   - 如果都不存在，使用 `ls docs/` 列出目录结构，自行建立文档地图。
3. 检查 `docs/ui/README.md` 是否存在 — 判断 UI bootstrap 是否已物化。

---

### 第二步：定位当前进度（任务溯源）

4. 读取 `docs/05-planning/task-status.json`。
5. **级联更新 backlog → ready**（AGENTS.md §12.1）：遍历所有阶段中 `status: backlog` 的任务，若其 `dependencies` 全部为 `done`/`merged`，则翻转为 `ready`。此操作为**幂等操作**，必须在搜索 ready 任务之前执行。

---

### 第三步：Phase 3 UI 分支判定

6. 检查 `current_phase`：
   - **若 `current_phase != 3`**：进入「非 UI 模式」，按原流程（第四步-第五步）执行。
   - **若 `current_phase == 3`**：进入「Phase 3 UI 模式」，按以下规则执行：

---

## 🎨 Phase 3 UI 模式（`current_phase == 3`）

> **核心规则**：init 只做 UI-aware 会话初始化，只读级联 backlog→ready，报告 phase/ready/in_progress 与 UI bootstrap 可用性。**不选任务、不写运行状态、不实现、不测试、不运行 Git。**

### A. 读取 UI 上下文
1. 检查以下 UI bootstrap 物化产物是否存在：
   - `docs/ui/README.md`
   - `docs/ui/echo-memory-canvas-style.md`
   - `UIAutomation/Contracts/`、`UIAutomation/Fixtures/`、`UIAutomation/Policies/`、`UIAutomation/Artifacts/`
   - `.ui-automation/state.schema.json`
   - `.opencode/commands/ui-bootstrap-build-echo.md`
   - `.opencode/commands/init-session-echo.md`（当前文件）是否包含 Phase 3 UI 分支
   - `.opencode/commands/next-task-echo.md` 是否包含 Phase 3 UI handoff mode
2. 区分「文件已写入磁盘」与「命令已由当前 OpenCode 会话加载」——报告时明确标注。

### B. 报告会话状态
3. 报告以下信息（摘要格式）：
   ```
   ## 📊 Echo 会话状态

   **当前阶段**：Phase 3 — UI 与集成
   **Phase 3 状态**：[从 task-status.json 读取]
   **任务账本更新**：级联 backlog→ready 已完成 ✅

   ### Ready 任务（按账本顺序）
   | ID | 标题 | 依赖 |
   |----|------|------|
   | 3.1 | 主视图 HomeView + HomeViewModel | 2.11 ✅ |
   | 3.2 | 检索视图 SearchView + SearchViewModel | 2.6 ✅ |
   | … | … | … |

    ### In-Progress 任务
    [列出所有 in_progress 的 Phase 3 任务]

    ### 延期任务（deferred-items.json）
    - 延后到 Phase 4：[N] 条
    - 上次扫描：[日期]
    - 提示：阶段集成测试时会自动扫描是否可解决

    ### UI Bootstrap 可用性
   - ✅ docs/ui/ 已物化
   - ✅ UIAutomation/ 已就绪
   - ✅ .ui-automation/state.schema.json 已创建
   - ✅ /ui-bootstrap-build-echo 已物化并可用 [或 ⚠️ 文件已写入但需重启]
   ```

### C. 已批准设计配置验证
4. 读取 `docs/ui/echo-memory-canvas-style.md`，验证：
   - `profileId == "echo-memory-canvas"`
   - `baseProfile == "apple-native"`
   - 批准记录存在
   - **不重新询问用户选择**，只报告验证结果。

### D. 已有 in_progress 任务处理
5. 若账本中存在一个 Phase 3 UI 任务 `in_progress`：
   - 报告其 task ID
   - 打印准确 resume 命令：`/ui-bootstrap-build-echo <task-id>`
   - 若匹配 manifest 处于可重试失败状态，也可报告 `/ui-retry-echo <task-id>`
   - **若存在多个 Phase 3 UI in_progress 或多个活动 run** → 报告冲突并停止。
6. 若用户向 init 提供了 task 参数：
   - **不静默选择或启动该 UI 任务**
   - **不写 manifest**
   - 报告该任务状态和合法下一步
   - 提示使用 `/next-task-echo` 或 `/ui-bootstrap-build-echo <task-id>`

### E. 约束
- 重复调用除合法的依赖级联外是**只读且幂等的**
- 相同账本输入不得产生额外写入
- **不写 `.ui-automation/state.json`**
- **不实现、不测试、不运行 Git、不创建 PR**
- **不标记 `review` 或 `done`**

---

## 📋 非 UI 模式（`current_phase != 3`）

### 第四步：定位任务
7. **若用户指定了任务 ID**，优先使用该任务：
   - **跨阶段阻断检查**：若该任务属于阶段 N（N > 1），检查阶段 N-1 的集成测试任务是否为 `done`。
   - 如果不是 `done`，阻断并提示先完成前一阶段集成测试。
8. **若用户未指定**：
   - 找出 `current_phase`（当前阶段）。
   - **跨阶段阻断检查**：若 `current_phase > 1`，检查阶段 `current_phase - 1` 的集成测试任务是否为 `done`。
   - 找到该阶段中第一个 `status: "ready"` 的任务。
   - 如果找不到 ready 任务，检查是否有 `in_progress` 的任务。
   - 如果都没有，列出当前阶段的所有 `backlog` 任务，让用户选择。
9. 确认该任务的所有 `dependencies` 是否已标记为 `done`。
10. 输出当前阶段、任务 ID、标题及关联的用户故事编号。

### 第五步：锁定规格上下文（防幻觉）
11. 根据上述任务 ID，查阅 `AGENTS.md` 中的「任务类型 → 文档快速索引」（§0.2）。
12. 使用 `read` 读取本次任务需要参考的具体规格文档章节。
13. 按以下格式输出上下文摘要：

```markdown
## 📋 任务上下文锁定

### 任务信息
- **任务 ID**：[任务ID]
- **标题**：[任务标题]
- **关联用户故事**：[US-XXX]
- **阶段**：Phase X - [阶段名称]

### 验收标准（AC）原文
> [逐字粘贴 AC-1 原文]
> [逐字粘贴 AC-2 原文]

### 关键架构约束
> [引用 AGENTS.md 中的相关规则]

### 依赖状态
- [依赖任务1]：✅ done
- [依赖任务2]：✅ done

### 参考文档
- `docs/01-spec/...`
- `docs/02-architecture/...`
```

14. **快速一致性检查**：检查 AC 是否在 `AGENTS.md` 红线或数据主权契约中有对应规则。冲突时标记并等待用户确认。

### 第六步：状态确认与开工
15. 总结当前认知。
16. 等待用户确认「开始执行」后：
    - 将 `task-status.json` 中该任务的 `status` 更新为 `in_progress`。
    - 再进入 TDD 编码流程。

---

请开始执行初始化。
