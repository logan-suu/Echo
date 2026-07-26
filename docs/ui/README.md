# Echo UI 文档路由

> **责任**：告诉 Agent 针对 UI 任务读取哪份文档，而不是让 Agent 重读 bootstrap 全文
> **无需读取本文全文**：按任务选择下表对应文档即可
> **最后同步 bootstrap**：2026-07-25

---

## 文档地图

| 文档 | 路径 | 用途 | 何时读取 |
|------|------|------|----------|
| **设计风格** | `echo-memory-canvas-style.md` | 完整 Apple 原生基础、Discovery/Focus/Task 映射、共享 token、内容卡片、响应式与可访问性、禁止项 | 任何 UI 实现任务 |
| **自动化工作流** | `automation-workflow.md` | 状态机、任务账本桥接、自动继续、唯一 simulator 所有者、重试、停止、恢复、试点评分和批准点 | 执行 `/ui-bootstrap-build-echo` 时 |
| **架构** | `architecture.md` | 六层职责、单向数据流、组件边界、受保护和允许内容 | 理解 UI 层与 Core 层的边界时 |
| **测试与 Artifact** | `testing-and-artifacts.md` | PR 与 nightly 矩阵、artifact 字段、测试层级、安全、各阶段 Definition of Done | 编写测试或收集 artifact 时 |
| **命令兼容性** | `command-compatibility.md` | 14 个现有命令 + 3 个新增命令在 Phase 3 UI 模式下的行为表 | 不确定某个命令是否可用于 Phase 3 时 |

---

## 按任务选择

| 任务 | 必读文档 |
|------|----------|
| Phase 3 UI 实现（3.1–3.9） | `echo-memory-canvas-style.md` + `architecture.md` |
| UI 测试 | `testing-and-artifacts.md` |
| UI 交付 | `automation-workflow.md`（§批准点） |
| 首次 bootstrap | `echo-readiness.md` + `automation-workflow.md` |

---

## 实际路径映射

| 提案路径 | 实际路径 | 状态 |
|----------|----------|------|
| `docs/ui/README.md` | `docs/ui/README.md` | ✅ |
| `docs/ui/echo-memory-canvas-style.md` | `docs/ui/echo-memory-canvas-style.md` | ✅ |
| `docs/ui/automation-workflow.md` | `docs/ui/automation-workflow.md` | ✅ |
| `docs/ui/architecture.md` | `docs/ui/architecture.md` | ✅ |
| `docs/ui/testing-and-artifacts.md` | `docs/ui/testing-and-artifacts.md` | ✅ |
| `docs/ui/echo-readiness.md` | `docs/ui/echo-readiness.md` | ✅ |
| `UIAutomation/Contracts/` | `UIAutomation/Contracts/` | ✅ |
| `UIAutomation/Fixtures/` | `UIAutomation/Fixtures/` | ✅ |
| `UIAutomation/Policies/` | `UIAutomation/Policies/` | ✅ |
| `UIAutomation/Artifacts/` | `UIAutomation/Artifacts/` | ✅ |
| `.ui-automation/state.json` | `.ui-automation/state.json` | ✅ |

---

## 权威顺序

冲突时按以下顺序，前者高于后者：
1. 用户当前明确指令 + 仓库根 `AGENTS.md` + 受保护政策
2. `docs/05-planning/task-status.json`（项目 phase、任务生命周期唯一权威）
3. `UIAutomation/Contracts` 与 `UIAutomation/Policies`（UI 机器契约）
4. 本目录下的拆分设计文档
5. 原始 bootstrap 规范（仅首次初始化输入，物化后不再是运行权威）
