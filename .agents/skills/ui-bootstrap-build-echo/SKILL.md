---
name: ui-bootstrap-build-echo
description: "Phase 3 UI 实现入口 — 执行 repo_discovery→materialize→readiness→pilot→contract→profile→generation→verification→Live Sim Review（双设备：iPhone 17 Pro iOS 26 + iPhone 16 Pro iOS 18）完整流水线。接受推荐 handoff 或 direct ready fallback"
---

> Codex migration: This is a repository-scoped native skill. Follow the
> repository `AGENTS.md` as the authority. Treat any remaining GitHub API
> wording as the equivalent `gh` CLI operation supported by the current
> environment. Never weaken human-only approval, PR merge, branch retention,
> privacy, or release gates. If `gh auth status` is invalid, stop external
> GitHub mutations and ask the user to re-authenticate.


## 🎨 Phase 3 UI Bootstrap Build

> **契约来源**：`Echo SwiftUI UI Agent 自动化 Bootstrap 与执行规范.md` §22.7
> **前置条件**：任务必须为 `ready`（direct fallback）或 `in_progress + automation_phase: selected`（推荐 handoff）
> **⚠️ 禁止**：`$do-task-echo` 对 Phase 3 UI 任务无效。Phase 3 UI 必须通过本命令执行。

---

## 第一步：验证起点 & 建立运行上下文

1. 读取 `docs/05-planning/task-status.json`、`docs/05-planning/deferred-items.json` 和 `.ui-automation/state.json`（若存在）。
2. 验证任务合法性：
   - `current_phase` 精确等于 `"3"`（用 `^3$` 精确匹配，**不得**捕获 `"3F"`）
   - 任务属于 phase `"3"`（通过该 phase 的 `tasks` 数组**包含关系**确定）
   - 全部 `dependencies` 为 `done`
3. 接受两种起点（其他组合停止并报告证据）：

| 模式 | 条件 | 行为 |
|------|------|------|
| **Direct fallback** | `status == ready`，无冲突 active run | 将任务 `ready → in_progress`，创建 `.ui-automation/state.json`，推进到 `repo_discovery` |
| **推荐 handoff** | `status == in_progress` + manifest `task_id` 匹配 + `automation_phase == selected` | 不重复写账本、不创建新 run ID，将 manifest 从 `selected` 推进到 `repo_discovery` |

4. 两种模式都**不得**改 title、phase、dependencies、test file 或其他任务。

---

## 第二步：仓库发现（`repo_discovery`）

5. 定位 Echo 仓库根目录（交叉确认 project/workspace/scheme/version control 元数据）。
6. 读取以下文件建立完整上下文：
   - 根目录 `AGENTS.md`
   - `docs/INDEX.md`
    - `docs/05-planning/task-status.json`
    - `docs/05-planning/deferred-items.json`
   - `docs/ui/README.md`、`docs/ui/echo-memory-canvas-style.md`
   - `.agents/skills/` 目录下全部 Echo skills
   - `.swiftlint.yml`
   - `.github/workflows/ci.yml`
7. 列出受保护路径清单（`docs/ui/architecture.md` §4）。
8. 更新 `.ui-automation/state.json`：`automation_phase: repo_discovery`、`inventoryHash`。

---

## 第三步：结构物化（`materialize_structure`）

9. 若此前 bootstrap 已物化，检查 hash 一致性后跳过。若缺失文件或 hash 不一致：
   - 生成 migration map，逐项标明 `exists/create/merge/adapt-path/blocked`
   - 缺失文件创建、已有文件按语义合并（不盲目覆盖）
   - 创建 `EchoTests/Phase${phase.id}/` 目录（若不存在；phase `"3"` → `EchoTests/Phase3/`，**不**映射为 `Phase3F`）
   - **每批结构变更后编译**：`xcodebuild build -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
10. 更新 `.ui-automation/state.json`：`automation_phase: materialize_structure`、`migrationMapHash`。

---

## 第四步：就绪检查（`readiness_check`）

11. 按 `docs/ui/echo-readiness.md` 执行五类门禁：

### 4.1 Bootstrap 与数据库打开
- 检查 `DatabaseManager` 公共接口，确认 Preview/UI test 确定性入口可用

### 4.2 隐私 Policy 一致性
- 检查 policy 中 `photo/note/voice/search/geofence` identifier 统一性
- 若不一致，停止并记录 blocker

### 4.3 CI 与 SwiftLint 路径
- 校验 CI workflow 引用的 scheme/workspace/project/测试 target 实际存在
- 校验 SwiftLint 路径与当前仓库一致

### 4.4 模型产物与 ProximaKit
- 确认模型文件位置（`Echo/Resources/Models/`）
- 分类 ProximaKit warning 为：可接受/需修复/阻塞

### 4.5 Xcode 26.5 与 Bridge Preflight
- 在 Echo 实际开发机执行 `xcodebuild -version`，记录真实 Build/SDK/runtime
- 按以下顺序验证 `mcpbridge`：
  1. 确认 Xcode 26.5 为 `xcode-select` 路径
  2. `xcrun --find mcpbridge` 返回实际路径
  3. 确认 Xcode Intelligence 设置允许外部 Agent
  4. Codex 环境可调用预期工具；否则记录原因并使用 CLI + XCTest fallback
  5. 最小 read/build/test smoke test
  6. 通过 → 记录 `mcpbridge` 为候选 owner；失败 → 记录原因，自动选择 CLI + XCTest fallback
- Bridge 失败**不阻塞 UI 工作**

12. 五类门禁都有证据后进入下一步。任何未通过项记录为 blocker。
13. 更新 `.ui-automation/state.json`：`automation_phase: readiness_check`、xcode/mcpbridge 字段。

---

## 第五步：选择试点（`select_pilot`）

14. 按 `docs/ui/automation-workflow.md` §8 评分规则：
   - 从 inventory 列出所有可独立呈现的 surface/journey（≥3 有意义状态）
   - 八个维度评分，淘汰硬条件（需签名/真实数据/迁移/Core 修改）
   - 选总分最高者。并列时依次选保护路径面更小、新文件更少、运行时间更短者
15. 记录候选、分数、淘汰原因、最终选择。
16. 更新 `.ui-automation/state.json`：`automation_phase: select_pilot`。

---

## 第六步：契约草拟（`contract_drafting`）

17. 为试点 surface 创建契约（写入 `UIAutomation/Contracts/`）：
   - `surfaceId`、`surfaceFamily`（discovery|focus|task）
   - 至少 3 个有意义的 `stateId`（loaded/empty/loading/error 等）
   - `actionId` 和 `journeyId`
   - 确定性 fixture（写入 `UIAutomation/Fixtures/`）
18. 校验 schema 版本、必需字段、交叉引用。
19. 契约符合既有 policy → 自动继续；不符合 → `awaiting_exception_decision`。
20. 更新 `.ui-automation/state.json`：`automation_phase: contract_drafting`、contract/fixture hash。

---

## 第七步：设计 Profile 验证（`design_profile_validation`）

21. 从 `docs/ui/echo-memory-canvas-style.md` 读取并验证：
   - `profileId == "echo-memory-canvas"` + 批准记录
   - `baseProfile == "apple-native"`
   - 为 surface 声明正确的 `surfaceFamily`
   - **Discovery** 验证 masonry 启用条件、稳定排序、卡片 variant、单列/List 回退
   - **Focus** 验证使用单列 + grouped metadata，**不得使用 masonry**
   - **Task** 验证使用 Form/List/Sheet/Alert/Menu/Toolbar，**不得使用 masonry**
22. 验证共享 token（typography/semantic colors/accent/radii/spacing/materials/SF Symbols）
23. 更新 `.ui-automation/state.json`：`automation_phase: design_profile_validation`、design profile 字段。

---

## 第八步：UI 切片生成（`ui_slice_generation`）

24. 为试点 surface 生成一个可编译的 UI 切片：
   - **SwiftUI Views**：使用 typed state、action closure
   - **薄 Adapter**：`@MainActor @Observable`，映射 Core 输出为 UI state，转发 user action 为 intent
   - **Preview**：每个关键 state 有具名 Preview
   - **确定性 Fixtures**：Preview 和测试使用 fixture loader
25. 实现约束：
   - View 不直接写数据库、不读取全局数据库状态
   - Adapter 不保存第二份领域真相
   - **不修改 Core、数据模型、数据库 schema 或业务规则**
   - **不复制 Pinterest 品牌、文案、控件或 trade dress**
   - 使用系统容器和组件（`NavigationStack`、`List`、`Form`、SF Symbols、system font 等）
26. **编译检查**：`xcodebuild build -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
27. 更新 `.ui-automation/state.json`：`automation_phase: ui_slice_generation`。

---

## 第九步：验证（`verification`）

28. 执行以下验证（按 `docs/ui/testing-and-artifacts.md`）：
   - **契约验证**：schema 版本、交叉引用、fixture 解码
   - **Build**：clean build 成功
   - **单元测试**：adapter 测试、view 状态测试
   - **XCUITest**：journey 行为验证（使用 accessibility identifier，不依赖坐标）
   - **Accessibility**：自动 audit、元素存在性、Dynamic Type、文本截断
   - **Discovery surfaces**：验证 masonry 启用条件、稳定排序、回退行为
   - **Focus/Task surfaces**：验证不存在 masonry
29. 收集证据到 `UIAutomation/Artifacts/`：
   - Raw build log
   - 结构化测试摘要
   - Accessibility tree
   - 必要 `.xcresult`
   - Run manifest
   - **禁止 screenshot、reference/actual/diff、video**
30. 任一验证失败 → 记录 blocker，按 `docs/ui/automation-workflow.md` §5 重试规则处理。
31. 更新 `.ui-automation/state.json`：`automation_phase: verification`、artifacts、blockers。

---

## 第十步：Live Simulator 交付审批（`awaiting_delivery_approval`）

> **双设备审查**：Live Simulator Review 必须**同时**在以下两台设备上进行，分别覆盖 iOS 26 与 iOS 18 两个平台：
> - **iPhone 17 Pro（iOS 26.5）**：主审查设备（最新平台 / 主开发 runtime）
> - **iPhone 16 Pro（iOS 18.x）**：最低支持版本审查设备（部署目标 iOS 18.0）
>
> 构建产物统一以 `iPhone 17 Pro` 为 destination 编译（见 AGENTS.md §9.4），同一产物安装到两台设备。两台设备均使用相同 fixture 与 launch argument，保证审查状态一致。

32. **生成 UI 审查指南**（在报告前完成，依据：`.ui-automation/state.json` 的 `files_created`/`files_modified`、`UIAutomation/Contracts/`、代码中的 `🔮 Phase 3.x` / `stub` / `fixture` / `deferred` 标记）：
   - **本次添加/修改的页面清单**：页面名称 + 变更类型（🆕 新增 / ✏️ 修改）+ 对应文件路径
   - **导航路径**：从 App 哪个入口（Tab / 列表项 / 按钮）点击、如何到达该页面（逐条可执行步骤）
   - **未实现功能 / 临时效果**：逐项列出 —— 哪些功能标注 `🔮` 未实现（含目标 Phase）、当前为 fixture/stub 驱动的临时数据效果、String Catalog 未迁移等已知临时状态
33. 使用唯一 simulator owner 构建 App（destination 为 `iPhone 17 Pro`），并**同时**安装、启动到两台审查设备：
   - iPhone 17 Pro（iOS 26.5）— 主审查设备
   - iPhone 16 Pro（iOS 18.x）— 最低版本审查设备
34. 在两台设备上分别通过确定性 fixture + launch argument 或契约声明的路径，导航到任务目标 `surfaceId/stateId`。
   - **不得用无法复现的临时数据库或真实用户数据**
35. 两台设备导航完成后，**停止 tap/swipe/输入和自动修正**，保持两台 Simulator/App/目标界面均在前台。
36. 在对话中报告（两台设备信息并列，**必须包含审查指南三区块**）：
   ```
   ## 🖥️ Live Simulator Review

   **Task**：[taskID]
   **Device 1（主审查）**：[iPhone 17 Pro] [UDID] — [iOS 26.5]
   **Device 2（最低版本）**：[iPhone 16 Pro] [UDID] — [iOS 18.x]
   **Surface**：[surfaceId]
   **State**：[stateId]
   **Fixture**：[fixtureId]

   ### 📄 本次添加/修改的页面
   | 页面 | 变更 | 说明 | 文件 |
   |------|:---:|------|------|
   | [页面名] | 🆕 新增 | [一句话说明] | [路径] |
   | [页面名] | ✏️ 修改 | [一句话说明] | [路径] |

   ### 🧭 如何查看这些页面（导航路径）
   1. 打开 Echo App → 点击底部 Tab Bar 的 **[Tab 名]**（[图标描述]）
   2. [下一步操作]
   3. [如需输入/交互，明确写出]（例如：点击搜索框 → 输入任意文字 → 回车）

   ### 🔮 未实现功能 / 临时效果
   | 位置/功能 | 当前效果 | 计划 |
   |------|---------|------|
   | [功能名] | 当前为 [fixture 示例数据 / stub 返回 / 占位] | Phase 3.x 接入 [真实实现] |
   | [交互]（如点击结果卡片） | 无跳转 | Phase 3.x [MemoryDetailView 等] |
   | 文案 | 硬编码英文 | Phase 3.8 String Catalog |

   ### 已验证
   - [✅] Build（iPhone 17 Pro destination）
   - [✅] Contract validation
   - [✅] Unit tests
   - [✅] Accessibility audit
   - [✅] Surface family rules
   - [✅] 双设备安装与导航（iOS 26 + iOS 18）

   ### 已知风险
   [如有]

   ---
   **请直接查看两台 Simulator 中的界面（iOS 26 与 iOS 18），然后回复批准或具体修改意见。**
   ```
37. **不 commit、不 push、不创建 PR、不标记 `review` 或 `done`。**
38. **不调用 screenshot/recording API。**
39. 用户明确批准后 → 运行状态记录 `accepted`；项目任务**仍保持 `in_progress`**。

---

## 第十一步：恢复运行

39. 若 init 报告已有 UI task `in_progress`：
   - 用户调用本命令时，Agent 先确认账本任务仍为 `in_progress`、运行状态 `task_id` 一致且活动 run 唯一
   - 从 `selected` 或最早失效 phase 恢复
   - 恢复不重复改账本状态、不新建 run ID
   - 不重做证据完整且 hash 未变的阶段

---

## 安全与停止规则

| 条件 | 行为 |
|------|------|
| 修改 Core、数据模型、数据库迁移 | 立即 `stopped` |
| 猜测领域规则 | 立即 `stopped` |
| 需生产签名、真实用户数据 | 立即 `stopped` |
| 契约/方向/验收策略未批准变化 | 立即 `stopped` |
| Simulator 重复所有者（同一设备被多个 run/owner 控制；双审查设备为同一 owner 合法持有） | 立即 `stopped` |
| Artifact 含凭据/PII | 立即 `stopped` |
| 自动重试 2 次失败 | `failed`，保留 artifact |
| 环境错误 | 首次健康检查+清理→重试1次；再次失败→`failed` |

---

## 工具名映射

按当前 Codex 环境选择只读文件、补丁编辑和文本搜索工具；不得依赖旧 Agent 的工具名称。

不得借此放宽权限或自动交付。
