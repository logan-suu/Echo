# ADR-003: DatabaseManager 集中式 SQL 执行 —— 不跨 Actor 传递 OpaquePointer

**状态**: 已接受
**日期**: 2026-07-04
**决策人**: AI Agent (Task 1.4)
**任务**: 1.4 - 集成 SQLite，创建 ExcludedAssets, Feedback, TaskProgress, PendingOperations 表

## 背景

Task 1.4 需要 4 个业务 Actor（ExcludedAssets / Feedback / Progress / PendingOps）各自操作 SQLite 表。最初的实现思路是让各 Actor 调用 `DatabaseManager.prepare(sql)` 获取 `OpaquePointer`（SQLite statement handle），然后在自己的 actor 上下文中执行 bind / step / finalize。

这与 VectorStoreActor 的模式类似——后者直接操作 ProximaKit 的 HNSWIndex 对象，不需要中间层。

## 问题

Swift 6 `-strict-concurrency=complete` 编译报错：

```
error: non-Sendable 'OpaquePointer'-typed result can not be
returned from actor-isolated instance method 'prepare' to
actor-isolated context
```

**根本原因**：`OpaquePointer` 是 C 指针类型，未遵循 `Sendable`。编译器无法证明指针从 `DatabaseManager` actor 传递到 `ExcludedAssetsActor` actor 后在并发环境中是安全的——尽管两个 actor 都是串行执行，但编译器不做运行时行为分析，只看类型系统。

### 为什么 VectorStoreActor 没这个问题？

ProximaKit 的 `HNSWIndex` 内部已通过 `@unchecked Sendable` 处理了类似问题（库作者承担了安全保证）。但 Echo 项目规约 **R-007 红线**明确禁止我们使用 `@unchecked Sendable`。

## 决策

**所有 SQLite statement 的生命周期（prepare → bind → step → finalize）完全在 `DatabaseManager` actor 内部完成。跨 Actor 传递仅使用 Sendable 值类型。**

具体 API 设计：

```swift
// ❌ 不这样做：返回非 Sendable 的 OpaquePointer
public func prepare(_ sql: String) throws -> OpaquePointer

// ✅ 这样做：内聚整个 SQL 执行，只出入 Sendable 值类型
public func executeWrite(sql: String, bindings: [DBBinding]) throws -> Int32
public func executeQuery(sql: String, bindings: [DBBinding]) throws -> [[String: DBValue]]
```

跨 Actor 边界的数据流：

```
┌─────────────────────┐    [DBBinding] (Sendable)    ┌─────────────────────┐
│  ExcludedAssetsActor │ ────────────────────────────▶│  DatabaseManager     │
│                     │◀─── [[String: DBValue]] ─────│                      │
│  (actor)            │        (Sendable)             │  (actor)             │
└─────────────────────┘                               │  OpaquePointer (私有)│
                                                      └─────────────────────┘
```

### 备选方案

| 方案 | 描述 | 结论 |
|---|---|---|
| `@unchecked Sendable` | 给 `OpaquePointer` 加 conformance | ❌ R-007 禁止 |
| `nonisolated(unsafe)` | 声明指针为 unsafe 以绕过检查 | ❌ R-007 禁止 |
| 每个 Actor 独立 SQLite 连接 | 各 Actor 自己 open 一个 db connection | ❌ 多连接写入 WAL 冲突 |
| 集中式 SQL API | 所有 SQL 在 DatabaseManager 内完成 | ✅ 采用 |
| 放弃 Actor，用串行队列 | 回到 GCD 串行队列模式 | ❌ AGENTS.md §4.2 要求 Actor 隔离 |

### 为什么不用锁？为什么不用串行队列？

AGENTS.md §2.1 明确要求「并发模型：Swift Concurrency (Actor, Task, AsyncStream)，**禁止 GCD/Combine**」。所以 GCD 串行队列不在选项中。

## 实现

由 `DatabaseManager` 提供两个核心方法，覆盖所有场景：

```swift
// 写入：INSERT / UPDATE / DELETE
func executeWrite(sql: String, bindings: [DBBinding]) throws -> Int32

// 查询：SELECT
func executeQuery(sql: String, bindings: [DBBinding]) throws -> [[String: DBValue]]
```

`OperationType` 通过 SQL 字符串本身区分（各 Actor 传入不同的 SQL），无需额外的方法重载或命令模式。

## 后果

### 正面
- 完全符合 Swift 6 strict-concurrency，编译零警告
- 不违反 R-007（零 `@unchecked Sendable` / `nonisolated(unsafe)`）
- SQL 生命周期管理内聚，无泄漏风险（`finalize` 由 defer 保证）
- 业务 Actor 只关心「什么数据」，不关心「怎么写 SQL」

### 负面
- `executeQuery` 返回 `[[String: DBValue]]`（字典数组），缺少编译期类型安全
- 绑定参数顺序必须与 SQL 中 `?` 占位符严格对齐（手写易出错——见 ProgressActor.updateProgress bug）
- 复杂查询结果的手工映射代码较冗长

### 已知坑

ProgressActor 的 `updateProgress` 方法曾在第一版实现中因绑参顺序与 SQL 占位符不匹配导致测试失败：

```swift
// ❌ 错误：bindings 顺序与 SQL 的 ? 不对齐
sql: "UPDATE ... SET lastProcessedIndex = ?, lastProcessedId = ?, updatedAt = ? WHERE taskId = ?"
bindings: [.int(index), .double(date), .text(taskId), .text(lastId)]
//          ?1=index ✓         ?2=date ✗(应该是 lastId)
```

已修复并覆盖测试。

## 参考

- `Echo/Core/Actors/DatabaseManager.swift` - 实现
- `Echo/Core/Actors/ProgressActor.swift:updateProgress` - 绑参 bug 案例
- [SE-0414: Region based Isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md)
- AGENTS.md R-007: 禁止 `@unchecked Sendable` / `nonisolated(unsafe)`
