# Echo UI 就绪门禁

> **上游权威**：`Echo SwiftUI UI Agent 自动化 Bootstrap 与执行规范.md` §3.1、§16
> **用途**：首次 bootstrap 或 readiness 复检时读取

---

## 1. Echo 当前状态（基于基准提交 `aaf1ff1f`）

1. Core 和数据层已有实质内容，非空项目
2. 当前 UI 仍接近占位状态（`ContentView.swift` = "Hello, world!"）
3. 仓库尚无稳定的 ViewModel 层、设计系统和确定性 UI fixtures
4. UI 自动化不能假设应用启动、数据库打开、隐私文案、CI 路径或模型资源已适合无人值守运行

---

## 2. 五类就绪门禁

### 2.1 Bootstrap 与数据库打开
- [ ] 明确 `DatabaseManager.open` 的成功、失败和重复调用语义
- [ ] 为 Preview 和 UI test 提供确定性入口（不访问生产数据）
- [ ] 数据库打开失败映射为可测试的启动状态
- [ ] **在此门禁通过前，不运行依赖真实数据库的 UI 自动化**

### 2.2 隐私 Policy 与 Source Identifier
- [ ] 统一 `photo`、`note`、`voice`、`search`、`geofence` 等 identifier 的授权语义
- [ ] 盘点 UI 隐私文案、配置、元数据和实际数据来源
- [ ] 若授权 identifier 不一致 → 试点停止

### 2.3 CI 与 SwiftLint 路径
- [ ] 校验 CI workflow 引用的 scheme/workspace/project/测试 target 和脚本路径实际存在
- [ ] 校验 SwiftLint 包含/排除/配置路径与当前仓库结构一致
- [ ] 路径错误必须先独立修复

### 2.4 模型产物与 ProximaKit 警告
- [ ] 明确模型产物是仓库资源、构建产物、运行时下载还是外部依赖
- [ ] 记录模型缺失/版本不匹配/不可用时的 UI 可观察行为
- [ ] ProximaKit warning 分类为：可接受、需修复、阻塞
- [ ] Agent 不得静默忽略 warning，也不得修改模型或 Core 集成

### 2.5 Xcode 26.5 与 Bridge Preflight
- [ ] 在 Echo 实际开发机执行 `xcodebuild -version`
- [ ] 记录可用 SDK、Simulator runtime 和双审查目标 device（iPhone 17 Pro iOS 26.5 + iPhone 16 Pro iOS 18.x）
- [ ] 执行 `mcpbridge` preflight（§11.2）：
  1. 确认 Xcode 26.5 为当前 `xcode-select`
  2. `xcrun --find mcpbridge` 返回实际路径
  3. Xcode Intelligence 设置允许外部 Agent
  4. OpenCode MCP 配置连接成功
  5. 最小 read/build/test smoke test
  6. 通过则记录 `mcpbridge` 为候选，失败则 CLI + XCTest fallback

---

## 3. 就绪结论

五类门禁全部有明确证据后，Echo 才能进入 `select_pilot`。任何未通过项记录为仓库就绪问题，不归因于 `echo-memory-canvas` 或某个 surface。`mcpbridge` preflight 失败允许使用 CLI + XCTest fallback 继续。

---

## 4. 复检触发条件

以下任一情况发生时，必须重新执行 readiness_check：
- Echo 仓库发生新的 commit（`sourceRevision` 变化）
- Xcode 版本或 SDK 升级
- `DatabaseManager` 公共接口变更
- 模型文件（`Echo/Resources/Models/`）增删或版本变更
- CI workflow（`.github/workflows/ci.yml`）或 SwiftLint（`.swiftlint.yml`）修改
- 上次 readiness_check 通过后超过 30 天
- `task-status.json` 中 Phase 3 或 Phase 3F 任务的 `dependencies` 发生变化
- `deferred-items.json` 中 Phase 3 / Phase 3F 相关条目发生变化（新增延期 / 移回 / 已解决）

复检时只验证受影响的类别，不重做全部五类门禁。hash 未变的门禁结果可复用。

---

## 5. 首次 Bootstrap 证据位置

| 证据 | 路径 |
|------|------|
| Inventory | 首次 bootstrap 对话记录 / `.ui-automation/` |
| Migration map | `.ui-automation/state.json` `migrationMapHash` |
| 保护路径清单 | `docs/ui/architecture.md` §4 |
| 命令兼容性清单 | `docs/ui/automation-workflow.md`、`.opencode/commands/` |
| Build log | 开发机本地 / CI artifact |

---

## 6. Phase 3F 感知

- **phase 为字符串**：`task-status.json` 的 `phase_order` / `current_phase` 均为字符串，包含 `"3F"`（`["1","2","3","3F","4","5"]`）
- **五类门禁适用**：Phase 3F UI 任务（3F.7–3F.10）沿用本文档全部就绪门禁；Phase 3F 引入的「默认 App 无 `-ui-fixture`」生产路径要求 §2.1 Bootstrap 与数据库打开门禁以真实（非 fixture）入口为准
- **双审查设备**：§2.5 的 Xcode 26.5 / Bridge Preflight 与双设备目标（iPhone 17 Pro iOS 26.5 + iPhone 16 Pro iOS 18.x）对 Phase 3F UI 交付同样有效
- **UI 模式匹配精确 `"3"`**：首次 bootstrap 的 `readiness_check` 在 `current_phase == "3"` 的 UI 模式下按原流程触发；`current_phase == "3F"` 时按通用流程（Phase 3F UI 任务经 `/ui-bootstrap-build-echo`）执行，复检触发条件含 Phase 3F（§4）
