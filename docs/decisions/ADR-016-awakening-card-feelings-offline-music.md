# ADR-016: 交互式唤醒卡的感受关系与全离线音乐边界

**状态**: 已接受
**日期**: 2026-09-02
**决策人**: Codex 规格复审（根据人类产品负责人“先评审合理性，不合理先修文档”的明示指令）

## 背景

US-AWK-005 的方向合理，但原文无法直接形成一致且可测的生产合同：

1. 原 AC 一方面说“Apple Music 已授权则推荐”，另一方面要求完全离线。Apple 官方将 MusicKit catalog/personal recommendation 定义为 Apple Music API Web Service；权限状态也不等于内容存在、订阅能力或本地可播。这与 Echo R-001/R-005 “数据不离开设备/运行时不下载”冲突。
2. 原 AC 同时要求“限流时不显示音乐建议”与“降级到随包离线库”，降级行为自相矛盾。
3. “`userFeelings` 数组”未区分领域投影与物理存储，可能导致将可编辑子实体嵌入 canonical JSON，使事务、级联删除和不可搜索边界变得模糊。
4. `record` 的审计时机、`feelingAssociatedToSource` 类型、“下一张”顺序以及 card → Focus 与后续 source anchor 的任务边界均不可测。

## 决策

### D-1 随包离线曲库是默认且始终可用的建议源

- 离线曲库 manifest 声明 `schemaVersion`、`supportedYears`、每个受支持年份 20 条元数据、通用 fallback 分组以及 provenance/license，仅随 App 版本更新。Bundle 不包含音频、封面、歌词或网络 URL。
- 推荐在端侧使用已有的时间、地点、标签等派生元数据完成；同分组内由 memoryId digest 稳定选择，无精确年份时使用 fallback，不需要媒体库权限。
- Bundle 条目是“建议”，不声称用户拥有或可离线播放该曲目。

### D-2 设备音乐匹配仅是显式 opt-in 的本地增强

- 只有用户在唤醒卡中显式选择“匹配此设备音乐”，才请求 `MPMediaLibrary` 权限。
- 授权后只通过 `MPMediaQuery` 读取设备媒体库，并排除 `isCloudItem == true` 的曲目；匹配过程不上传记忆、查询、感受或派生标签。
- 禁止 `MusicCatalogSearchRequest`、`MusicCatalogResourceRequest`、personal recommendations、recently played、`MusicDataRequest` 及其他 MusicKit Web Service。
- denied/restricted/empty/query failure 都回退随包库，不形成网络重试或 L2 云服务待办。只有被系统证明本地可播的设备曲目才可显示播放动作。

### D-3 `userFeelings` 是领域集合，`MemoryFeeling` 是关系存储

- 领域 API 向 UI 提供 `userFeelings: [UserFeeling]`。
- SQLite 使用独立 `MemoryFeeling` 表，每行至少包含 `feelingId, memoryId, text, createdAt, updatedAt`，以 `memoryId` 关联 canonical memory。
- 新增/编辑/删除由专用 Actor 经 DatabaseManager 事务处理；原 memory 删除时感受同事务级联删除，不写 `ExcludedAssets`。
- 感受不创建 Memory/Representation，不进入 FTS、向量、SearchPipeline 或翻译缓存；只允许本地个性化/情绪分析读取。

### D-4 动作与审计语义必须可观察

- `next` 按当前唤醒结果的稳定顺序前进，无后继项时禁用；不修改上游 Search/Awakening 排序。
- `record` 仅在感受事务提交成功后记录；打开、取消或保存失败均不记成功 `record`。
- `jump` 仅在稳定 memory/source 路由已执行时记录。
- `AuditEvent` 必须新增 `.cardInteraction`；事件只含 `action`、`cardIdDigest`、`memoryIdDigest` 和布尔 `feelingAssociatedToSource`。仅成功且仍关联原 memory 的 `record` 为 true；不记感受原文或媒体库内容。

### D-5 任务边界

- `4.0d` 消费 `4.0a` 的稳定 Discovery card 和 `4.0b` 的 Focus 路由，负责唤醒卡交互、感受关系、离线音乐与 card → Focus intent。
- ADR-017 后续将该边界细分：`4.0h` 负责真实来源解析、PhotoKit 原始删除与资产失效/撤权，`4.0i` 负责复验 source anchor 和稳定 Detail 路由。
- `4.2` 只消费并验证两者，不在测试任务中补写生产功能。

## 备选方案

1. **MusicKit catalog/personal recommendations**：拒绝。是网络 Web Service，必须放弃 Echo 的零上传/零运行时下载红线才能采用。
2. **仅显示“需要 Apple Music 授权”**：拒绝。这会让非订阅用户或拒绝权限的用户无法获得本就可离线产生的建议。
3. **将 feelings 作为 canonical memory JSON 数组**：拒绝。频繁编辑子实体会放大整体重写，并模糊索引和级联删除边界。

## 后果

正面：US-AWK-005 与 R-001/R-005 完全一致；离线降级始终有结果；权限、可播放性、感受事务、搜索隔离、审计时机和任务归属均可测。

负面：不使用 Apple Music 云端个性化，推荐新鲜度低于 catalog 方案；必须新增关系表/迁移与媒体库适配器；Bundle 建议不一定可播放。

## 参考

- Apple MusicKit：<https://developer.apple.com/documentation/musickit>
- Apple `MusicAuthorization`：<https://developer.apple.com/documentation/musickit/musicauthorization>
- Apple `MPMediaLibraryAuthorizationStatus`：<https://developer.apple.com/documentation/mediaplayer/mpmedialibraryauthorizationstatus>
- Apple `MPMediaQuery`：<https://developer.apple.com/documentation/mediaplayer/mpmediaquery>
- Apple `MPMediaItemPropertyIsCloudItem`：<https://developer.apple.com/documentation/mediaplayer/mpmediaitempropertyisclouditem>
- `AGENTS.md` R-001/R-005/R-006/R-007/R-008、D-005、§4.2
- `docs/decisions/ADR-012-awakening-system-boundary.md`
- `docs/01-spec/用户故事与验收标准规格书.md` US-AWK-005
