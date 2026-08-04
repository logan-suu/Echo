# Echo Phase 3 UI 命令兼容性表

> **上游权威**：`Echo SwiftUI UI Agent 自动化 Bootstrap 与执行规范.md` §22.4
> **用途**：一站式查看所有 14 个现有命令 + 3 个新增 UI 命令在 Phase 3 UI 模式下的行为
> **3F-aware**：命令流水线感知 Phase 3F——`task-status.json` 的 phase 为字符串（含 `"3F"`），UI 模式仅在 `current_phase == "3"` 精确匹配时进入；Phase 3F 任务（**含 UI 任务 3F.7–3F.10**）统一按 canonical plan §7 + §6.2.2 协议执行，`/ui-bootstrap-build-echo` 为 Phase 3 专用。详见下文「Phase 3F 感知」。
> **物化日期**：2026-07-26

---

## 14 个现有命令 + 3 个新增命令

| # | 命令 | Phase 3 UI 行为 | 分类 | 定义文件 |
|---|------|----------------|------|----------|
| 1 | `init-session-echo` | **UI 模式**：只读初始化、级联 backlog→ready、报告 UI bootstrap 可用性、不选任务、不写 manifest。UI 模式仅在 `current_phase == "3"`（精确字符串匹配）时触发；`"3F"` 时按通用流程运行 | 🟢 适配 | `init-session-echo.md` |
| 2 | `next-task-echo` | **UI handoff**：选择 ready 任务→`in_progress`、创建 `selected` checkpoint、打印 `/ui-bootstrap-build-echo`。仅 `current_phase == "3"` 时进入 UI handoff；`"3F"` 时按通用 next-task 流程 | 🟢 适配 | `next-task-echo.md` |
| 3 | `status-echo` | **UI 感知**：同时报告项目账本 + `.ui-automation/state.json` UI 运行状态 | 🟢 适配 | `status-echo.md` |
| 4 | `do-task-echo` | **🔴 阻断（仅 Phase 3 UI）**：Phase 3 UI 实现任务（3.1–3.9）禁止使用，重定向到 `/ui-bootstrap-build-echo`；集成测试（3.10）例外。Phase 3F 任务（含 3F.7–3F.10）走标准模式，但权威交付按 canonical plan §7 + §6.2.2 协议（见下文「Phase 3F 感知」） | 🔴 阻断 | `do-task-echo.md` |
| 5 | `retry-task-echo` | **🔴 重定向**：Phase 3 UI 任务重定向到 `/ui-retry-echo`；Phase 3F 任务按 execution-plan §9 失败恢复流程处理 | 🔴 重定向 | `retry-task-echo.md` |
| 6 | `commit-pr-echo` | **交付门禁**：PR 前验证 `accepted` 审批状态（双设备 Live Sim Review 已通过），禁止 `git add -A` | 🟢 适配 | `commit-pr-echo.md` |
| 7 | `read-spec-echo` | **路由适配**：Phase 3 / Phase 3F UI 任务路由到 `docs/ui/echo-memory-canvas-style.md` + `docs/ui/architecture.md` | 🟢 适配 | `read-spec-echo.md` |
| 8 | `pr-review-echo` | **部分适配**：读取 UI artifact 和批准记录，但不能代替 Live Sim 视觉批准或人类 merge | 🟡 部分 | `pr-review-echo.md` |
| 9 | `explain-echo` | **不变**：只读解释，Phase 3 / Phase 3F UI 代码同样适用 | ⚪ 不变 | `explain-echo.md` |
| 10 | `sync-docs-echo` | **不变**：同步范围含 `docs/ui/` 和 `.ui-automation/` | ⚪ 不变 | `sync-docs-echo.md` |
| 11 | `test-unit-echo` | **不变**：`xcodebuild test` 对 Phase 3 / Phase 3F UI 测试（含 `EchoTests/Phase3F/`、`EchoUITests` 套件）同样适用 | ⚪ 不变 | `test-unit-echo.md` |
| 12 | `test-phase-echo` | **不变**：Phase 3 集成测试（3.10）与 Phase 3F 集成测试（3F.11）均走标准流程 | ⚪ 不变 | `test-phase-echo.md` |
| 13 | `test-integration-echo` | **不变**：全量集成测试对 Phase 3 / Phase 3F UI 同样适用 | ⚪ 不变 | `test-integration-echo.md` |
| 14 | `pr-merge-echo` | **不变**：人类 merge 控制不变，Phase 3 / Phase 3F UI 任务同样适用 | ⚪ 不变 | `pr-merge-echo.md` |
| — | — | — | — | — |
| 15 | `ui-bootstrap-build-echo` | **Phase 3 UI 实现入口（Phase 3 专用）**：11 步完整流水线（discovery→materialize→readiness→pilot→contract→design→generate→verify→双设备 Live Sim Review 17 Pro + 16 Pro）。校验 `current_phase == "3"` 精确匹配；Phase 3F UI 任务（3F.7–3F.10）按 §7 + §6.2.2 协议执行（见「Phase 3F 感知」），**不经本命令** | 🆕 新增 | `ui-bootstrap-build-echo.md` |
| 16 | `ui-status-echo` | **只读双状态查询**：项目账本 + UI 运行状态 + 下一合法动作 | 🆕 新增 | `ui-status-echo.md` |
| 17 | `ui-retry-echo` | **受限阶段重试**：2 次预算、hash 失效验证、blocker 证据检查 | 🆕 新增 | `ui-retry-echo.md` |

---

## Phase 3F 感知

- **phase 为字符串**：`task-status.json` 的 `phase_order` / `current_phase` 均为字符串，包含 `"3F"`（`["1","2","3","3F","4","5"]`）
- **UI 模式匹配精确 `"3"`**：`init-session-echo`、`next-task-echo` 的 UI 分支仅在 `current_phase == "3"` 时进入；`current_phase == "3F"` 时走通用流程，UI bootstrap 模式不自动触发
- **全部 3F 任务按 canonical plan §7 + §6.2.2 协议执行**：`phase3f-execution-plan.md` §7 规定 3F.1–3F.11（**含 UI 任务 3F.7 UI→Core 全域接线、3F.8 Awakening、3F.9 Translation/Creation、3F.10 i18n/accessibility/errors**）统一走任务清单（RED→focused→cumulative→Release→static 门禁）→ §6.2.2 单脚本交付（evidence marker 校验→commit→push→PR→ledger）→ 人类合并，**无一引用 `/ui-bootstrap-build-echo`**。3F.7–3F.10 的 checklist 额外含双设备 Live Simulator Review、AX tree、统一日志、无媒体 manifest（`visualMediaCaptured: false`）与 §4.6.7–4.6.10 的 UIAutomation Contracts/Fixtures。`/ui-bootstrap-build-echo` 为 Phase 3 专用（校验 `current_phase == "3"` 精确匹配），**不适用于 Phase 3F**
- **同一设计 profile 与规则**：Phase 3F UI 工作延续已批准的 `echo-memory-canvas` 配置与 `docs/ui/` 全部规则（双设备 Live Simulator Review、无媒体 manifest `visualMediaCaptured: false`）
- `3F.0` 人类合并后，standing authority 允许在任务穷尽式 Files 清单内修改 UI-adjacent Core 接线文件（如 3F.7）

---

## 分类图例

| 标记 | 含义 |
|:----:|------|
| 🟢 适配 | 原命令追加了 Phase 3 UI 分支或门禁逻辑 |
| 🔴 阻断 | Phase 3 UI 任务禁止使用，需重定向到对应 UI 命令 |
| 🔴 重定向 | 自动重定向到对应的 UI 专用命令 |
| 🟡 部分 | 部分适配，但某些 Phase 3 UI 场景需额外注意 |
| ⚪ 不变 | 行为无变化，Phase 3 UI 和非 UI 任务相同 |
| 🆕 新增 | Phase 3 UI bootstrap 中全新创建的专用命令 |

---

## Phase 3 UI 推荐三命令序列

```
/init-session-echo → /next-task-echo → /ui-bootstrap-build-echo <task-id>
```

Direct fallback（跳过 init/next）：
```
/ui-bootstrap-build-echo <ready-task-id>
```

---

## 溯源

- 命令文件：`.opencode/commands/*.md`
- 设计规范：`docs/ui/echo-memory-canvas-style.md`
- 自动化工作流：`docs/ui/automation-workflow.md`
- AGENTS.md §17：Phase 3 UI 协作规约
