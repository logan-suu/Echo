# ADR-018: 渐进式系统权限编排与诚实授权状态

**状态**: 已接受  
**日期**: 2026-09-04  
**决策人**: Codex（依据用户指示执行 4.0f 规格合理性评审）

## 背景

Task 4.0f 原方向要求 PIPL 先行、照片显式连接、通知/位置/HealthKit 按用途请求，但仍缺少可直接实现和验证的系统语义。现有生产代码存在四个具体问题：

1. `OnboardingViewModel.acceptPrivacy()` 先推进权限页，再异步持久化同意，用户可能在同意落库前触发 PhotoKit。
2. `CoreLocationProvider.requestWhenInUseAuthorization()` 调用系统 API 后立即读取旧状态，没有等待 delegate 回调；同时只有 When In Use 路径，无法明确满足 App 被终止后的区域唤醒。
3. `RealHealthStore.currentAuthorizationState()` 使用 `authorizationStatus(for:)` 判断 HRV 读取权限，但该 API 表示 share/write 授权。HealthKit 为保护隐私不披露 read denied，授权请求 completion success 也只表示请求流程完成。
4. Awakening UI 把通知授权视为三个唤醒偏好的总门禁。这样会把触发源授权、App 内卡片生成和系统通知投递混成一个状态，并可能让一个开关隐式引发多个系统 prompt。

Apple 的平台契约要求权限请求发生在用途明确的用户动作之后；PhotoKit 支持 limited access；Core Location 的 When In Use 与 Always 能力不同且授权结果异步交付；UserNotifications 应在请求后读取当前 settings；HealthKit 不披露读取授权结果。

## 决策

1. **持久化同意硬门禁**：PIPL 同意先写入 `ConsentStoreActor`。只有写入成功才进入 PhotoKit 连接步骤；失败停留在 consent error 并提供显式重试。任何受保护请求都不得与持久化并行抢跑。
2. **PhotoKit 单一触发**：Onboarding 只展示 `Connect Photos` 与 `Not Now`。前者请求 `.readWrite`，后者零系统调用并直接继续。limited/full 按实际范围工作；denied/restricted 后才显示设置恢复。
3. **通知独立投递 opt-in**：通知按钮只请求通知。geofence/emotion/anniversary 开关不隐式请求通知，也不因通知 denied 被统一关闭；未授权通知时仍可生成和展示 App 内唤醒卡。
4. **定位分两阶段**：启用 geofence 时首次只请求 When In Use，并等待 delegate 回调。若用户选择终止态后台区域唤醒，在解释能力差异后由第二个明确动作请求 Always。任何页面加载都只读状态。
5. **HealthKit 诚实状态**：仅请求 HRV read type。领域状态拆为 `requestState = notRequested | requestCompleted | unsupported` 和 `dataState = samplesAvailable | noReadableSamples | unavailable`。禁止把 `authorizationStatus(for:)` 或 request completion success 映射成 read granted/denied。请求处理失败不持久化 `requestCompleted` 并显示 L2 可重试错误；设置页样本查询失败显示 L2，唤醒运行时查询失败按本轮无可用样本进入既有 7 天查询字符串与感受回退。
6. **异步完成语义**：permission adapter 的 async 方法必须等待系统回调，或在 completion 后复读最终系统快照，再返回 Sendable 值类型。重复进入页面、重启和读取状态不触发请求。
7. **偏好持久化**：新增 `AwakeningPreferenceActor`，通过 `DatabaseManager` 管辖的 SQLite 表保存三个唤醒偏好、通知投递意图与 HealthKit request lifecycle。系统 notification/location/HealthKit 授权快照不入库。重启恢复偏好只读数据库与系统快照，不调用 request API。
8. **验证边界**：单元/集成测试使用调用 spy 与可控 delegate 验证顺序、次数、scope、持久化和回调完成；XCUITest 只验证可由 Simulator 稳定控制的真实系统 prompt 与返回状态。不得用 fixture 成功态证明生产授权。

## 备选方案

### 方案 A：保留统一权限向导

实现简单，但在首次启动连续请求四类敏感权限，缺乏用途上下文，也与当前产品规格冲突。

### 方案 B：每个唤醒开关自动请求自身权限与通知

比统一向导更有上下文，但一次动作仍可能连续出现两个 prompt，且把通知投递与触发源能力耦合。

### 方案 C：完全依赖系统设置恢复

避免应用内 prompt 编排，但首次启用体验断裂，也无法在 notDetermined 状态提供就地授权。

## 后果

- Onboarding 状态机需要新增 consent persisting/error 状态，并移除通知、位置、HealthKit 权限步骤。
- Awakening 偏好需要生产持久化边界；通知、触发偏好和权限快照成为正交状态。
- `LocationProviding` 需要可等待的 When In Use 与 Always 请求接口。
- `HealthStoreServing` 需要移除伪 read authorization，并以 request/data availability 返回诚实状态。
- 需要新增由 `DatabaseManager` 管辖的 `AwakeningPreferenceActor`/SQLite 表；它不缓存系统授权结果。
- UI Contract、测试与可访问文案需要覆盖分阶段定位、独立通知投递和 HealthKit 无可读样本回退。

## 参考

- `docs/01-spec/用户故事与验收标准规格书.md` US-SRC-001、US-PRV-008、US-AWK-001~003
- `docs/02-architecture/架构设计文档.md` §2.3.1
- `docs/02-architecture/数据流全链路技术说明文档.md` §1.1
- Apple Developer Documentation: Delivering an Enhanced Privacy Experience in Your Photos App
- Apple Developer Documentation: Requesting authorization to use location services
- Apple Developer Documentation: Asking permission to use notifications
- Apple Developer Documentation: Authorizing access to health data
