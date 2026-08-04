# ADR-011: 任务进度与降级恢复边界

**状态**: 已接受
**日期**: 2026-08-04
**决策人**: Architecture Lead（审批）+ Ingestion Lead（实现）

## 背景

基线中 `ProgressActor` 有隔离持久化，但默认 App 用 fixtures、无 TaskQueue/stream 集成（SYS-001 Partial）；长任务（索引构建、数据同步）无串行队列、无取消/恢复、无进度持久化；L1-L4 错误矩阵在 UI 层不完整（DEF-39-1：L1/L3/L4 未映射）；feedback L2 静默降级未写 PendingOperations（DEF-37-001）；覆盖门禁阈值被临时下调（DEF-38-003）。

## 决策

1. **TaskQueueActor 串行契约**：索引构建与数据同步必须串行入队（`TaskQueueActor`）；入队所有写入 VectorStoreActor 的长任务；任务实现 `Cancellable`；支持暂停（挂起不释放资源）/取消（保存进度）。
2. **ProgressActor 持久化**：进度持久化到 SQLite `TaskProgress`（taskId、taskType、lastProcessedIndex、totalCount、resumeData）；原子写入；任务完成/失败后删除记录；取消保留进度，重启弹窗询问「继续/重新开始」。
3. **L1-L4 错误矩阵落地**：L1 瞬态指数退避重试 3 次（1s/2s/4s）失败升级 L2；L2 可恢复写 `PendingOperations` 且**仅手动重试**（无自动重放）；L3 阻断停止功能引导系统设置修复；L4 冲突标记 + 手动合并 UI。
4. **降级来源真实化**：低电量与 serious/critical thermal 状态改变实际运行时行为（任务暂停/降级提示/恢复状态转移），非 fixture 显示。
5. **覆盖门禁**：3F.11 修复 `coverage_gate.py` 并恢复 AGENTS.md §9.3 阈值（全局 line coverage ≥95%）——关闭 DEF-38-003 需 3F.0 人类批准覆盖率路径 + 3F.11 报告。

## 备选方案

| 方案 | 描述 | 结论 |
|------|------|------|
| **A（采纳）** | TaskQueue 串行 + ProgressActor 持久化 + L1-L4 真实化 | ✅ 满足 TaskQueue/断点续传/错误分级契约，证据可定位 |
| B | 并行任务 + 内存进度 | ❌ 数据竞争、重启丢失、无法恢复 |
| C | L2 自动重放 + 静默降级 | ❌ 违反「仅手动重试」契约，掩盖真实故障 |

## 后果

### 正面

- 长任务取消/重启恢复、进度持久化、L1-L4 逐级证据全部可测。
- feedback L2 写 PendingOperations 且手动重试（关闭 DEF-37-001）。
- 降级横幅由真实 power/thermal/model 源驱动（3F.10）。

### 负面

- 串行队列使索引与同步互斥，长任务期间并发操作需排队。
- 取消/恢复状态机复杂度上升。
- 覆盖门禁恢复 95% 需在 3F.11 完成测试扩充。

## 参考

- `docs/01-spec/用户故事与验收标准规格书.md` US-SYS-001、US-RES-001~004
- AGENTS.md §4.3（TaskQueue 契约）、§4.4（L1-L4）、§4.5（断点续传）、§9.3（CI 门禁）
- `docs/03-implementation/开发避坑与关键注意点手册.md`
- `docs/05-planning/phase3f-execution-plan.md` §4.6.5（3F.5 文档合同）、§4.6.10（3F.10 文档合同）
- `docs/05-planning/deferred-items.json` DEF-37-001、DEF-38-003、DEF-39-1
