---
name: pr-merge-echo
description: "审查并合并已批准的 Pull Request（需人类确认），更新任务状态"
---

> Codex migration: This is a repository-scoped native skill. Follow the
> repository `AGENTS.md` as the authority. Treat any remaining GitHub API
> wording as the equivalent `gh` CLI operation supported by the current
> environment. Never weaken human-only approval, PR merge, branch retention,
> privacy, or release gates. A sandboxed `gh auth status` failure is
> inconclusive. Apply the two-stage, read-only verification in `AGENTS.md`
> §15; request re-authentication only after an explicit credential rejection.


## 🔀 PR 合并

请按 Echo 项目 AGENTS.md 的 GitHub 自动化操作规约（第 15 章）执行：

> **核心原则**：合并操作必须由人类手动执行。Agent **在任何情况下都不得调用 `gh pr merge` 或任何合并命令**。本命令仅负责检查合并条件、生成合并建议，并等待人类手动合并。

> **🚫 绝对禁止 Agent 执行的操作**：
> - `gh pr merge` — 无论是否带 `--squash`/`--merge`/`--delete-branch`
> - 任何 GitHub API 合并请求
> - 任何修改远程分支的删除操作
>
> **合并是人类的专属权限。Agent 只能读取状态、输出报告。**

### 第一步：定位 PR
1. 如果用户提供了 PR 编号（如 `pr-merge-echo 42`），直接使用该 PR。
2. 如果未提供：
   - 使用 `gh pr list --head [branch] --json number,url,title,state` 检查当前分支对应的 PR。
   - 如果只有一个 PR，自动使用该 PR。
   - 如果有多个 PR，列出所有 PR（编号、标题、状态），让用户选择。
   - 如果没有 PR，提示：“当前分支没有关联的 PR，请先执行 `commit-pr-echo` 创建 PR。”

### 第二步：检查合并前门禁（§15.2）
逐一检查以下所有条件，**任一条件不满足即阻断合并**：

1. **CI 检查**：
   - 使用 `gh pr view [PR编号] --json mergeable,mergeStateStatus,statusCheckRollup` 查询合并与 CI 状态。
   - 状态必须为 `clean`（无冲突）且所有 CI 检查通过。
   - 如果 CI 失败，输出失败原因并退出。

2. **审查批准**：
   - 检查 PR 是否获得至少 1 名人类 Reviewer 的批准。
   - 如果未获批准，输出当前审查状态并退出。

3. **任务状态**：
   - 读取 `docs/05-planning/task-status.json`。
   - 确认该任务对应的 `status` 为 `review`。
   - 如果状态不是 `review`，提示：“任务状态为 [status]，需要先更新为 review 才能合并。”

4. **冲突检查**：
   - 检查 PR 是否有合并冲突。
   - 如果有冲突，输出冲突文件列表，提示“请手动解决冲突后再合并。”

5. **对话线程**：
   - 检查 PR 中是否有未解决的对话线程。
   - 如果有，列出未解决线程，提示"请先解决所有对话后再合并。"

6. **PR Review 延后项检查（AGENTS.md §15.5 规则 3）**：
   - 读取 `docs/05-planning/deferred-items.json` 的 `deferred_from_pr_review` 数组。
   - 筛选 `pr` 字段等于当前 PR 编号的条目。
   - 若存在延后项，输出清单（ID、标题、延后目标条件），并提示：
     "ℹ️ 本 PR 有 N 项审查发现被延后（已记录于 deferred-items.json）。合并后将在 Phase 集成测试时扫描追踪。"
   - 若存在延后项但**未记录**到 deferred-items.json（即 PR 描述中标注 🔮/deferred 但无对应 DEF- 条目），**阻断**并提示：
     "⛔ 存在未记录的延后项。请先执行 pr-review-echo 第八步将延后项写入 deferred-items.json，再合并。"

### 第三步：生成合并建议
1. **所有检查通过**：
   - 输出合并前检查报告（表格形式）。
   - 显示 PR 的合并策略建议（默认 `squash`）。
2. **建议的合并命令**：
   - **GitHub Web**：提示用户点击 PR 页面中的 "Squash and merge" 按钮。
   - **GitHub CLI**（供用户参考）：`gh pr merge [PR编号] --squash`
   - ⚠️ **禁止在建议命令中包含 `--delete-branch`**（违反 AGENTS.md §3.1.1 分支保留规则）。
   - **告知用户**：Agent 不会自动执行合并，请用户手动操作。

### 第四步：等待人类确认后更新状态
1. **等待**：输出 "✅ 合并前检查全部通过。请在 GitHub 上手动合并该 PR。" **然后停止，不要执行任何命令。**
2. **仅当用户明确告知"已合并"后**，才执行以下操作：
   - **首先** `git checkout dev-1.0`（切到 dev-1.0 分支）
   - **然后** `git pull origin dev-1.0`（拉取合并后的最新代码）
    - **接着在 dev-1.0 上**更新 `docs/05-planning/task-status.json`：
      - 将任务的 `status` 更新为 `done`。
      - 记录 `merged_at` 时间戳。
      - 更新 `last_updated` 时间戳。
      - 同步检查 `docs/05-planning/deferred-items.json`，确认是否有延期任务被本次合并解决（如对应的依赖已全部完成），若有则移至 `resolved_deferred` 并更新 `last_checked_at`。
- **级联更新 backlog → ready**（AGENTS.md §12.1）：按 `phase_order` 遍历每个 phase，对其 `tasks` 中 `status: backlog` 的任务，若其 `dependencies` 全部为 `done`/`merged`，则翻转为 `ready`。
- **Phase 入口门禁（`entry_gate`）**：对声明了 `entry_gate` 的 phase（如 phase `"4"` 的 `entry_gate: "3F.11"`），仅当该 gate 任务（按精确字符串 ID 查找）为 `done`/`merged` 时，才允许级联该 phase 的 backlog→ready；否则该 phase 视为锁定，跳过其全部任务的级联。
- **Phase `"3F"` finalizer 例外**：若被合并的任务是 phase `"3F"` 的集成测试任务 `"3F.11"`，**不得**自动级联 phase `"4"` 的 backlog→ready。Phase `"4"` 解锁只发生在人类合并 `"3F.11"` 后触发 finalizer 记录 `3F.finalize`（docs/05-planning/phase3f-execution-plan.md §10.1）时，由该 finalizer 显式把 `current_phase` 改为 `"4"` 并仅将 `4.1`–`4.9` 置为 `ready`。普通 pr-merge 流程只把 `3F.11` 置为 `done`，**不**改 `current_phase`、**不**改 phase `"4"` 任务状态。
   - **最后** `git add` → `git commit` → `git push origin dev-1.0`
   - ⚠️ **禁止在 feature 分支上更新 task-status.json**，必须切到 dev-1.0 操作。
3. 输出任务完成摘要：
   - 任务 ID 和标题。
   - 关联的用户故事。
   - 合并时间。
   - 提示："🎉 任务 [任务ID] 已完成！"
