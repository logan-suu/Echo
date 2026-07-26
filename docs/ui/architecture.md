# Echo UI 架构规范

> **上游权威**：`Echo SwiftUI UI Agent 自动化 Bootstrap 与执行规范.md` §5、§10、§15
> **不得覆盖**：Core Actor/Pipeline 实现、数据库 schema、模型集成

---

## 1. 六层架构

```
第一层：意图与人工批准层      → 维护 echo-memory-canvas，管理批准点
第二层：契约与场景层          → surface/state/action/journey/fixture 稳定 ID
第三层：编排与状态机层        → 推进状态、重试、唯一 simulator 所有者
第四层：UI 生成与适配层       → SwiftUI View、design token、薄 adapter
第五层：执行与验证层          → schema 校验、build、test、accessibility audit
第六层：证据/治理与安全层     → run manifest、审计链、批准记录
```

**边界**：
- 第一层**不能写生产代码**
- 第四层 adapter **不得保存第二份领域真相**
- 第六层 Agent **不能批准自己的输出**

---

## 2. 单向数据流

```
Core/Database → 只读输出 → @MainActor @Observable Adapter
→ UI State (typed) → SwiftUI View
→ User Action → Adapter Intent → 已有 Core 接口
```

**约束**：
- View 不直接写数据库
- Adapter 不保存独立领域模型
- Core 不依赖 SwiftUI

---

## 3. 组件边界

| 角色 | 职责 | 禁止 |
|------|------|------|
| **App Shell** | 根导航、依赖装配、应用级环境 | 实现领域规则 |
| **Surface View** | 一个 surface 的布局和交互组合 | 直接读取数据库 |
| **Component** | 可复用的视觉和语义行为 | 大量布尔开关组合 |
| **Adapter** | 主线程 UI 状态、异步生命周期、错误映射、intent 转发 | 保存第二份领域真相 |
| **Fixture Loader** | Preview/测试环境加载确定性数据 | 访问网络/生产数据库 |
| **Journey Driver** | 通过稳定 accessibility identifier 操作 UI | 调用 View 内部方法 |
| **Artifact Collector** | 收集执行证据 | 改变测试结果或 UI 状态 |

---

## 4. 受保护内容（只读）

1. Core 领域逻辑和公共语义
2. 数据模型、数据库 schema、迁移和持久化规则
3. `DatabaseManager` 的打开、事务和生命周期规则
4. 隐私声明、签名、entitlements、发布配置和 secrets
5. CI 安全门禁、SwiftLint 基线和 acceptance policy
6. Live Simulator 审批规则和 acceptance policy
7. 模型文件、模型下载或打包逻辑、ProximaKit 集成边界

---

## 5. 允许内容

1. SwiftUI Views 和纯表现组件
2. UI semantic tokens 和组件样式
3. `@MainActor @Observable` 薄适配器
4. Preview support 和确定性 fixtures
5. UI contract、UI 层测试和 artifact 收集配置

> 任何允许内容一旦需要改变受保护语义，就停止自动生成并升级为独立工程决策。
