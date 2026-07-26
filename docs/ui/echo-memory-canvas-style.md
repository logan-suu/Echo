# Echo Memory Canvas · 设计风格规范

> **上游权威**：用户批准的 `echo-memory-canvas` 设计配置，扩展 `apple-native` 基础
> **物化来源**：`Echo SwiftUI UI Agent 自动化 Bootstrap 与执行规范.md` §7
> **不得覆盖**：Core 领域逻辑、数据库 schema、模型集成、隐私声明、CI 门禁
> **最后同步**：2026-07-25 bootstrap 规范 §7 全文

---

## 1. 设计配置标识

- **Profile ID**：`echo-memory-canvas`
- **Base Profile**：`apple-native`
- **批准状态**：用户已批准（记录于 bootstrap 规范 §7.1）
- **额外灵感来源**：Pinterest 仅启发 Discovery surfaces 的内容组织密度与探索节奏；**不是**产品依赖、品牌关系或复制其 UI 的许可

---

## 2. Apple 原生基础

### 2.1 系统容器与导航
- 优先使用 `NavigationStack`、`TabView`、`List`、`Form`、`Sheet`、`Alert`、`Menu`、`Toolbar`、`Searchable` 等系统容器和交互模式

### 2.2 Typography
- 只使用系统 Dynamic Type text styles（`.largeTitle`、`.title`、`.headline`、`.body`、`.callout`、`.subheadline`、`.footnote`、`.caption`）
- 不用固定字号构建主要信息层级
- 长文本可自然增长，不通过裁切维持卡片外形
- 标题、摘要、正文、metadata、caption 和 action 标签形成稳定层级

### 2.3 Color
- 使用 `Color.primary`、`.secondary`、系统 `background`、`fill`、`tint` 等 semantic colors
- 完整适配 light、dark 和 increased contrast
- Echo 使用温暖、克制的 accent：`Color.accentColor`
- Accent 限定于：tint、选中态、重点 action 和少量状态强调
- 必须通过对比度与色盲语义验证

### 2.4 SF Symbols
- 使用 SF Symbols 及其语义化 variant（`.fill`、`.circle`、`.slash`）
- 自定义图标只在系统符号无法表达产品概念时使用
- 自定义图标必须满足同等可访问性要求

### 2.5 可访问性
- 保留标准 focus、keyboard、VoiceOver、Voice Control、Switch Control、Reduce Motion
- 保留 context menu、swipe action、destructive confirmation 和系统手势行为
- 所有交互元素有 `accessibilityLabel`、`accessibilityHint`
- 动态内容变化触发 `accessibilityAnnouncement`

### 2.6 Motion
- 使用系统 motion、transition 和反馈语义
- `Reduce Motion` 开启时移除非必要位移和连续动画
- 不用视觉新奇性覆盖可预测性
- 转场保留空间关系

### 2.7 系统版本适配
- 最新系统视觉 API 不得成为最低部署版本不可用时的硬依赖
- 必须提供 `@available` 检查和 Apple 原生回退

---

## 3. 三类 Surface Family

### 3.1 Discovery surfaces
**适用场景**：Home、Search、collection browsing

- 使用内容优先的 adaptive masonry 或内容卡片布局
- 布局服务于扫描、比较和发现，不改变系统导航、Tab、搜索、菜单或选择行为
- **Masonry 启用条件**（见 §5）

### 3.2 Focus surfaces
**适用场景**：Memory detail、media viewing、translation

- 使用沉浸式单列系统导航
- 主内容按阅读或观看顺序呈现
- 相关来源、时间、位置、转写、翻译和操作进入清晰分组的 metadata
- **明确禁止 masonry**，不使用 masonry 分割注意力

### 3.3 Task surfaces
**适用场景**：Edit、settings、permissions、background tasks、errors、recovery

- 使用 Apple 原生 `Form`、`List`、`Sheet`、`Alert`、`Menu`、`Toolbar`
- 共享本 profile 的字体、颜色、间距、卡片语气和 motion
- **明确禁止 masonry**
- 任务完成率、可读性、系统习惯和错误恢复优先于内容发现感

### 3.4 Surface 契约强制
每个 Surface 契约必须声明：
- `surfaceFamily: discovery | focus | task`
- 所选系统容器
- 回退条件

---

## 4. 共享 Token 与视觉语言

### 4.1 Typography Token
```
title:       .largeTitle / .title
subtitle:    .headline
body:        .body
metadata:    .subheadline
caption:     .caption
action:      .callout
```
仅使用系统 Dynamic Type text styles。

### 4.2 Color Token
```
primary:     Color.primary
secondary:   Color.secondary
background:  Color(.systemBackground)
groupedBg:   Color(.systemGroupedBackground)
fill:        Color(.systemFill)
separator:   Color(.separator)
accent:      Color.accentColor
```
温暖、克制的 accent，限定于 tint、选中态、重点 action。

### 4.3 Radii Token
```
imageRadius: 系统上下文映射（卡片内图片）
cardRadius:  系统上下文映射（卡片容器）
```
不把超大圆角当作品牌替代品，不手工模拟系统 chrome。

### 4.4 Spacing Token
```
compact:   8pt  — masonry gutter、图标间距
normal:    12pt — 卡片内边距
grouped:   16pt — metadata 分组
section:   20pt — Form/List section 周边
```
间距随 size class 与 Dynamic Type 调整，不靠 magic number 拼接。

### 4.5 Materials
- 卡片优先使用 `systemBackground`、`systemGroupedBackground`、`systemFill`、`separator`
- 阴影、模糊和玻璃效果只能帮助层级，不得堆叠成主要信息架构

### 4.6 Image Policy
- 图片按来源比例、预先声明的受支持比例或语义裁切展示
- 缩略图允许安全裁切
- 人物、文字、票据等敏感内容需使用适合的 `contentMode`（`.fit`）或单列回退
- 加载前 fixture 必须提供稳定 `aspectRatio` metadata，避免异步重排

### 4.7 Metadata Hierarchy
1. 内容本体（图片/视频/文本/音频）
2. 标题或摘要
3. 时间、来源、类型和状态
4. 重复或低价值 metadata 合并到次级层，不用图标噪声替代文字含义

### 4.8 Symbols and Motion
- 图标：SF Symbols
- 动画：系统 `withAnimation` + `transaction` 语义
- 转场：保留空间关系，`Reduce Motion` 可简化

---

## 5. 内容类型卡片（Memory Cards）

Discovery surfaces 使用统一 Memory Card 协议，包含以下 variants。

### 5.1 Photo Card
- 以图片为主，保留稳定 aspect metadata
- 显示必要标题或日期
- VoiceOver label：先描述记忆类型与可用替代文本，再读关键 metadata
- Fixture：离线、确定、控制 `contentId`、`aspectRatio`、时间戳

### 5.2 Video Card
- 使用稳定 poster fixture、时长和 `play.rectangle` SF Symbol 或系统 overlay
- 自动化 fixture 不自动播放
- 辅助技术区分视频与静态图片
- Fixture：离线、确定、控制 `contentId`、`aspectRatio`、`duration`、poster

### 5.3 Text/Note Card
- 正文摘要可自然换行
- 设置可读的最大摘要策略（如 3 行）
- 提供完整内容入口
- 不得使用固定卡片高度裁掉文字
- Fixture：离线、确定、控制 `contentId`、`textContent`、`locale`、`title`

### 5.4 Voice Card
- 显示录音类型 icon、时长、可用转写摘要和播放状态语义
- 波形若存在必须来自确定 fixture，不能成为理解内容的唯一方式
- Fixture：离线、确定、控制 `contentId`、`duration`、`transcriptSummary`、`locale`

### 5.5 Mixed Memory Card
- 为图片、视频、文字、语音组合提供一个主内容和明确的类型摘要
- 避免在单卡内堆叠完整子卡
- VoiceOver 使用单一可理解容器，必要 action 单独暴露
- Fixture：离线、确定、控制 `contentId`、`primaryType`、`subTypes`、`summary`

### 5.6 卡片通用要求
- 由系统 text styles、semantic colors、materials、buttons 和 interaction primitives 组成
- 不复制 Pinterest 的外观或品牌元素
- 测试验证：accessibility label、value、traits、action、reading order、点击区域和内容类型
- 不以颜色、图片或 SF Symbol 作为唯一语义

---

## 6. 响应式、排序与可访问性规则

### 6.1 Masonry 启用条件
**仅 Discovery surfaces** 满足以下全部条件时使用 adaptive masonry：
- Regular Dynamic Type（非 accessibility sizes）
- 足够宽的宽度（compact → 单列，regular → 两列+）
- 卡片内容简单，适合视觉扫描
- iPad 根据可用宽度、split view 和内容复杂度选择列数

### 6.2 单列/List 回退（必须）
以下任一条件触发回退到单列卡片或系统 List：
- Accessibility Dynamic Type（`.accessibility1` 及以上）
- 窄宽度（compact size class）
- 长文本（超出摘要策略）
- 复杂语义（需要连续阅读顺序）
- 关键图片无法安全裁切
- 辅助技术难以理解视觉列顺序

### 6.3 排序规则
- 排序由显式稳定 key 决定（产品定义的相关度、记忆时间与稳定 ID tie-breaker）
- 布局计算不得改变语义顺序
- 刷新、旋转、Dynamic Type 变化和重复 fixture 运行必须得到确定顺序

### 6.4 Reading Order
- VoiceOver 与键盘 reading order 按语义数据顺序，**不是**按视觉装箱结果
- 跨列视觉位置不能成为 journey 或测试的唯一定位方式

### 6.5 卡片高度
- 卡片高度由内容和受支持比例决定
- 不得固定高度裁切文本
- 不得用无限文本撑开破坏扫描
- 达到摘要边界时提供明确的完整内容入口和辅助技术语义

---

## 7. Focus 与 Task 的共享表达

### 7.1 Focus surfaces
- 单列内容流、系统 back 行为、可预测 toolbar、grouped metadata
- 媒体沉浸不隐藏必要的可访问退出路径
- 翻译同时保留原文与译文关系

### 7.2 Task surfaces
- Form/List section、系统 disclosure、toggle、picker、progress、sheet、alert、confirmation
- 错误与恢复明确说明：发生了什么、可执行动作、结果
- 不伪装成内容卡片瀑布流

### 7.3 三类 Family 的视觉一致性
通过共享 token 和行为达成一致，不来自把同一布局套到所有页面：
- Typography、semantic colors、warm restrained accent、radii、spacing
- Materials、metadata hierarchy、SF Symbols、system motion

---

## 8. 明确禁止项

1. ❌ 在 edit、settings、permissions、background tasks、errors、recovery、memory detail、media viewing 或 translation 上使用 masonry
2. ❌ 制作 Pinterest-heavy 的自定义导航栏、Tab Bar、搜索框、筛选控件、按钮、手势或转场
3. ❌ 复制 Pinterest 名称、商标、图标、品牌色、文案、布局细节或可识别 trade dress
4. ❌ 硬编码只适用于单一设备、系统版本或外观的尺寸、颜色、列数和卡片高度
5. ❌ 用固定卡片高度裁切正文、Dynamic Type 内容或本地化文本
6. ❌ 用模糊、玻璃、阴影、大圆角、复杂动画或视觉新奇性代替清晰信息架构
7. ❌ 在一个任务中重新提出多套视觉方向

---

## 9. 批准记录

| 事项 | 批准人 | 日期 | 来源 |
|------|--------|------|------|
| `echo-memory-canvas` 设计配置 | 用户 | 2026-07-25 | bootstrap 规范 §7 |
| `apple-native` 基础 | 用户 | 2026-07-25 | bootstrap 规范 §7.1 |
| Discovery/Focus/Task 三类映射 | 用户 | 2026-07-25 | bootstrap 规范 §7.2 |

> 若要改变 profile、Apple 原生基础或三类 surface 映射，必须修订本文和 `docs/ui/echo-memory-canvas-style.md` 并重新获得用户批准。
