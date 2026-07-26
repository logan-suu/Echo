# UIAutomation/Policies

本目录保存 UI 自动化的机器可读策略文件。

## 文件

| 文件 | 内容 |
|------|------|
| `acceptance-policy.json` | acceptance 规则：门禁条件、矩阵定义、通过阈值 |
| `protected-paths.json` | 受保护路径清单：禁止修改的文件和目录 |
| `simulator-ownership.json` | 单 owner 规则：并发控制与冲突解决 |
| `retry-policy.json` | 重试预算：阶段限制、错误分类、降级策略 |
| `media-policy.json` | 媒体限制：禁止 screenshot/video 的具体规则 |
| `secret-policy.json` | 敏感信息扫描规则：PII、凭据、签名材料 |

## 保护路径（概述）

默认只读类别：
1. Core 领域逻辑和公共语义
2. 数据模型、数据库 schema、迁移和持久化规则
3. `DatabaseManager` 的打开、事务和生命周期规则
4. 隐私声明、签名、entitlements、发布配置和 secrets
5. CI 安全门禁、SwiftLint 基线和 acceptance policy
6. Live Simulator 审批规则
7. 模型文件、模型下载或打包逻辑、ProximaKit 集成边界

## 人工批准规则

- 最终视觉审批只通过 Live Simulator Review
- Agent 不能批准自己的输出
- 设计配置变化需重新获得用户批准
- Git commit/push/PR 需要用户明确调用适配后的交付命令
