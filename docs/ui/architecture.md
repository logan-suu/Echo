# Echo UI 架构规范

> **上游权威**：`Echo SwiftUI UI Agent 自动化 Bootstrap 与执行规范.md` §5、§10、§15
> **不得覆盖**：Core Actor/Pipeline 实现、数据库 schema、模型集成

---

## 1. 六层架构

```
第一层：意图与人工批准层      → 维护 echo-memory-canvas，管理批准点
第二层：契约与场景层          → surface/state/action/journey/fixture 稳定 ID
第三层：编排与状态机层        → 推进状态、重试、唯一 simulator 所有者（双审查设备）
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

### 2.1 完整路径
```
Core/Actor → 只读值类型输出 → @MainActor @Observable Adapter
→ UI State (typed enum) → SwiftUI View
→ User Action → Adapter Intent 方法 → Core Pipeline 接口
→ 结果回调 → Adapter 状态更新 → View 重新渲染
```

### 2.2 错误传播路径
```
Core throws (L1-L4) → Adapter do/catch → 映射规则：
  L1 → 静默重试 3 次（1s/2s/4s），失败升级 L2
  L2 → state = .error(L2)，View 显示 Toast + 重试按钮
  L3 → state = .error(L3)，View 显示全屏引导页
  L4 → state = .error(L4)，View 显示 Banner + 冲突入口
```

### 2.3 加载态路径
```
User Action → Adapter state = .loading → View ProgressView/skeleton
→ await Core → 成功: .completed / 失败: .error
```

### 2.4 取消传播路径
```
View .onDisappear → Adapter task?.cancel()
→ Core Task.checkCancellation() → CancellationError
→ Adapter state = .cancelled
```

### 2.5 约束
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

### 4.1 受保护路径

| 路径 | 内容 | 原因 |
|------|------|------|
| `Echo/EchoApp.swift` | `@main` 入口点 | App 生命周期 |
| `Echo/App/` | AppDelegate（BGTask） | 系统回调 |
| `Echo/Core/Actors/` | 所有 Actor | 可变状态封装 |
| `Echo/Core/Pipelines/` | 所有 Pipeline | 业务规则 |
| `Echo/Core/Models/` | 领域模型 | 数据结构契约 |
| `Echo/Core/Services/` | 向量存储、模型加载、Embedder、ASR | 持久化、推理封装 |
| `Echo/Resources/Models/` | Core ML 模型包 | 不可损毁 |

### 4.2 抽象受保护内容

1. Core 领域逻辑和公共语义（所有 `Echo/Core/` 子目录）
2. 数据模型、数据库 schema、迁移和持久化规则
3. `DatabaseManager` 的打开、事务和生命周期规则
4. 隐私声明、签名、entitlements、发布配置和 secrets
5. CI 安全门禁、SwiftLint 基线和 acceptance policy
6. Live Simulator 审批规则和 acceptance policy
7. 模型文件、模型下载或打包逻辑、ProximaKit 集成边界

> UI 层**不得**：导入 Core Actor 可变方法以外的内部符号、直接访问 SQLite/ProximaKit、修改 Core 目录下任何文件。

---

## 5. 允许内容

1. SwiftUI Views 和纯表现组件
2. UI semantic tokens 和组件样式
3. `@MainActor @Observable` 薄适配器
4. Preview support 和确定性 fixtures
5. UI contract、UI 层测试和 artifact 收集配置

> 任何允许内容一旦需要改变受保护语义，就停止自动生成并升级为独立工程决策。

---

## 6. ViewModel 契约

> **上游权威**：AGENTS.md §8.1（ViewModel 强制规范）

### 6.1 标注要求
- 所有 ViewModel **必须标注 `@MainActor`**
- **必须使用 `@Observable` 宏**，禁止手动 `objectWillChange.send()`

### 6.2 状态枚举
```swift
enum State {
  case idle          // 初始
  case loading       // 加载中
  case completed(T)  // 成功
  case error(ErrorLevel)  // L1-L4 错误
  case cancelled     // 取消
}
```
状态流转：`idle→loading→completed/error/cancelled`，禁止 `idle→completed` 直接跳转。

### 6.3 action 方法规则
- 每个 action 方法**第一行必须设置 `state = .loading`**
- 副作用仅通过 action 方法触发，禁止在 computed property 中触发

### 6.4 值类型持有
- ViewModel 只能持有值类型副本（Sendable）
- 不可变 Actor 引用（`let`）是合法的
- 禁止持有数据库引用

### 6.5 进度订阅
- 使用 `Task` 或 `.task` 修饰符，禁止 `Task.detached`

---

## 7. 适配器契约

### 7.1 职责
| 职责 | 说明 |
|------|------|
| 线程隔离 | Core Actor → `@MainActor` 状态 |
| 状态映射 | Core 值类型 → UI State |
| 错误映射 | L1-L4 → Toast/Banner/全屏/冲突 |
| Intent 转发 | User Action → Core `await` 调用 |
| 生命周期 | 管理 Task，View 消失时 cancel |

### 7.2 错误映射模式
| Core | UI | 用户操作 |
|------|----|---------|
| L1 瞬态 | 静默重试，不显示 UI | 无 |
| L2 可恢复 | Toast + 重试按钮 | 点击重试 |
| L3 阻断 | 全屏引导页 | 按引导操作 |
| L4 数据冲突 | Banner + 冲突入口 | 手动解决 |

### 7.3 禁止清单
- ❌ 保存第二份领域真相
- ❌ 复制业务规则
- ❌ 持有数据库引用
- ❌ 在 computed property 中触发 Core 调用
- ❌ `Task.detached`

---

## 8. Surface Family 架构映射

> **上游权威**：`echo-memory-canvas-style.md` §3

| 属性 | Discovery | Focus | Task |
|------|-----------|-------|------|
| 适用场景 | Home/Search | Memory detail/translation | Settings/errors/permissions |
| 布局 | masonry（条件）| 单列+metadata | Form/List/Sheet/Alert |
| Masonry | ✅ 条件触发 | ❌ 禁止 | ❌ 禁止 |
| 参考章节 | style §3.1, §5, §6 | style §3.2, §7.1 | style §3.3, §7.2 |

每个 Surface View 头部必须声明 family 归属。交叉引用：`echo-memory-canvas-style.md`。

---

## 9. Phase 3F 感知

> `docs/05-planning/task-status.json` 的 phase 为字符串（`phase_order = ["1","2","3","3F","4","5"]`，`current_phase = "3F"`）。Phase 3F 的 UI 任务在**同一 `echo-memory-canvas` 设计 profile 与本文档全部规则**下继续执行，六层架构、单向数据流、组件边界、受保护/允许内容等既有规则全部保留。

- **Phase 3F UI 任务**：3F.7（UI→Core 全域接线）、3F.8（Awakening 与 system adapters）、3F.9（Apple Translation 与 grounded creation）、3F.10（i18n、accessibility 与 production errors）按 canonical plan §7 + §6.2.2 协议执行（任务清单 → §6.2.2 单脚本交付 → PR → 人类合并；checklist 含双设备 Live Sim Review 与 §4.6.7–4.6.10 UIAutomation 契约），**不经 `$ui-bootstrap-build-echo`**（该 skill 为 Phase 3 专用，校验 `current_phase == "3"` 精确匹配；见 `README.md`、`command-compatibility.md`）
- **UI-adjacent Core 接线的受控例外**：§4 的「受保护内容（只读）」保持 Core 只读基线；`3F.0` 人类合并后，standing authority 允许在**任务穷尽式 Files 清单内**修改 UI-adjacent Core 接线文件（如 3F.7 的默认 live adapter 接线），超出任务明示范围仍须停止升级为独立决策
- **测试**：每个 Phase 3F UI 任务的单元/集成测试位于 `EchoTests/Phase3F/`（如 `3F.7_UIToCoreIntegrationTests.swift`），UI 旅程测试在 `EchoUITests` 套件；阶段集成测试为 `EchoTests/Phase3F/Phase3FIntegrationTests.swift`
- **验证**：Phase 3F UI 交付仍需**双设备 Live Simulator Review**（iPhone 17 Pro iOS 26.5 主审查 + iPhone 16 Pro iOS 18.x 最低版本审查），并生成**无媒体 manifest**（`visualMediaCaptured: false`），不创建或持久化 screenshot/video
