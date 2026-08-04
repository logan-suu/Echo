# ADR-007: 生产组合、首次启动与同意/审计存储契约

**状态**: 已接受
**日期**: 2026-08-04
**决策人**: Privacy Engineering Lead（审批）+ iOS Platform Lead（实现）

## 背景

基线中 App 启动既不加载 deny-by-default 的生产策略，也不创建应用自有的 composition root；`AppRootView` 构造默认 ViewModel，`EchoApp/AppDelegate` 无生产接线。同意 UI 仅为 fixture 状态过渡，撤回/数据清除流未接入。审计行在 Core 测试中存在，但 Settings 审计查看器未接实时数据，且审计契约（必需字段、hash-only、30 天清理、`NSFileProtectionComplete`）无 schema/存储迁移证据。

## 决策

3F.1 落地以下契约（ADR 批准的生产签名）：

1. **应用自有 composition root**：`Echo/App/AppComposition.swift` 持有唯一依赖图（DatabaseManager、PrivacyActor、Pipeline、generation 路由、card repository、creation runtime、export boundary）。默认 App 从 composition root 构造；fixtures 仅限测试/预览。
2. **Deny-by-default 同意**：新装用户未同意前拒绝任何业务数据访问（PrivacyCheckpoint `.denied` 立即终止）。同意版本与时间戳持久化到 `ConsentState`。
3. **事务性撤回/清除**：撤回同意 = 事务性数据清除（向量、索引、缓存、元数据、审计日志、translationCache），失败进入 blocked 状态并写审计。清除边界与 `PurgeBoundary` 显式定义。
4. **AuditLog schema/存储迁移**：每个审计行必填 `eventType`、`timestamp`、`traceID`、`policyVersion`、`success`；内容字段仅存 hash；保留期 30 天确定性清理；SQLite/审计文件使用 `NSFileProtectionComplete`。
5. **显式不可用启动状态**：`model-unavailable`、`route-unavailable`、`index-unavailable` 三种启动状态由 3F.1 暴露，供 3F.2/3F.3/3F.4/3F.7/3F.11 消费；完整启动就绪仅由 3F.11 证明。
6. **无 CloudKit**：`echo-memory-canvas-style.md` 移除/调和任何暗示 iCloud 同步状态的 UI，生产无 CloudKit 依赖。

## 备选方案

| 方案 | 描述 | 结论 |
|------|------|------|
| **A（采纳）** | Composition root + deny-by-default + 事务清除 + 审计存储迁移 | ✅ 满足 R-001/R-002/R-006/D-001~D-005，证据可定位 |
| B | 维持 AppRootView 内联构造 + UserDefaults 同意标志 | ❌ 无审计、无事务清除、fixture 当生产 |
| C | 同意后置（先展示内容再请求同意） | ❌ 违反 deny-by-default 与隐私审计要求 |

## 后果

### 正面

- 首次启动状态机、同意持久化、撤回/清除与审计契约全部在生产路径可测。
- 关闭 DEF-45-002（consent 持久化 + 撤回流）的证据路径确定。
- 审计 schema 迁移可由迁移测试证明必填字段与保护属性。

### 负面

- 3F.1 需要迁移 AuditLog schema/存储（破坏性变更，需迁移表）。
- 未同意状态下的启动体验更严格（无可浏览内容）。
- 撤回=全量清除是重操作，需 Toast/进度反馈。

## 参考

- `docs/01-spec/用户故事与验收标准规格书.md` US-PRV-001/004/005/006/008、US-SRC-001、US-RES-004
- AGENTS.md R-001/R-005/R-006、D-001~D-005、§7 审计日志契约
- `docs/02-architecture/架构设计文档.md`、`docs/02-architecture/数据流全链路技术说明文档.md`
- `docs/05-planning/phase3f-execution-plan.md` §4.6.1（3F.1 文档合同）
