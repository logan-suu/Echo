# ADR-002: MainActor 隔离下的 Sendable 模型属性标注策略

**状态**: 已接受
**日期**: 2026-07-04
**决策人**: AI Agent (Task 1.4)
**任务**: 1.4 - 集成 SQLite，创建 ExcludedAssets, Feedback, TaskProgress, PendingOperations 表

## 背景

Echo 项目配置了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（在 project.pbxproj 中），这意味着所有顶级声明（包括 `struct`、`enum` 的属性、初始化方法、计算属性）默认都隔离到 `@MainActor`。

Task 1.4 需要定义多个 `Sendable` 数据模型（`FeedbackEntry`、`TaskProgress`、`PendingOperation` 等），这些模型需要在非 MainActor 的 `actor` 上下文中创建和传递。

## 决策

**对纯数据 struct 的所有 stored/computed properties 和 init 显式标注 `nonisolated`，并暂时移除 `Equatable` 遵循。**

## 问题表现

```swift
// 没有 nonisolated 标注时：
public struct TaskProgress: Sendable, Codable, Equatable {
    public let taskId: String          // ❌ 自动 @MainActor
    public let lastProcessedIndex: Int // ❌ 自动 @MainActor
}

// 在 actor 内部访问：
let index = progress.lastProcessedIndex // ❌ 需要 await（跨 Actor）
```

## 解决方案

### 可行方案对比

| 方案 | 描述 | 结论 |
|---|---|---|
| 标注 `nonisolated` | 每个属性和 init 加 `nonisolated` | ✅ 采用 |
| 移除 `SWIFT_DEFAULT_ACTOR_ISOLATION` | 在 project.pbxproj 中删除全局设置 | ❌ 影响范围太大，UI 层需要 MainActor |
| `@unchecked Sendable` | 绕过 Sendable 检查 | ❌ AGENTS.md R-007 禁止 |
| 文件级 `@preconcurrency import` | 降低并发检查严格度 | ❌ 不够精确，影响整个文件 |

### 最终实现

```swift
public struct TaskProgress: Sendable, Codable { // 移除 Equatable
    public nonisolated let taskId: String
    public nonisolated var lastProcessedIndex: Int
    // ...所有属性均 nonisolated

    public nonisolated init(...) { ... }
}
```

### Equatable 移除原因

Swift 6 为 struct 自动合成的 `==` 函数继承了全局 Actor 隔离（`@MainActor`），导致在 actor 上下文中无法直接比较两个 struct 实例。目前测试通过比较单个属性来验证，如需恢复 `Equatable`，需手写 `nonisolated static func ==`。

## 后果

### 正面
- 数据模型可在任意 Actor 上下文中自由传递，无需 `await`
- 不违反 R-007（零 `@unchecked Sendable`）
- 不修改全局项目设置

### 负面
- 每个属性/init 需手写 `nonisolated`（代码冗长）
- 失去 `Equatable` 自动合成（需手写 `==` 或按属性比较）
- 未来新增模型属性时易遗漏 `nonisolated`（需 code review 把关）

## 参考

- `docs/05-planning/task-status.json` → Task 1.4
- `Echo/Core/Models/ErrorEnums.swift` - 实现
- [SE-0414: Region based Isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md)
- `Echo.xcodeproj/project.pbxproj` → `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
