# ADR-010: Canonical 存储与 generation 生命周期

**状态**: 已接受
**日期**: 2026-08-04
**决策人**: Privacy Engineering Lead（审批）+ Storage Architecture Lead（实现）

## 背景

基线中 ING-006（canonical 事务性 vector/text/FTS 提交、故障注入回滚、事务审计路径）完全未映射；384→512 填充与单 store 生产路由存在（须删除）；`GenerationRegistryActor`/`ActiveRouteSet` 已有骨架但无重启恢复/原子发布/回滚；反馈身份（generation 维度）与全删除边界无生产验证；`originalTimestamp`/`userLocked` 持久化缺失（DEF-38-001/002）。

## 决策

1. **Canonical Memory/Representation schema**：`CanonicalMemoryRepositoryActor` 持有规范事实源；确定性 ID（RFC 4122 派生，不依赖输入顺序）；事务 CRUD（canonical + vector + FTS 同事务）。
2. **Generation 生命周期**：每个模型空间（E5 384d 文本 / SigLIP2 视觉 / OCR / lexical）独立 generation 与 `VectorStoreActor`；`GenerationRegistryActor` 管理 manifest 与逐代文件；`ActiveRouteSet` 原子发布。
3. **重启恢复 + shadow build + 原子发布 + 回滚**：启动恢复 active route；新 generation shadow 构建完成后原子发布；旧 generation 可回滚；任何故障注入点不得产生 half-write 或 mixed-generation route。
4. **Generation-aware 反馈与删除**：feedback 身份绑定 generation（US-FBK-001/002/003）；全删除边界事务性覆盖向量、索引、缓存、元数据、审计、translationCache（D-005）。
5. **删除/ExcludedAssets 边界**：用户「仅从 Echo 移除」写入 ExcludedAssets；系统自动删除与原始文件级联删除不写入；级联删除清理无效排除记录（R-003/D-002/D-003）。
6. **迁移发布子契约**（与 ADR-008 共同管辖）：导入目标为全新 staging 数据库与 generation；每个计数/哈希/引用校验通过后才原子发布；任何拒绝/回滚保持 active 数据库与 active routes 不变；staging 文件 `NSFileProtectionComplete`、固定 app 目录、no-follow open、显式 symlink 拒绝、备份排除；成功/失败/取消/下次启动确定性清理。
7. **删除 384→512 padding 与单 store 生产路由**：文本与视觉空间彻底分离。

## 备选方案

| 方案 | 描述 | 结论 |
|------|------|------|
| **A（采纳）** | Canonical repository + 分代 + 原子发布/回滚 + 事务删除 | ✅ 满足 D-001~D-005、ING-006、US-FBK 身份要求 |
| B | 单 store 混合空间 + 非事务写入 | ❌ mixed-generation 路由、half-write、无法回滚 |
| C | 文件系统直接写库无 staging | ❌ 发布中断产生不可恢复中间态 |

## 后果

### 正面

- 重启恢复、原子发布、回滚、反馈 generation 身份与全删除边界全部可故障注入验证。
- 迁移包发布/回滚契约与 ADR-008 共同保证 active 数据永不处于中间态。
- 关闭 DEF-38-001/002 的证据路径确定。

### 负面

- 每代一个 VectorStore 实例增加文件与内存管理复杂度。
- 事务性 CRUD 需要 `DatabaseMigrationActor` 维护 schema 演进。
- 全删除边界测试需覆盖所有存储侧写路径。

## 参考

- `docs/01-spec/用户故事与验收标准规格书.md` US-ING-006、US-PRV-004/006/007、US-AWK-007、US-FBK-001~003
- AGENTS.md D-002/D-003/D-005、§5 存储层次与契约
- `docs/02-architecture/架构设计文档.md`、`docs/02-architecture/数据流全链路技术说明文档.md`
- `docs/05-planning/phase3f-execution-plan.md` §4.6.4（3F.4 文档合同）、§4.6.7（3F.7 迁移安全子契约）
- ADR-008（来源导入边界）
