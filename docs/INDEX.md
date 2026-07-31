# Echo 项目文档索引

> 本文档供 AI Agent（OpenCode 桌面版）及人类开发者快速定位项目文档。
> 所有文档位于 `docs/` 目录下，遵循 Echo v4.6 规格。
> **Agent 使用指引**：启动时读取本文件建立全局认知；执行任务前根据 `AGENTS.md` §0.2 映射表按需读取具体章节。

---

## 📁 文档目录

| 类别                   | 文件路径                                          | 核心内容                                          |
| ---------------------- | ------------------------------------------------- | ------------------------------------------------- |
| **规格与需求**         | `01-spec/用户故事与验收标准规格书.md`             | 66 个用户故事、AC、优先级、技术契约、错误矩阵     |
| **架构设计**           | `02-architecture/架构设计文档.md`                 | Cognitive Pipeline + Actor + Observable ViewModel |
| **技术选型**           | `02-architecture/技术选型文档.md`                 | 模型、数据库、推理框架选型决策                    |
| **数据流**             | `02-architecture/数据流全链路技术说明文档.md`     | 检索/摄入/同步/唤醒/反馈数据流                    |
| **双语言实现**         | `03-implementation/双语言实现说明文档.md`         | 跨语言检索、翻译、术语表                          |
| **开发避坑手册**       | `03-implementation/开发避坑与关键注意点手册.md`   | 禁止事项、陷阱、防御性检查清单                    |
| **AI Native 开发理念** | `04-ai-native/AI Native开发理念与实战技巧手册.md` | AI Native 方法论、工具、Agent 协作                |
| **产品创新工具**       | `04-ai-native/产品创新工具全景指南.md`            | 前沿 AI 工具介绍及融入方案                        |
| **开发计划**           | `05-planning/开发计划安排文档.md`                 | 里程碑、时间线、资源安排                          |
| **UI 文档路由**        | `ui/README.md`                                     | Phase 3 UI 设计配置、自动化工作流、架构边界、测试 |
| **UI 设计风格**        | `ui/echo-memory-canvas-style.md`                   | echo-memory-canvas 完整设计规范、surface family、token |
| **UI 自动化工作流**    | `ui/automation-workflow.md`                        | 状态机、批准点、重试/停止规则、试点评分           |
| **UI 架构**            | `ui/architecture.md`                               | 六层架构、单向数据流、保护路径、组件边界          |
| **UI 测试与 Artifact** | `ui/testing-and-artifacts.md`                      | PR/Nightly 矩阵、artifact 策略、DoD                |
| **UI 就绪门禁**        | `ui/echo-readiness.md`                             | Echo 五类门禁、首次 bootstrap 证据位置             |
| **任务状态**           | `05-planning/task-status.json`                    | 任务状态、依赖、测试文件映射                      |
| **延期任务**           | `05-planning/deferred-items.json`                 | 延期到后续 Phase 的未解决任务，集成测试时扫描     |

---

## 🔍 按模块快速定位

| 如果你需要...                             | 请查阅...                                              |
| ----------------------------------------- | ------------------------------------------------------ |
| 用户故事与 AC                             | `01-spec/用户故事与验收标准规格书.md` §2~11            |
| 核心架构原则（Pipeline/Actor）            | `02-architecture/架构设计文档.md` §3~4                 |
| 技术选型理由与决策                        | `02-architecture/技术选型文档.md` §1~5                 |
| 数据流程细节（检索/摄入/同步）            | `02-architecture/数据流全链路技术说明文档.md` §2~5     |
| 跨语言检索实现                            | `03-implementation/双语言实现说明文档.md` §4           |
| 双语言审计与监控                          | `03-implementation/双语言实现说明文档.md` §7           |
| 避坑规则（并发/状态/管线）                | `03-implementation/开发避坑与关键注意点手册.md` §2~4   |
| 隐私校验与审计完整性                      | `03-implementation/开发避坑与关键注意点手册.md` §6     |
| ExcludedAssets 边界规则                   | `03-implementation/开发避坑与关键注意点手册.md` §9     |
| 反馈学习与权重计算                        | `03-implementation/开发避坑与关键注意点手册.md` §10    |
| AI Native 开发理念                        | `04-ai-native/AI Native开发理念与实战技巧手册.md` §1   |
| AI Native 协作流程（需求→编码→测试→运维） | `04-ai-native/AI Native开发理念与实战技巧手册.md` §2~7 |
| 创新工具选型与融入方案                    | `04-ai-native/产品创新工具全景指南.md` §3~7            |
| 工具融入优先级                            | `04-ai-native/产品创新工具全景指南.md` §8              |
| 开发里程碑与时间线                        | `05-planning/开发计划安排文档.md` §2                   |
| Phase 3 UI 设计配置与规范                  | `ui/echo-memory-canvas-style.md`                       |
| UI 自动化工作流与试点选择                  | `ui/automation-workflow.md`                            |
| UI 架构边界与保护路径                      | `ui/architecture.md`                                   |
| UI 测试策略与 artifact                     | `ui/testing-and-artifacts.md`                          |
| Echo 就绪门禁                              | `ui/echo-readiness.md`                                 |
| 当前开发任务与进度                        | `05-planning/task-status.json`                         |

---

## 📊 用户故事模块概览

| 模块           | 故事数量 | 关键故事编号               |
| -------------- | -------- | -------------------------- |
| 数据源接入     | 13       | US-SRC-001~013             |
| 记忆摄入       | 6        | US-ING-001~006             |
| 跨语言检索     | 8        | US-RET-001~008             |
| AI 响应与创作  | 8        | US-SYN-001~008             |
| 主动唤醒与交互 | 7        | US-AWK-001~007             |
| 隐私与数据主权 | 8        | US-PRV-001~008             |
| 系统透明度     | 5        | US-DIS-001~004, US-SYS-001 |
| 系统韧性       | 4        | US-RES-001~004             |
| 设置与管理     | 4        | US-SET-001~004             |
| 反馈与学习     | 3        | US-FBK-001~003             |

---

## 🏗️ 架构核心速查

| 组件                   | 定义                                                         | 文档参考               |
| ---------------------- | ------------------------------------------------------------ | ---------------------- |
| **Cognitive Pipeline** | 无状态处理节点（Search/Ingest/Sync/Awakening/Feedback）      | `架构设计文档.md` §2.1 |
| **Actor**              | 可变状态封装（Privacy/ExcludedAssets/Feedback/Progress/PendingOps/TaskQueue/ModelManifest/GenerationRegistry） | `架构设计文档.md` §2.2 |
| **ViewModel**          | `@Observable` + `@MainActor` 驱动 UI                         | `架构设计文档.md` §2.3 |
| **分代索引**           | Memory/Representation/ModelManifest/IndexGeneration/ActiveRouteSet 六表 + 每代独立 VectorStoreActor | `架构设计文档.md` §4.4 |
| **PrivacyCheckpoint**  | 强制隐私校验，所有 Pipeline 入口必须调用                     | `架构设计文档.md` §7.1 |
| **统一错误矩阵**       | L1~L4 分级，L2 仅手动重试                                    | `架构设计文档.md` §5   |
| **TaskProgress**       | SQLite 表存储断点续传进度                                    | `架构设计文档.md` §6.1 |

---

## 🔧 技术栈速查

| 层级       | 选型                                    | 文档参考             |
| ---------- | --------------------------------------- | -------------------- |
| 视觉编码   | MobileCLIP-B LT                          | `技术选型文档.md` §1 |
| 语音转写   | SenseVoice Small (GGUF / CoreML INT8)    | `技术选型文档.md` §2 |
| 文本嵌入   | multilingual-e5-small (384d)              | `技术选型文档.md` §3 |
| 向量数据库 | ProximaKit 1.7 (HNSW)                   | `技术选型文档.md` §4 |
| 推理框架   | Core ML (主力) + SenseVoice.cpp (ASR)   | `技术选型文档.md` §5 |
| 应用架构   | `@Observable` + Actor Isolation         | `技术选型文档.md` §6 |
| 本地化     | String Catalog + 术语表 JSON            | `技术选型文档.md` §7 |

---

## 📌 Agent 使用指引

1. **启动时**：读取本文件，了解文档全貌和模块分布
2. **执行任务前**：
   - 根据 `AGENTS.md` §0.2 的任务类型映射表
   - 结合本索引的“按模块快速定位”表
   - 按需读取具体文档的章节
3. **遇到疑问**：回到本索引，确认是否遗漏了相关文档
4. **任务执行中**：参考 `task-status.json` 确认当前进度和依赖；参考 `deferred-items.json` 确认延期任务状态

---

**文档维护声明**
本索引与 Echo v4.6 全量规格书、架构设计、技术选型等文档协同维护。当文档目录或结构发生变化时，需同步更新本文件。

**下次全面复审日期**：2026-08-15（与 Phase 3 UI 阶段同步）