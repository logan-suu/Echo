# Echo UI 测试与 Artifact 规范

> **上游权威**：`Echo SwiftUI UI Agent 自动化 Bootstrap 与执行规范.md` §12、§13、§17、§18、§20

---

## 1. PR 与 Nightly 验证矩阵

| 维度 | PR 门禁 | Nightly 门禁 |
|------|---------|-------------|
| 契约 | 所有 schema 和引用校验 | 全量校验并检查孤立 ID |
| Build | 受影响 target clean build | 全量支持配置 build |
| State | canonical loaded + 变更相关 | loading/loaded/empty/error/modal |
| Journey | 受影响关键路径 smoke | 全量关键 journey |
| Device | 双固定 simulator：iPhone 17 Pro (iOS 26.5) + iPhone 16 Pro (iOS 18.x) | 小屏、标准屏、iPad |
| Theme | 变更相关 | light + dark |
| Dynamic Type | default + 1 accessibility size | default、中间档、最大支持档 |
| Locale | 默认 | long Latin、CJK、RTL 或伪本地化 |
| Contrast | 默认 | increased contrast |
| Motion | 变更相关 | Reduce Motion 开/关 |
| 可访问性 | 自动 audit、稳定 ID、关键标签 | audit、语义证据 + 人工记录 |
| 视觉 | 双设备 Live Sim Review（变更 surface） | 结构化检查，不保存媒体 |
| 安全 | artifact secret/PII 扫描 | 依赖、权限、telemetry 复核 |
| Masonry | 受影响 surface 的列数验证 + 回退检查 | 全部 Discovery surface 的 masonry 行为（启用/回退/列数/Dynamic Type 响应） |
| Surface Family | 受影响 surface 的 family 规则验证（禁止 Focus/Task 使用 masonry） | 全部 surface 的 family 规则全量验证 |

---

## 2. 测试策略

> **String Catalog 验证**（所有测试层级的通用前置条件）：
> - PR 门禁：所有 `zh-Hans` + `en-US` 键均有值，无缺失翻译
> - 运行时校验：`String(localized:)` 不应 fallback 到开发语言
> - 术语表覆盖率 ≥ 90%（基于 `UIAutomation/Fixtures/` 术语 Golden Dataset 校验）

### 2.1 契约测试
- 校验 schema 版本、必需字段、未知字段策略
- 确认 design profile 为 `echo-memory-canvas`、基础为 `apple-native`
- 校验 surface/state/action/journey/fixture/artifact 交叉引用
- 所有 fixture 可确定性解码

### 2.2 Adapter 测试
- 使用 Core 协议受控替身验证状态映射
- 验证异步取消、重复 action、错误映射、主线程发布
- 断言 adapter 不保存第二份领域真相

### 2.3 View 与组件测试
- 每个关键 state 有具名 Preview
- 验证 Dynamic Type、主题、长文本、空内容和可访问性语义
- Discovery 验证 masonry 启用条件、稳定排序与单列/List 回退
- Focus 与 Task 验证不存在 masonry
- Preview 是开发反馈，**不是**最终视觉审批渠道

### 2.4 Journey 测试
- XCUITest 从用户可观察入口执行
- 使用稳定 accessibility identifier，避免依赖坐标
- 关键断言覆盖行为结果和必要语义

### 2.5 视觉与可访问性测试
- **不调用 screenshot/screen-recording API**
- 不生成 reference/actual/diff，不维护图像 baseline
- 自动化使用 accessibility tree、元素存在性、点击区域、文本截断审计
- 自动 accessibility audit 不能替代 VoiceOver/Voice Control/Switch Control 专项检查
- 最终视觉判断只通过 **Live Simulator Review（双设备）**（bootstrap 规范 §11.4）：iPhone 17 Pro (iOS 26.5) 主审查 + iPhone 16 Pro (iOS 18.x) 最低版本审查

### 2.6 权限流程测试（Permission Flow Testing）
- 系统权限对话框拒绝路径覆盖（相册、麦克风、语音、通知等）
- 权限变更后的 UI 更新验证（从 Settings 返回后的状态刷新）
- XCUITest 使用 `addUIInterruptionMonitor` 处理系统弹窗
- 覆盖场景：首次拒绝 → 降级 UI / 空状态引导 / 设置引导入口

### 2.7 多分支旅程测试（Multi-branch Journey Testing）
- 每个 Journey 的分支路径（同意/拒绝、成功/失败、有数据/无数据）均需覆盖
- 禁止仅覆盖 Happy Path；分支覆盖度是 Journey 测试的必过门禁

### 2.8 跨 Surface 旅程测试（Cross-Surface Journey Testing）
- Home → Search → Detail → 返回的完整路径（跨 Discovery → Focus 边界）
- 通知点击 → 深层链接到具体记忆详情
- 验证 NavigationStack 返回栈完整性

---

## 3. Artifact 规范

每次运行必须生成 manifest，记录：
1. run ID、actor、时间、commit SHA 和 dirty flag
2. 契约版本/hash、fixture ID/hash、acceptance policy hash
3. Xcode、SDK、runtime、设备（双审查设备 17 Pro + 16 Pro 的 UDID/runtime）、架构、locale、timezone、主题
4. simulator 所有者（唯一 owner）、工具版本和配置摘要
5. surface/state/journey/test ID
6. build/test/audit/视觉结果
7. raw build log、结构化测试摘要、accessibility tree、`.xcresult`、crash report、manifest hash
8. `visualMediaCaptured`：布尔字段，必须为 `false`。**绝不**记录 screenshot、reference/actual/diff、video 路径

### Artifact 保留策略
| 产物 | 保留规则 |
|------|----------|
| manifest、结构化摘要、必要日志、accessibility tree | 持久化到 `UIAutomation/Artifacts/` |
| 通过的 `.xcresult` | 摘要写入 manifest 后可删除 |
| 失败的 `.xcresult` | 保留至 blocker 解决或任务完成 |
| CI artifact | 短期 retention，不提交到 Git |

---

## 4. 各阶段 Definition of Done

### Bootstrap DoD
- 只读 inventory + 保护路径清单
- 14 个现有命令兼容性清单
- Migration map（全部责任有归属）
- AGENTS.md 路由 merge
- `docs/ui/` 6 文件完整
- `UIAutomation/` 4 目录
- `.ui-automation/state.json` schema
- 适配后的 init/next 命令
- 新增 ui-bootstrap-build/status/retry 命令
- **String Catalog 完整性扫描**：所有 `zh-Hans` + `en-US` 键均有值，术语表覆盖率 ≥ 90%
- 每批结构变更后的 build 原始日志

### 试点 DoD
- 候选评分表与选择记录（8 维度评分 + 淘汰原因）
- 试点 surface/state/action/journey/fixture 契约（schema 校验通过）
- Fixture 完整性验证（覆盖契约声明的所有 state）
- SwiftUI View + 薄 adapter + 具名 Previews
- Adapter/行为/XCUITest/accessibility 证据
- Live Simulator Review 上下文（双设备 17 Pro iOS 26 + 16 Pro iOS 18，surfaceId/stateId/fixtureId 匹配）
- **UI 审查指南**（报告必需）：本次添加/修改页面清单（🆕/✏️ + 文件路径）+ 导航路径（如何点击到达）+ 未实现功能/临时效果（🔮 Phase 标记、fixture/stub 数据、String Catalog 未迁移）
- **不生成持久化视觉媒体**
- **权限拒绝路径测试通过**：试点 surface 关联的所有系统权限，拒绝路径均已通过 XCUITest

### 后续切片 DoD
- 受影响 readiness/hash 复检
- 一个边界清楚的 UI 切片
- 必要测试 + 受影响验证矩阵
- 两台 Simulator（17 Pro iOS 26 + 16 Pro iOS 18）导航到目标 state 并保持前台

---

## 5. Phase 3F 感知

> Phase 3F 的 UI 任务（3F.7–3F.10）沿用本节全部测试与 artifact 规则，以下为 3F 专项补充。phase ID 为字符串（含 `"3F"`），任务账本见 `docs/05-planning/task-status.json`。

- **测试套件**：每个 Phase 3F UI 任务配套 `EchoTests/Phase3F/` 单元/集成测试（如 `3F.7_UIToCoreIntegrationTests.swift`、`3F.8_AwakeningSystemAdaptersTests.swift`）与 `EchoUITests` 旅程套件；阶段集成测试为 `EchoTests/Phase3F/Phase3FIntegrationTests.swift`（`3F.11`）
- **PR 门禁不变**：受影响 target clean build、契约校验、双设备 Live Simulator Review（变更 surface）、String Catalog 双语键完整，均与 §1 一致
- **双设备 Live Simulator Review 要求**：Phase 3F UI 交付的视觉批准仍只通过双设备 Live Simulator Review——iPhone 17 Pro (iOS 26.5) 主审查 + iPhone 16 Pro (iOS 18.x) 最低版本审查，同一产物安装到两台设备；Agent 不能自行批准界面
- **无媒体 manifest**：每次运行的 manifest 必须记录 `visualMediaCaptured: false`（§3 第 8 项），Phase 3F 同样不创建、不持久化 screenshot、video、reference/actual/diff，不维护图像 baseline
- **生产集成专项**：Phase 3F 的测试强调「默认 App 无 `-ui-fixture` 参数」的生产路径证据（如 3F.7 默认 live adapter、3F.11 no-fixture E2E），fixtures 仅用于测试或 Preview，不作为生产完成证据
