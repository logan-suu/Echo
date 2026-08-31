# UIAutomation/Contracts

本目录保存 UI 自动化的 schema 定义和实例契约。

## 目录约定

- `schemas/` — JSON Schema 定义（DesignProfile、Surface、State、Action、Journey、Fixture、Artifact、Approval）
- `instances/` — 具体 surface 的契约实例（如 `home-surface.json`）

## 核心实体

| 实体 | 作用 | 必需字段 |
|------|------|---------|
| DesignProfile | 全局视觉与行为约束 | `profileId`, `version`, `baseProfile`, `approvalRecord`, `surfaceFamilyRules` |
| Surface | 可独立呈现和验证的 UI 边界 | `surfaceId`, `surfaceFamily`, `responsibility`, `inputs`, `observableOutputs` |
| State | Surface 的确定状态 | `stateId`, `dataConditions`, `allowedActions`, `expectedSemantics` |
| Action | 用户或系统事件 | `actionId`, `source`, `targetIntent`, `expectedOutcome` |
| Journey | 跨 surface 的行为路径 | `journeyId`, `steps`, `preconditionFixtures`, `assertions` |
| Fixture | 确定性输入 | `fixtureId`, `schemaVersion`, `locale`, `theme`, `payload` |
| Component | 可复用表现单元 | `componentId`, `variants`, `slots`, `accessibilityContract` |
| Artifact | 可追溯证据 | `runId`, `testId`, `sourceHash`, `path`, `contentHash` |
| Approval | 人工决定 | `approvalId`, `stage`, `actor`, `decision`, `sourceRun` |

## 契约规则

1. ID 在 brief、fixture、Preview、测试和 artifact 中保持一致
2. Fixture 必须确定、离线、可复现，控制时钟/UUID/随机数/动画
3. View 只依赖 typed state 和 action closure
4. Adapter 映射必须可单元测试
5. Journey 断言可观察结果，不断言 Core 私有实现
6. Schema 变更使用显式版本
7. 每个 Surface 必须声明 `designProfileId: echo-memory-canvas`；Focus/Task 的 no-masonry 只改变布局，不豁免全 App 视觉一致性

## 交叉引用

- 设计配置：`docs/ui/echo-memory-canvas-style.md`
- 测试策略：`docs/ui/testing-and-artifacts.md`
- 架构约束：`docs/ui/architecture.md`
