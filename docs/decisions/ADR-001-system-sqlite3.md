# ADR-001: 选择系统 SQLite3 而非 GRDB.swift

**状态**: 已接受
**日期**: 2026-07-04
**决策人**: AI Agent (Task 1.4)
**任务**: 1.4 - 集成 SQLite，创建 ExcludedAssets, Feedback, TaskProgress, PendingOperations 表

## 背景

Echo v4.6 规格书及技术选型文档中，关系数据库写的是「SQLite (通过 GRDB 或原生)」，未明确最终选择。Task 1.4 需要在 Phase 1 完成四张核心业务表的创建和 Actor 封装。

## 决策

**选择系统 SQLite3（零外部依赖），通过自定义 `DatabaseManager` actor 集中管理所有 SQL 操作。**

不使用 GRDB.swift。

## 备选方案

| 方案 | 优点 | 缺点 | 结论 |
|---|---|---|---|
| **GRDB.swift** | 类型安全、Swift Concurrency 原生支持、成熟的 ORM 层 | 额外的 SPM 依赖（~2MB 二进制）、学习曲线、可能与 Swift 6 strict-concurrency 有磨合问题 | ❌ 不选 |
| **系统 SQLite3** | iOS 系统自带、零外部依赖、WAL 模式足够、Actor 天然串行隔离 | 需手写 SQL 绑定/映射代码、无 ORM 层 | ✅ 选择 |

## 实现要点

- `DatabaseManager` actor 封装 `OpaquePointer`（db handle），不跨 Actor 传递语句句柄
- `executeWrite(sql:bindings:)` + `executeQuery(sql:bindings:)` 两个方法覆盖所有 CRUD
- `DBBinding` / `DBValue` 枚举作为跨 Actor 传递的 Sendable 值类型
- 4 个业务 Actor（ExcludedAssets/Feedback/Progress/PendingOps）通过 `DatabaseManager.shared` 间接访问数据库

## 后果

### 正面
- 零外部依赖，符合 Echo「本地优先」原则
- iOS 系统 SQLite3 经过 Apple 签名验证，安全可靠
- 编译时间更短（少一个 SPM 包）
- 完全控制 SQL 执行路径，避免 ORM 黑盒

### 负面
- 手写 SQL 绑定/映射代码，代码量略多
- 缺乏编译期类型安全的查询构建
- 表结构变更时需手动同步 SQL 字符串

## 参考

- `docs/02-architecture/技术选型文档.md` §4 - 端侧向量数据库选型
- `docs/02-architecture/架构设计文档.md` §5.1 - 存储层次
- `Echo/Core/Actors/DatabaseManager.swift` - 实现
- [SQLite WAL Mode](https://www.sqlite.org/wal.html)
