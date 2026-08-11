# ADR-012: 唤醒系统边界

**状态**: 已接受（3F.8 已实现，2026-08-11 — 决策-1~7 全部落地）
**日期**: 2026-08-04
**决策人**: Privacy Engineering Lead（审批）+ iOS System Integration Lead（实现）

## 背景

基线中 AWK-001（地理围栏）仅有可调用编排与测试 stub，无 CLLocation 集成、权限投递、通知、持久化、默认调用；AWK-003（情绪唤醒）有 stub provider，HealthKit/实时情绪/投递/持久化缺失；AWK-002 的「精确每日 09:00 后台调度」iOS 无法保证（spec-invalid）；AWK-004（Widget/Live Activity）与 AWK-006（Siri/App Intents）为已批准产品延期（DEF-001/002）。

## 决策

1. **Best-effort 调度**：放弃精确时刻保证（ADR-006），采用 earliest-eligible/best-effort 窗口；启动后按最早可用机会投递。
2. **权限感知**：denied/accepted 位置与健康权限全状态处理；权限拒绝则对应来源不投递且不查询（US-SRC-010 的 denied HealthKit 来源不得被查询）。
3. **系统适配器真实化**：`CoreLocationProvider`、`HealthKitSystemProvider`、`LocalNotificationAdapter`、`NotificationResponseRouter` 接入生产；通知请求与响应路由分离。
4. **HealthKit 数据最小化**：只取授权范围内的最小化时序样本（不存原始健康值）；`HealthKitSystemProvider` 符合 3F.6 注入 provider 协议，向 health+memory 融合提供时间窗口内样本并保留来源身份（`.crossAppSearch`）。
5. **卡片持久化/去重**：`AwakeningCardRepositoryActor` 持久化卡片，重启去重；情感 fallback/debounce；日期窗口处理。
6. **AWK-004/006 保持 DEF-001/DEF-002**：Widget/Live Activity 与 Siri/App Intents 为 v1 外已批准延期，不悄悄并入其他任务。
7. **通知边界**：通知内容最小化；隐私批准签字确认 HealthKit 最小化与通知边界。

## 备选方案

| 方案 | 描述 | 结论 |
|------|------|------|
| **A（采纳）** | 权限感知 best-effort + 真实系统适配器 + 最小化 HealthKit | ✅ 公开 API 内可落地，满足 R-001/R-006 |
| B | 精确后台时刻保证 | ❌ iOS 无法保证，spec-invalid |
| C | 缓存完整健康数据供情绪推断 | ❌ 违反数据最小化 |

## 后果

### 正面

- 唤醒投递（围栏/情绪/周年）、通知请求与响应路由、卡片持久化/去重全部可测。
- US-SRC-010 的 live HealthKit 集成（授权→时序样本→3F.6 融合）证据路径确定。
- denied HealthKit 来源不查询成为显式 E2E 断言（3F.11）。

### 负面

- 用户感知的唤醒时刻不可精确预测（best-effort）。
- 情绪推断仅基于最小化样本，精度受限于数据边界。
- Widget/Siri 能力推迟到 v1 后。

## 参考

- `docs/01-spec/用户故事与验收标准规格书.md` US-AWK-001/002/003/005、US-SRC-010
- AGENTS.md R-001、§8.3（后台任务面板契约）
- `docs/ui/echo-readiness.md`、`docs/ui/testing-and-artifacts.md`
- `docs/05-planning/phase3f-execution-plan.md` §4.6.8（3F.8 文档合同）
- `docs/05-planning/deferred-items.json` DEF-001（AWK-004）、DEF-002（AWK-006）
