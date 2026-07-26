---
description: 提交当前代码变更，推送到远程仓库，并创建 Pull Request（遵循 Echo Git 规范）
agent: build
---

## 🚀 提交代码与创建 PR

请严格按照 Echo 项目 AGENTS.md 的 Git 协作规范（第 3 章）和任务执行第 6 步（§12.3）执行：

### 第一步：前置检查（强制门禁）
0. **Phase 3 UI 任务交付门禁（AGENTS.md §17.6）**：
   - 如果当前任务属于 Phase 3 UI（3.1–3.9），检查 `.ui-automation/state.json`：
     - `automation_phase` 必须为 `accepted`（用户已完成 Live Sim Review 批准）
     - `delivery_approval.approved` 必须为 `true`
   - 如果未通过，**阻断**并输出：
     ```
     ⛔ Phase 3 UI 任务尚未通过 Live Simulator 视觉审批。
     请先执行 /ui-bootstrap-build-echo [任务ID] 完成验证与 Simulator Review，
     获得用户明确批准后再提交。
     ```
1. **Git 状态检查**：
   - 执行 `git status`，确认有变更可提交。
   - 如果无变更，输出：“当前没有可提交的变更。请确认代码已修改或使用 `git add` 添加文件。”并退出。
   - 执行 `git branch --show-current`，获取当前分支名。
   - 检查远程是否已存在同名分支：`git ls-remote --heads origin [分支名]`
   - 如果分支已存在且有关联 PR，询问用户：“当前分支已存在 PR，是否要更新 PR 而非新建？”
   - 如果分支已存在但无关联 PR，询问是否覆盖或重命名。
1. **运行 Lint**：确保 SwiftLint 0 违规。
2. **运行测试**：确保当前任务的单元测试通过（可调用 `test-unit-echo`）。
3. **检查水印**：确认核心文件（Actor/Pipeline）头部包含“出生证明”水印（§12.5）。

### 第二步：更新任务状态
1. 将 `docs/05-planning/task-status.json` 中当前任务的 `status` 更新为 `review`，记录当前时间戳。
2. 检查 `docs/05-planning/deferred-items.json`：如果本次 PR 涉及解封某个延期任务（如环境就绪、依赖完成），将其移至 `resolved_deferred` 数组并更新 `resolved_at`。

### 第三步：Git 提交
1. **分支命名**：`{type}/{description}-US-XXX`（如 `feature/search-pipeline-US-RET-001`）。
2. **如果当前分支名不符合规范**，提示用户并退出。
3. **生成 Commit Body**：
   - 总结本次变更的主要内容（从 `git diff --stat` 和代码变更中提取）。
   - 引用相关 AC（如“- Implements AC-1: 系统自动删除不写入 ExcludedAssets”）。
   - 包含关联的用户故事编号：`Related: US-XXX`
4. **提交示例**：
   ```
   feat(actor): add ExcludedAssetsActor with cascade cleanup

   - Implements AC-1: system auto-delete does not write to ExcludedAssets
   - Adds cascade cleanup for invalid records per US-PRV-007
   - Includes unit tests covering all write paths

   Related: US-PRV-004, US-PRV-007
   ```
5. 执行 `git add -A`，然后 `git commit -m "[完整的 commit message]"`。

### 第四步：创建 PR
1. **推送代码**：
   - 执行 `git push -u origin [分支名]`
   - **如果推送失败**：
     - 远程有新提交 → 提示 `git pull --rebase` 后重试。
     - 权限问题 → 提示检查 GitHub OAuth 配置。
2. **生成 AC 覆盖对照表**：
   - 从当前任务的 `story` 字段获取用户故事编号（如 US-PRV-001）。
   - 读取 `docs/01-spec/用户故事与验收标准规格书.md`，定位到该故事。
   - 提取所有 AC（验收标准）。
   - 对比代码变更（通过 `git diff` 分析实现了哪些 AC）。
   - 生成表格：
     | AC # | Spec Summary | Test File | Implementation | Status |
     | --- | --- | --- | --- | --- |
     | AC-1 | ... | ... | ... | ✅ |
     | AC-2 | ... | ... | ... | ✅ |
3. 使用 GitHub API 创建 PR（OpenCode 桌面版应已配置 OAuth）。
4. **PR 标题**：`{type}({scope}): {description} [US-XXX]`
5. **PR 描述**：必须包含上述 AC 覆盖对照表（§3.3）。

### 第五步：后续
1. **自动刷新已有 PR 描述（AGENTS.md §15.5）**：
   - 如果当前分支已有关联的开放 PR（通过 `gh pr list --head [分支名] --json number --jq '.[0].number'` 检测）
   - 且本次提交为 PR Review 修复提交（commit body 中包含 "PR review" / "Addresses review" 等关键词）
   - 则自动执行 `gh pr edit [PR编号] --body "[更新的 PR 描述]"`，刷新 AC 覆盖对照表
   - 同时更新 `task-status.json` notes + 核心文件头部 AC 覆盖注释
2. 输出 PR 链接。
3. 提醒用户：“请执行 `pr-review-echo` 进行 AI 预审，或等待人类 Reviewer 批准。”
4. **可选**：检查 GitHub Actions 是否已触发（通过 API 查询），如果未触发，提醒用户检查配置。
