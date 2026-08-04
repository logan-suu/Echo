# UIAutomation/Policies

本目录保存 UI 自动化的机器可读策略文件。

## 文件

| 文件 | 内容 |
|------|------|
| `acceptance-policy.json` | acceptance 规则：门禁条件、矩阵定义、通过阈值 |
| `protected-paths.json` | 受保护路径清单：禁止修改的文件和目录 |
| `simulator-ownership.json` | 单 owner 规则：并发控制与冲突解决 |
| `retry-policy.json` | 重试预算：阶段限制、错误分类、降级策略 |
| `media-policy.json` | 媒体限制：禁止 screenshot/video 的具体规则 |
| `secret-policy.json` | 敏感信息扫描规则：PII、凭据、签名材料 |

## 保护路径（概述）

默认只读类别：
1. Core 领域逻辑和公共语义
2. 数据模型、数据库 schema、迁移和持久化规则
3. `DatabaseManager` 的打开、事务和生命周期规则
4. 隐私声明、签名、entitlements、发布配置和 secrets
5. CI 安全门禁、SwiftLint 基线和 acceptance policy
6. Live Simulator 审批规则
7. 模型文件、模型下载或打包逻辑、ProximaKit 集成边界

## Phase 3F 后的受控编辑权限（3F.0 合并后生效）

`3F.0`（docs-only bootstrap PR）被人类合并后，Phase 3F 获得**受任务范围约束**的编辑权限，替代「Core 全目录绝对只读」的默认状态。该权限**不**覆盖任何默认停止规则，且仅对 `3F.1`–`3F.11` 生效。

| 谁 | 可以编辑什么 | 条件 |
|----|-------------|------|
| 3F 任务（3F.1–3F.11） | Core actors/pipelines/models、UI、测试、Xcode 工程、CI、发布配置 | 仅当该任务 `docs/05-planning/phase3f-execution-plan.md` 中的**穷尽式 Files 清单**点名该精确路径；且 `3F.0` 已由人类合并 |
| 任何 3F 任务 | 文档、planning、UIAutomation contracts/fixtures、policy 文件 | 仅限该任务 §4.6 文档合同列出的精确路径 |
| 人类 | PR 合并、关闭 PR、删除本地/远程分支、任何超出当前任务明确范围的操作 | 始终为人类专属操作，不授予 Agent |

强制保留（不因上述权限而削弱）：

1. **停止规则**：任何写入不在当前任务 Files 清单内的受保护路径 → 立即 `STOPPED`，severity 不变，不消耗重试预算（`protected-paths.json` `stop_rule`）。
2. **受保护资产**：7 类 `protected_categories` 的路径与 `stopped` severity 全部原样保留，禁止模糊路径或泛化通配符扩大范围；RED 必须改动清单外文件时任务置 `blocked`，仅可通过人类批准的 scope PR 扩展。
3. **重试上限**：`max_retries_per_phase = 2`、环境错误 1 次、product_divergence/security_scope 零重试；三次不同方案失败后恢复最近绿色提交并置任务 `blocked`，提供 2-3 个决策选项（`retry-policy.json` §9）。
4. **无覆盖规则**：不覆盖既有已批准工作；worktree/branch 的 no-overwrite、no-reset、no-clean、no-delete 规则不变。
5. **无媒体规则**：禁止生成或持久化 screenshot/video/reference/actual/diff（`media-policy.json`）；只使用双设备 Live Simulator Review（iPhone 17 Pro iOS 26 + iPhone 16 Pro iOS 18）、AX tree、统一日志与结构化 manifest，`visualMediaCaptured: false`。
6. **机密规则**：PII、凭据、签名材料不得进入任何 artifact（`secret-policy.json`）；单一 simulator owner 规则不变（`simulator-ownership.json`）。
7. **门禁阈值**：acceptance 矩阵与验证门禁的阈值全部保留，Phase 3F 只增加 mandatory gates，不降低任何门槛（`acceptance-policy.json`）。

## 人工批准规则

- 最终视觉审批只通过双设备 Live Simulator Review（iPhone 17 Pro iOS 26 + iPhone 16 Pro iOS 18）
- Agent 不能批准自己的输出
- 设计配置变化需重新获得用户批准
- Git commit/push/PR 需要用户明确调用适配后的交付命令
