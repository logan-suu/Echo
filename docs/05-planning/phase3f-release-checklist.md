# Phase 3F Release Checklist

对应规格: docs/decisions/ADR-014-release-compliance-boundary.md §决策-4/5 (发布制品与门禁阈值),
          docs/05-planning/phase3f-execution-plan.md §11.2 (3F.11 gate matrix)
任务: 3F.11 - Production E2E 与 Phase 4 准入门禁
状态: pre-merge review (仅预合并证据；merge SHA 与 Phase 4 解锁由人类 finalizer 记录)
生成时间: 2026-08-12

> 本 checklist 由 Release Quality Lead 在 3F.11 预合并阶段逐项填写，Release
> Manager 与 Privacy Engineering Lead 审批。签名/归档相关证据仅在受控 release
> 凭据环境产生（ADR-014 §决策-4）。

## 1. 签名与归档 Approver 记录

| Field | Value | Status |
| --- | --- | --- |
| Signing approver |  | ☐ |
| Evidence location | `docs/05-planning/phase3f-evidence-index.md` → 3F.11 entry | ☐ |
| Artifact digest (archive SHA-256) |  | ☐ |
| Retention rule | Release archive retained for the App Store required period | ☐ |
| Expiry date |  | ☐ |
| CODE_SIGNING_ALLOWED=NO device build exit | 0 (local) | ☐ |
| Release simulator build exit | 0 (local) | ☐ |

## 2. 可执行 Target 清单与逐 Target 合规报告

`Scripts/validate_release_compliance.py` 发现并扫描全部可执行 app/extension
target；任何 target 被跳过即门禁失败（ADR-014 §决策-3）。

| Target | Type | Networking | Linked SDK | Secrets | Entitlements | Privacy manifest | Required-reason API | Purpose strings |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `Echo` | application | clean | clean | clean | app-groups, healthkit | PrivacyInfo.xcprivacy present | UserDefaults (CA92.1) | Photo/Location/Health × 6 |
| `EchoShareExtension` | app-extension | clean | clean | clean | app-groups | PrivacyInfo.xcprivacy present | none | none required |

**Report command:** `python3 Scripts/validate_release_compliance.py` (exit 0)
**Unit tests:** `python3 -m unittest Scripts.validate_release_compliance_tests` (9/9)

## 3. 门禁矩阵（§11.2）

| Gate | Command/environment | Expected | Evidence | Result |
| --- | --- | --- | --- | --- |
| Release simulator/device | `xcodebuild build -configuration Release ... CODE_SIGNING_ALLOWED=NO` | exit 0 | log + SHA | ☐ |
| Unit/integration/UI | serial full suites (`-parallel-testing-enabled NO`) | 100% pass | xcresult summary | ☐ |
| Coverage | `Scripts/coverage_gate.py` | approved contract met (≥65% excl. Views until Phase 4 restore to 95%, DEF-38-003) | report | ☐ |
| Models | `prepare_models.sh --verify-only` + reference inference | 100% present/valid/offline | manifest/SBOM/log | ☐ |
| No-fixture E2E | clean install journey (EchoUITests/Phase3FProductionE2ETests) | all steps pass | run manifest/AX tree/unified log | ☐ |
| Privacy/static | validate_static_bans + R-007 scans + purge | 100%/zero violations | report | ☐ |
| Release compliance | validate_release_compliance (per-target) | all targets scanned, no blocking findings | JSON report | ☐ |
| P0/P1/deferred | ledger validator | 0/0; no gating open | JSON report | ☐ |

## 4. App Store 隐私披露一致性

- `docs/05-planning/app-store-privacy-disclosure.md` 与 `PrivacyInfo.xcprivacy`
  及 App Store Connect 答案互证一致（收集数据 = 无）。
- 外部隐私政策版本号：______ (Release Manager 发布时填写)
- 权限用途文案齐备（Photos ×2, Location ×2, HealthKit ×2）。

## 5. 最终批准

| Approver | Role | Signature | Date |
| --- | --- | --- | --- |
| Release Quality Lead | implementation |  |  |
| Release Manager | gate approver |  |  |
| Privacy Engineering Lead | privacy approver |  |  |
| Security / Architecture (if required) |  |  |  |

**P0 = ____  P1 = ____**（3F.11 预合并必须 0/0）

> ⚠️ 预合并阶段不得填写 merge SHA、不得声明 Phase 4 已解锁。人类合并 3F.11
> 后，由 `3F.finalize` finalizer 记录 merge 证据并仅解锁 4.1~4.9。
