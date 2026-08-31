# ADR-014: 发布合规边界与 Phase 4 准入门禁

**状态**: 已接受
**日期**: 2026-08-04
**决策人**: Release Manager + Privacy Engineering Lead（审批）+ Release Quality Lead（实现）

## 背景

基线中 Release simulator/device 均 exit 65；模型 Bundle 0/6；no-fixture 新装停在 "Echo is getting ready…"；无 `PrivacyInfo.xcprivacy`、无 App Store 隐私披露文档、无 release checklist、无每目标（Echo + EchoShareExtension）合规报告、无签名归档证据。`current_phase` 此前为 4，但 Phase 4 的所有质量门禁（Golden、性能、覆盖、合规）在 3F 完成前均无意义。

## 决策

1. **Phase 4 唯一入口 = 3F.11**：`current_phase` 置为 `"3F"`；Phase 4 全部 14 记录冻结为 `backlog` 且 `entry_gate: "3F.11"`；命令不得在 `3F.11 == done` 前把 Phase 4 级联为 `ready`。
2. **Pre-merge 证据边界**：3F.11 PR 只提交 pre-merge gate 证据（Release 构建、测试、覆盖、模型、隐私、合规、签名、no-fixture E2E），**不包含 merge SHA、不声明 Phase 4 已解锁**。`3F.finalize` 由人类合并后显式触发，才记录 merge SHA、把 3F.11 置 `done`、解锁 Phase 4（仅 4.1~4.9 `ready`，4.10~4.14 保持 `backlog`）。
3. **每目标合规报告**：`Scripts/validate_release_compliance.py` 发现所有可执行 app/extension target（显式 `Echo` 与 `EchoShareExtension`），逐 target 报告网络、linked-SDK、secret、entitlement、privacy-manifest、required-reason API、purpose-string 结果；任何 target 被跳过即测试失败。
4. **发布制品**：`Echo/Config/Release.xcconfig`、`PrivacyInfo.xcprivacy`、`docs/05-planning/app-store-privacy-disclosure.md`、`docs/05-planning/phase3f-release-checklist.md`、`CHANGELOG.md`；签名归档证据仅在受控 release 凭据环境生成。
5. **门禁阈值与阶段归属（2026-08-31 修订）**：3F.11 保留当时已批准的临时 coverage ratchet（release checklist 记录为排除 View 后 ≥65%），并要求 SwiftLint、strict concurrency、PrivacyCheckpoint、禁用 API/网络与 P0/P1 基本闭环证据通过；最终全局 line coverage ≥95% 不取消、不降级，转由 Phase 4 `4.6` 在 RC 前提供。受控签名/archive/export 由 `4.9` 提供，Golden/性能分别由 `4.1`/`4.3` 提供。
6. **模型合规**：`prepare_models.sh --verify-only` 100%、license/SBOM/checksum/参考推理全部获批（ADR-009）。
7. **禁止**：禁止在 3F.11 前启动 Golden、性能、TestFlight、Release Candidate 或最终发布集成；禁止 Agent 执行 merge/close/delete。
8. **发布资格不等于功能闭环**：基础生产路径、no-fixture E2E 与 per-target 合规允许 3F 完成功能阶段；最终 RC、TestFlight、受控签名、95% coverage、Golden 与性能证据属于 Phase 4 发布资格，不得在 `3F.finalize` 中伪造或追认。

## 备选方案

| 方案 | 描述 | 结论 |
|------|------|------|
| **A（采纳）** | Phase 4 锁定 + 3F.11 pre-merge 门禁 + 人类触发 finalizer | ✅ 门禁完整、解锁可审计、符合 §10/§15 |
| B | 提前解锁 Phase 4 并行推进 | ❌ 门禁形同虚设，无法证明生产完成 |
| C | Agent 在 PR 内记录 merge SHA 并解锁 | ❌ 伪造合并证据，违反 human-only merge |

## 后果

### 正面

- 发布证据全部可定位、可复验；Phase 4 解锁有不可变 merge SHA 锚点。
- 每 target 合规报告覆盖 Echo 与 EchoShareExtension，避免扩展 target 逃逸审查。
- DEF-38-003（覆盖门禁）与 DEF-47-001（测试 helper）的关闭证据统一由 Phase 4 `4.6` 提供。

### 负面

- Phase 4（含 TestFlight、RC、最终发布）整体后移到 3F.11 人类合并之后。
- 签名/归档证据依赖受控 release 环境与凭据，本地无法产生。
- 覆盖率恢复 95% 需要在 Phase 4 `4.6` 完成大量测试扩充，并在 `4.10` RC 前通过。

## 参考

- AGENTS.md §9（测试与质量契约）、§12.6（阶段集成测试）、§15（GitHub 自动化规约）
- `docs/05-planning/phase3f-execution-plan.md` §4.3（Phase 4 冻结）、§10（Phase 4 解锁与 handoff）
- `docs/05-planning/phase3f-evidence-index.md`（3F.11 与 3F.finalize 条目）
- `docs/05-planning/deferred-items.json` DEF-38-003、DEF-47-001
