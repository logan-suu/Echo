---
description: 基于 Echo 架构规约对当前 PR 进行 AI 预审，输出风险清单
agent: build
---

## 🔍 PR 架构预审

请按 Echo 项目 AGENTS.md 的代码质量契约（第 4、6、7 章）对当前 PR 进行审查：

### 第一步：获取变更
1. **确定 PR 编号**：
   - 如果用户提供了 PR 编号（如 `pr-review-echo 42`），直接使用。
   - 如果未提供，检查当前分支是否有对应的 PR（通过 GitHub API `GET /repos/:owner/:repo/pulls?head=:head`）。
   - 如果有 PR，自动使用该编号。
    - 如果都没有，提示用户输入 PR 编号或确认使用 `git diff` 对比本地分支与 dev-1.0。
2. 使用 **GitHub API**（优先）或 `git diff` 获取变更文件列表。
3. **审查范围**：
   - 仅审查 **新增或修改** 的文件（`git diff --name-only --diff-filter=AM`）。
   - 忽略纯测试数据文件（GoldenDataset 的 `.json` 等）和资源文件（除非涉及核心逻辑）。
   - 输出变更摘要：“本次 PR 变更涉及 X 个文件：核心代码 Y 个，测试 Z 个，其他 W 个。”

### 第二步：架构合规检查（核心）
按以下清单逐一扫描变更代码：
0. **PR 描述一致性检查**：
   - 读取 PR 描述中的 AC 覆盖对照表。
   - 验证每个 AC 对应的测试文件和实现文件是否确实存在且被修改。
   - 如果某个 AC 声称已实现但无对应代码变更，标记为 🔴。
1. **红线检查（§1.2）**：是否引入了网络请求、用户主动文本输入、Combine 等禁止项？
2. **Actor 隔离（§4.2）**：新 Actor 是否正确封装了可变状态？是否使用了 `nonisolated(unsafe)`？
3. **隐私校验（§7.1）**：所有新增的 Pipeline/异步方法入口是否调用了 `PrivacyCheckpoint.validate()`？
4. **错误处理（§4.4）**：`throws` 错误是否映射到了 L1~L4？
5. **并发安全**：ViewModel 是否标注了 `@MainActor`？跨 Actor 调用是否使用了 `await`？

### 第三步：上下文验证
1. **聚焦关键文件**：
   - 对所有新增或修改的 `Core/Actors/*.swift` 和 `Core/Pipelines/*.swift` 进行逐项检查。
   - 对于其他文件（如 ViewModel、Service），进行抽样检查。
2. **验证代码逻辑是否与 AC 描述一致**：
   - 对于每个关联的 AC，找到对应的代码实现（如 ExcludedAssets 的写入条件）。
   - 对比 AC 原文和代码逻辑，标记不一致之处。
3. **CI 状态检查**：
   - 通过 GitHub API 查询该 PR 的 CI 检查状态。
   - 如果 CI 失败，输出：“⚠️ CI 检查未通过，建议先修复 CI 问题再审查代码。”
   - 如果 CI 通过，继续。

### 第四步：CodeRabbit 评论审核（如存在）
> **核心原则**：外部 AI 审查工具（CodeRabbit 等）的评论**不等于**真理。Agent **必须逐条审核**，禁止无脑采纳。

1. **获取评论**：通过 GitHub API 获取 PR 中的所有 CodeRabbit review comments。
2. **逐条评估**：对每条 comment 按以下标准判定：
   - 🟢 **有效**：指出真实缺陷（绕过校验、竞态条件、静默错误等），有具体代码引用和影响说明 → **修复**
   - 🟡 **过度**：观点正确但影响有限（如 UserDefaults flag 翻转硬要加 PrivacyCheckpoint）→ **驳回并记录理由**
   - 🔴 **误报**：基于错误理解（如认为 task-status 跳过了 `in_progress` 状态）→ **驳回并记录理由**
3. **输出审核结论**：标记每条 CodeRabbit comment 为「采纳/驳回」，驳回的附理由。
4. **仅对 🟢 有效项进行修复**。

### Step 5: Output Report
Generate a structured report, each issue includes:
- **Severity**: 🔴 Critical / 🟡 Warning / ✅ Compliant
- **Description**: Which rule was violated
- **File Location**: `filename:line` (e.g. `PrivacyActor.swift:45`)
- **Fix Suggestion**: Concrete code modification example
- **Related Rule**: Reference AGENTS.md section number

### 第六步：审查结论
- **阻断项（🔴）**：如果存在任何 🔴 项，输出：“❌ 审查未通过，建议拒绝合并。”
- **警告项（🟡）**：如果仅存在 🟡 项，输出：“⚠️ 审查有条件通过，建议修复警告后再合并。”
- **全部合规（✅）**：输出：“✅ 审查通过，建议合并。”

### Step 7: Auto-Refresh PR Description After Fixes (AGENTS.md §15.5)
After the Agent fixes defects per the review report and pushes, **must** perform these steps:
1. Use `gh pr edit [PR#] --body "[updated PR description]"` to refresh the PR description
2. Fully rewrite the AC coverage table, reflecting the actual post-fix state:
   - Fixed ACs → ✅
   - Clearly mark deferred ACs (🔴 deferred / 🔮 Phase 3 etc.)
   - Include status legend
3. Sync update `docs/05-planning/task-status.json` `notes` field for the corresponding task
4. Sync update core implementation file header AC coverage comment (`// AC 覆盖:` line)
5. Note in fix commit body: "Addresses PR review feedback: [list of fixed defects]"