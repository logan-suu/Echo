---
description: 提交当前代码变更，推送到远程仓库，并创建 Pull Request（遵循 Echo Git 规范）
agent: build
---

## 🚀 提交代码与创建 PR

请严格按照 Echo 项目 AGENTS.md 的 Git 协作规范（第 3 章）和任务执行第 6 步（§12.3）执行：

### 第一步：前置检查（强制门禁）
0. **Phase 3 UI 任务交付门禁（AGENTS.md §17.6）**：
   - 如果当前任务属于 phase `"3"` 的 UI 任务（`tasks` 数组包含关系确定，且非其 `integration_task_id`；**不得**捕获 phase `"3F"` 任务），检查 `.ui-automation/state.json`：
     - `automation_phase` 必须为 `accepted`（用户已完成 Live Sim Review 批准）
     - `delivery_approval.approved` 必须为 `true`
   - 如果未通过，**阻断**并输出：
     ```
     ⛔ Phase 3 UI 任务尚未通过 Live Simulator 视觉审批。
     请先执行 /ui-bootstrap-build-echo [任务ID] 完成验证与双设备 Simulator Review
     （iPhone 17 Pro iOS 26 + iPhone 16 Pro iOS 18），获得用户明确批准后再提交。
     ```
1. **GitHub 认证双阶段核验（AGENTS.md §15）**：
   - 首先运行只读命令 `gh auth status -h github.com`。
   - 若初检失败，尤其是在沙箱内出现 token invalid、DNS、timeout、connection refused 或 API unavailable，结果只能标记为 `indeterminate`；不得据此宣称凭据失效，也不得要求用户重新认证。
   - 自动在允许联网的只读执行环境中复核 `gh auth status -h github.com`，并运行 `gh api user --jq .login` 验证当前身份。复核不得执行任何 GitHub 写操作。
   - 只有允许联网的复核明确返回 HTTP 401、`Bad credentials` 或等价认证拒绝时，才标记为 `invalid`，停止 GitHub 写操作并提示运行 `gh auth login -h github.com`。
   - DNS、timeout、connection refused、GitHub API 不可达或其他连接失败均归类为 `connectivity`；报告网络问题，不得要求重新认证。
   - 禁止运行或输出 `gh auth token`，不得把 token、keyring 内容或凭据写入日志、PR 或 Artifact。
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
     - 疑似权限问题 → 先执行第一步的认证双阶段核验；仅明确认证拒绝时提示重新登录，连接失败只报告网络问题。
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
3. 通过第一步的认证双阶段核验后，使用 GitHub API 创建 PR（OpenCode 桌面版应已配置 OAuth）。
4. **PR 标题**：`{type}({scope}): {description} [US-XXX]`
5. **PR 描述**：必须包含上述 AC 覆盖对照表（§3.3）。

### 第五步：后续
1. **自动刷新已有 PR 描述（AGENTS.md §15.5）**：
   - 如果当前分支已有关联的开放 PR（通过 `gh pr list --head [分支名] --json number --jq '.[0].number'` 检测）
   - 且本次提交为 PR Review 修复提交（commit body 中包含 "PR review" / "Addresses review" 等关键词）
   - 则自动执行 `gh pr edit [PR编号] --body "[更新的 PR 描述]"`，刷新 AC 覆盖对照表
   - 同时更新 `task-status.json` notes + 核心文件头部 AC 覆盖注释
2. **延后项检查（AGENTS.md §15.5 规则 3）**：
   - 如果本次提交是 PR Review 修复提交，检查是否有 🟡 警告项被决定延后
   - 若有延后项，确认其已写入 `docs/05-planning/deferred-items.json` 的 `deferred_from_pr_review` 数组
   - 若未写入，**阻断**并提示："⛔ 存在未记录的延后项。请先将延后的 🟡 警告项写入 deferred-items.json（格式见 §15.5 执行流程第 5 步），再提交。"
3. 输出 PR 链接。
4. 提醒用户："请执行 `pr-review-echo` 进行 AI 预审，或等待人类 Reviewer 批准。"
5. **可选**：检查 GitHub Actions 是否已触发（通过 API 查询），如果未触发，提醒用户检查配置。
