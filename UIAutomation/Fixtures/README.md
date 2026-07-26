# UIAutomation/Fixtures

本目录保存 UI 自动化所需的确定性输入数据。

## 要求

- 离线、可复现、不访问网络或生产数据库
- 控制时钟、UUID、随机数和动画
- 带 `schemaVersion` 字段
- 覆盖 loading、loaded、empty、error、permission-denied 等状态

## 内容类型 Fixture 规范

| Variant | 必需字段 |
|---------|---------|
| Photo card | `contentId`, `aspectRatio`, `timestamp`, `title` |
| Video card | `contentId`, `aspectRatio`, `duration`, `posterId`, `title` |
| Text/Note card | `contentId`, `textContent`, `locale`, `title` |
| Voice card | `contentId`, `duration`, `transcriptSummary`, `locale` |
| Mixed memory card | `contentId`, `primaryType`, `subTypes`, `summary` |

## Fixture 生命周期

1. `contract_drafting` 阶段：创建 fixture 定义
2. `ui_slice_generation` 阶段：Preview 和测试引用 fixture
3. `verification` 阶段：验证 fixture 可确定性解码
4. 后续切片：复用已有 fixture，增量更新
