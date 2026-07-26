# Echo UI 自动化工作流

> **上游权威**：`Echo SwiftUI UI Agent 自动化 Bootstrap 与执行规范.md` §6、§11、§14、§19、§22
> **对应命令**：`/ui-bootstrap-build-echo`、`/init-session-echo`（UI 分支）、`/next-task-echo`（UI 分支）

---

## 1. Bootstrap 与持续执行状态机

```
selected → repo_discovery → materialize_structure → readiness_check
→ select_pilot → contract_drafting → design_profile_validation
→ ui_slice_generation → verification → awaiting_delivery_approval → accepted
                                              ↑
                           awaiting_exception_decision（条件触发）
```

### 状态定义

| 状态 | 含义 | 触发 |
|------|------|------|
| `selected` | next 创建的 handoff checkpoint | `/next-task-echo`（Phase 3 UI 模式） |
| `repo_discovery` | 定位仓库根、读取指令、建立 inventory | ui-bootstrap 自动 |
| `materialize_structure` | 生成 migration map，创建目录和文件 | ui-bootstrap 自动 |
| `readiness_check` | 执行仓库、环境、Core 接口、Echo 门禁 | ui-bootstrap 自动 |
| `select_pilot` | 按通用评分选择低风险代表性切片 | ui-bootstrap 自动 |
| `contract_drafting` | 形成 surface/state/action/journey/fixture 契约 | ui-bootstrap 自动 |
| `design_profile_validation` | 确认 echo-memory-canvas 和 surface-family | ui-bootstrap 自动 |
| `ui_slice_generation` | 一次生成一个可评审 UI 切片 | ui-bootstrap 自动 |
| `verification` | 执行验证并归档证据 | ui-bootstrap 自动 |
| `awaiting_exception_decision` | 已定义条件触发 | 异常时自动进入 |
| `awaiting_delivery_approval` | 等待用户查看 Live Simulator | 验证通过后自动进入 |
| `accepted` | 用户批准 | 用户明确批准后 |

**终止状态**：`failed`（重试耗尽）、`stopped`（安全/范围/保护路径规则触发）

---

## 2. 一个固定批准点 + 一个条件决策点

### 固定交付批准点：Live Simulator Review
- Agent 导航到契约 UI state → 保持 Simulator 前台 → 停止操作
- 用户直接查看 → 明确批准或提出修改
- **Agent 不能自行批准界面**
- 不生成或持久化 screenshot/video

### 条件决策点
仅在以下情况触发：
- Agent 无法收敛
- 需要新增 token、组件、导航、依赖、权限
- 需要解释不明确的 Core 语义
- 未经决定不得扩大范围或猜测

---

## 3. 自动继续规则

以下状态转换**自动继续**，不等待人工审批：
- `repo_discovery` → `materialize_structure`（结构物化自动触发）
- `materialize_structure` → `readiness_check`（物化后自动进入就绪检查）
- `readiness_check` → `select_pilot`（就绪通过后自动选择试点）
- `select_pilot` → `contract_drafting`（试点选定后自动草拟契约）
- `contract_drafting` → `design_profile_validation`（契约 schema 通过 policy 校验后自动验证 profile）
- `design_profile_validation` → `ui_slice_generation`（profile 与已批准的 echo-memory-canvas 一致后自动生成）

下列操作**不触发审批**：
- 使用现有系统组件、已有 token、薄 adapter
- Fixtures、Preview、测试

---

## 4. 唯一 Simulator 所有者

- 每次运行只能有一个 simulator 生命周期与交互所有者
- 默认 fallback：CLI + XCTest（`xcodebuild`、`simctl`、`xcresulttool`）
- Xcode 26.5 上 `mcpbridge` 通过 preflight 后可成为候选
- 最终选择记录在 run manifest

---

## 5. 重试、停止规则

### 错误分类（5 类型）

| 类型 | 描述 | 可重试 | 最大重试 | 特殊规则 |
|------|------|:---:|:---:|------|
| **contract** | Schema 无效、引用缺失、fixture-state 不一致 | ✅ | 2 | 需改变的假设或修复点 |
| **implementation** | 编译失败、类型错误、adapter 映射错误、测试断言失败 | ✅ | 2 | 需改变的假设或修复点 |
| **environment** | Simulator 不健康、进程挂起、DerivedData 污染、工具不可用 | ✅ | 1 | 首次：健康检查+清理→重试1次；再次：failed |
| **product_divergence** | 偏离 echo-memory-canvas、apple-native 基础、surface-family 映射、信息层级 | ❌ | 0 | 返回 `awaiting_exception_decision` |
| **security_scope** | 触碰保护路径、请求真实凭据、产生敏感 artifact、修改验收规则 | ❌ | 0 | 立即 `stopped`，不消耗重试预算 |

### 自动重试
- 同阶段最多 2 次有证据支持的修复重试
- 每次重试必须改变具体假设或修复点，禁止无差别循环
- 环境错误首次出现：健康检查 + 清理 → 再重试 1 次
- 第 2 次失败 → `failed`，保留全部 artifact

### 立即停止（`stopped`）
- 修改 Core、数据模型、数据库迁移或保护配置
- 需要猜测领域规则
- 需要生产签名、发布凭据、真实用户数据
- 契约/方向/验收策略存在未批准变化
- Simulator 重复所有者或控制冲突
- Artifact 包含凭据、PII

---

## 6. 恢复规则

- 从最早失效的完整成功阶段继续
- 输入 hash 变化 → 使其影响范围内的后续状态和 artifact 失效
- 环境超时 → 终止进程组，检查残留
- 安全停止 → 只能由授权人确认后恢复

---

## 7. 任务账本桥接

- `docs/05-planning/task-status.json` 是项目 phase、任务生命周期唯一权威
- `.ui-automation/state.json` 只保存单次 UI 运行状态，通过 `task_id` 外键关联
- 一个 task 同时只能有一个活动 UI run
- 两者不一致时停止，不以运行状态修正项目账本

---

## 8. 试点评分

候选必须：≥3 个有意义可确定复现状态、不需签名/真实数据/迁移/Core 修改。

| 维度 | 评分 |
|------|------|
| 状态代表性 | 3 状态=2 分，4+=3 分 |
| Core 接口成熟度 | 单一稳定 API=3 分 |
| 数据风险 | 完全合成离线=3 分 |
| UI 范围 | 单 surface=3 分 |
| Profile 适配度 | 明确 surface family=3 分 |
| 系统组件覆盖 | 主要用 Apple 原生=3 分 |
| 验证价值 | 全链路覆盖=3 分 |
| 环境依赖 | 无网络/模型/权限=3 分 |

先淘汰硬条件，选总分最高者。并列时依次选保护路径面更小、新文件更少、运行时间更短者。
