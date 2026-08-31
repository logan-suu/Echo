# Phase 3F Release Checklist

对应规格: docs/decisions/ADR-014-release-compliance-boundary.md §决策-4/5 (发布制品与门禁阈值),
          docs/05-planning/phase3f-execution-plan.md §11.2 (3F.11 gate matrix)
任务: 3F.11 - Production E2E 与 Phase 4 准入门禁
状态: Phase 3F functional gate finalized；Phase 4 release qualification open
生成时间: 2026-08-12

> 本 checklist 保留 3F.11 预合并证据。PR #63 已于 2026-08-26 合并，
> `3F.finalize` 于 2026-08-31 完成。未填写的签名/archive、最终 95% coverage、
> Golden、性能与 RC 证据没有被追认为通过，分别由 Phase 4 的 4.1/4.3/4.6/4.9/4.10 负责。

## 1. 签名与归档 Approver 记录

> 本节是 Phase 4 `4.9` 的阻断清单，不是 3F.finalize 的完成条件。

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

> ✅ `3F.finalize` 记录：PR #63，merge commit
> `18784ea426d411ab539c5bd9c0eecd4548ae7e7a`，merged by `logan-suu` at
> `2026-08-26T03:25:13Z`；Phase 4 已解锁 4.1~4.9，4.10~4.14 保持 backlog。
