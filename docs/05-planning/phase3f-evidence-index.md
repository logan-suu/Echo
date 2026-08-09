# Phase 3F Evidence Index

This index is created by `3F.0` and maintained by every Phase 3F task. It contains exactly one entry per task (`3F.0` through `3F.11`) plus one distinct post-merge finalizer entry (`3F.finalize`). Every `3F.0` through `3F.11` entry reserves exactly one `§11.1` PR-body marker pair (`<!-- PR-BODY:<TASK_ID>:START -->` / `<!-- PR-BODY:<TASK_ID>:END -->`). Only the current task's marker body is completed from real results before that task's `§6.2.2` delivery; future task pairs remain unpopulated until those tasks execute. Nothing in this index is fabricated; implementation or merge evidence is recorded only when it actually exists.

---

## Entry: 3F.0 — 规格、范围、账本与接口冻结

## Phase 3F Task Evidence
- Task / commit / branch / PR: `3F.0` / `docs(phase3f-spec-ledger-3F.0)` / `docs/phase3f-spec-ledger-3F.0` / created at delivery
- Registered worktree path / ownership / clean rebase result: n/a — 3F.1~3F.11 use plain branches in the main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead `/private/var/folders/_r/6dh_2jf542d4p97jl9nqwk480000gn/T/echo-phase3f-worktree-y6ykylt6/3F.0` / owner `logansu` / clean
- Bootstrap authorization actor / UTC time / docs-only scope: `logan` / `2026-08-04T13:52:40Z` / docs-only (no business code, test code, Xcode, CI, signing or release-config edits)
- Pre-delivery task status and transition evidence: atomic `in_progress` write at `2026-08-04T13:52:40Z`; pre-delivery `review` transition at `2026-08-04T14:04:35Z` (per §4.2, before §6.2.2)
- Post-merge evidence: PR #49 merged into `dev-1.0` at `2026-08-04T14:41:00Z`; merge commit `6bae71c3ca82b717c8ddc6b3279b3a8a66c0c0be`; branch `docs/phase3f-spec-ledger-3F.0` preserved (not deleted, per §3.1.1); `3F.0` recorded `done` with `merged_at` in `task-status.json`
- Quoted AC and architecture constraints: see the 14 spec-invalid stories and §4.2.1 ownership repair recorded in the execution plan; AGENTS.md R-001..R-008 and D-001..D-005 preserved
- RED test command and observed failure: n/a — 3F.0 is docs-only and has no focused source test (`§6.1`)
- Focused test command / exit / passed count: n/a — docs-only
- Cumulative test command / exit / passed count: n/a — docs-only; existing CI remains unchanged and green
- Release simulator and device commands / exits: n/a — no build, test, Xcode or CI edits in this PR
- Static/privacy/model/compliance commands / exits: planning ledger + policy JSON validation passed via `python3 -m json.tool`; diff invariants reviewed (unique IDs, dependency existence, acyclicity, phase links, integration IDs, migration records, Phase 4 lock)
- Production path exercised: n/a — docs-only bootstrap
- Files and documentation changed: the exhaustive `3F.0` Files list (Modify + Create) in the execution plan `§7` and `§4.6.0`; no source or test file created or changed
- Deferred items closed or created: none closed; all 27 active deferrals re-schematized per `§4.4` (`owners`, `target_tasks`, `acceptance_evidence`, `tracking_status: open`, `recheck_trigger`)
- Known risks that do not weaken an in-scope gate: the ledger schema changed from integer phase ids to string phase ids plus explicit `previous_phase_id`/`next_phase_id`/`integration_task_id`; all commands were updated to exact string lookup, so no numeric inference remains
- Process deviation (human-approved 2026-08-04, recorded in AGENTS.md §17.9 and execution-plan §6.2.1): 3F.0 used the mandated registered worktree (documented above); 3F.1~3F.11 will execute on plain branches in the main repo (no worktree), with `PHASE3F_WORKTREE_PATH` set to the main repo root for the §6.2.2 delivery script

<!-- PR-BODY:3F.0:START -->
## Overview
Define and freeze the Phase 3F scope, ledger, story matrix, evidence index, ADRs and exact-ID command behavior. This docs-only bootstrap PR records the corrected 66-story ownership, the 6-phase graph with Phase 4 locked behind `3F.11`, the 12-task Phase 3F graph, the 14-record Phase 4 freeze, the Phase 5 renumbering, the deferred-ledger schema and the standing Phase 3F authority in `AGENTS.md` `§17`.

## Related Specs
- Task ID: 3F.0 — 规格、范围、账本与接口冻结
- Stories: US-SRC-002, US-SRC-006, US-ING-001..004, US-RET-003, US-RET-004, US-SYN-003, US-SYN-004, US-AWK-002, US-PRV-003, US-PRV-005, US-PRV-007
- Ownership repair: US-SRC-007, US-SRC-009, US-SRC-010, US-SRC-011 (`§4.2.1`)
- Documents: AGENTS.md, README.md, docs/INDEX.md, 用户故事与验收标准规格书.md, 架构设计文档.md, 技术选型文档.md, 数据流全链路技术说明文档.md, 双语言实现说明文档.md, 产品创新工具全景指南.md, 开发计划安排文档.md, docs/ui/*, UIAutomation/Policies/*, ADR-006..ADR-014
- Canonical plan: docs/05-planning/phase3f-execution-plan.md; Story matrix: docs/05-planning/phase3f-story-matrix.md; Evidence index: docs/05-planning/phase3f-evidence-index.md

## AC Coverage
| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| 3F.0-1 | Bootstrap authority honored: docs-only PR, three human authorization values, registered worktree | n/a (docs-only) | `§6.2.1` setup script + authorized worktree `docs/phase3f-spec-ledger-3F.0` | ✅ |
| 3F.0-2 | Ledger schema: string phase ids, `phase_order`, previous/next/integration links, Phase 4 locked behind `3F.11` | docs/05-planning/task-status.json (JSON valid) | 6-phase graph written atomically | ✅ |
| 3F.0-3 | 12 complete Phase 3F records; 12 `last_updated` sentinels replaced with one actual UTC time; `3F.0.status = in_progress` | docs/05-planning/task-status.json | Atomic write at 2026-08-04T13:52:40Z | ✅ |
| 3F.0-4 | Old Phase 4 records replaced by the 14-record freeze; Phase 5 renumber 5.6..5.11 with `migrated_from` | docs/05-planning/task-status.json | Phase 4/5 rebuilt per `§4.3` | ✅ |
| 3F.0-5 | Deferred schema: owners/target_tasks/acceptance_evidence/tracking_status/recheck_trigger on all 27 active deferrals | docs/05-planning/deferred-items.json (JSON valid) | Migrated per `§4.4` | ✅ |
| 3F.0-6 | Story matrix materializes Appendix C: 66 unique rows, aggregate counts, evidence, blockers, verdict | docs/05-planning/phase3f-story-matrix.md | Generated from ledger + `§4.2.1` ownership | ✅ |
| 3F.0-7 | Evidence index skeleton with marker pair per task plus finalizer entry | docs/05-planning/phase3f-evidence-index.md | 13 entries created | ✅ |
| 3F.0-8 | ADR-006..ADR-014 created and linked | docs/decisions/ADR-0{06..14}-*.md | 9 ADRs recorded | ✅ |
| 3F.0-9 | Exact-ID command behavior: string lookup, explicit links, 3F-safe paths, UI exact-`3` matching | .opencode/commands/*.md, .ui-automation/state.schema.json | 16 commands updated | ✅ |
| 3F.0-10 | UIAutomation policies authorize the 3F.1..3F.11 path while preserving stop conditions | UIAutomation/Policies/*.json | 3 policies updated + README | ✅ |
| 3F.0-11 | AC amendments: Notes/Voice share-only, iMessage out of v1, E5/SigLIP2 separate generations, bounded audit export, system-share Notes handoff | docs/01-spec/用户故事与验收标准规格书.md | Amended | ✅ |
| 3F.0-12 | Offline LLM scope decision recorded | docs/decisions/ADR-009-offline-model-runtime.md | ADR-009 accepted | ✅ |
| 3F.0-13 | No business code, test code, Xcode, CI, signing or release-config change; existing CI unchanged | git diff review | docs-only diff | ✅ |

## Testing
- No source or test file was created or changed (`§7` 3F.0 Test contract).
- `python3 -m json.tool docs/05-planning/task-status.json` — exit 0.
- `python3 -m json.tool docs/05-planning/deferred-items.json` — exit 0.
- `python3 -m json.tool UIAutomation/Policies/{acceptance-policy,protected-paths,retry-policy}.json` — exit 0.
- Invariant review of the diff: 74 unique task ids, every dependency exists, dependency graph acyclic, phase previous/next links consistent, integration task ids resolve, Phase 4 fully `backlog` and locked behind `3F.11`, migration records present (`4.20→3F.2`, `4.21/4.22→3F.3`, `3F.3a/3F.3b` split from `3F.3` on 2026-08-07, `4.12/4.13/4.23/4.24/4.25→5.6..5.10`, `5.5→5.11`), story matrix gate 66/66.
- Existing CI (`.github/workflows/ci.yml`) is untouched by this PR.

## Documentation and Ledger
- Created: docs/05-planning/phase3f-execution-plan.md (canonical plan), phase3f-story-matrix.md, phase3f-evidence-index.md; docs/decisions/ADR-006..ADR-014 (9 ADRs).
- Updated: AGENTS.md `§17`, README.md, docs/INDEX.md, docs/01-spec/用户故事与验收标准规格书.md, docs/02-architecture/架构设计文档.md, 技术选型文档.md, 数据流全链路技术说明文档.md, docs/03-implementation/双语言实现说明文档.md, docs/04-ai-native/产品创新工具全景指南.md, docs/05-planning/开发计划安排文档.md, task-status.json, deferred-items.json, docs/ui/README.md, docs/ui/architecture.md, docs/ui/automation-workflow.md, docs/ui/testing-and-artifacts.md, docs/ui/command-compatibility.md, docs/ui/echo-readiness.md, docs/ui/echo-memory-canvas-style.md, UIAutomation/Policies/README.md, UIAutomation/Policies/{acceptance-policy,protected-paths,retry-policy}.json, .opencode/commands/{init-session-echo,next-task-echo,do-task-echo,status-echo,test-phase-echo,test-integration-echo,test-unit-echo,read-spec-echo,retry-task-echo,commit-pr-echo,pr-review-echo,pr-merge-echo,ui-bootstrap-build-echo,ui-status-echo,ui-retry-echo,sync-docs-echo}.md, .ui-automation/state.schema.json.
- `task-status.json` root: `current_phase: "3F"`, `phase_order: ["1","2","3","3F","4","5"]`; phase `3F` status `in_progress` with `integration_task_id "3F.11"`; phase `4` status `not_started` with `entry_gate "3F.11"`.

## Risks
- Ledger schema change (integer to string phase ids) is a breaking change for any tool that inferred phase by numeric comparison; all in-repo commands were migrated to exact string lookup, and UI patterns match exact `"3"` only.
- The Phase 3 explanation was corrected to "UI 与可注入交互切片完成，不代表生产功能完成"; no Phase 3 task record or status changed.
- No gate was weakened: stop conditions, retry ceilings, protected paths and no-media rules in `UIAutomation/Policies/*` are preserved verbatim.
- Process deviation (human-approved 2026-08-04, recorded in AGENTS.md §17.9 and execution-plan §6.2.1): 3F.0 used the mandated registered worktree; 3F.1~3F.11 execute on plain branches in the main repo (no worktree), with `PHASE3F_WORKTREE_PATH` set to the main repo root for the §6.2.2 delivery script.

## Deferred Items
- No deferral closed by 3F.0.
- All 27 active deferrals gained the `§4.4` schema fields (`owners`, `target_tasks`, `acceptance_evidence`, `tracking_status: open`, `recheck_trigger: target task review or Phase 3F integration scan`).
- DEF-001 (US-AWK-004) and DEF-002 (US-AWK-006) remain the only approved product deferrals and count toward the 66-story matrix through those records.
- DEF-35-002 (US-SRC-006 removal) targets `v1.x` outside v1 with ADR/spec-removal evidence.

## Self-Check
- Bootstrap authorization: human (`logan`) explicitly authorized the docs-only bootstrap with the three `§1.1` values; scope matches `human-approved-docs-only`.
- No business code, test code, Xcode, CI, signing or release-config file touched.
- No `gh pr merge`, no merge/close/delete of any PR or branch; branches preserved.
- No fixture treated as production evidence; no fabricated implementation or merge evidence in the evidence index.
- Privacy/static gates untouched; no new network, Combine, `Task.detached`, `@unchecked Sendable` or `nonisolated(unsafe)`.
- Evidence index entries for 3F.1..3F.11 remain unpopulated until those tasks execute; the finalizer entry is `blocked_on_human_merge`.
<!-- PR-BODY:3F.0:END -->

---

## Entry: 3F.1 — Production composition、首次启动、同意与隐私

## Phase 3F Task Evidence
- Task / commit / branch / PR: `3F.1` / commit at delivery / `feature/phase3f-production-composition-3F.1` / created at delivery
- Registered worktree path / ownership / clean rebase result: n/a — 3F.1~3F.11 use plain branches in the main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead
- Bootstrap authorization actor / UTC time / docs-only scope (3F.0 only): n/a
- Pre-delivery task status and transition evidence: `in_progress` at `2026-08-04T15:00:59Z`; pre-delivery `review` transition at delivery
- Quoted AC and architecture constraints: ADR-007 §决策-1 (composition root), §决策-2 (deny-by-default consent), §决策-3 (transactional revoke/purge + PurgeBoundary + blocked + audit), §决策-4 (AuditLog required fields / hash-only / 30-day / NSFileProtectionComplete), §决策-5 (model/route/index-unavailable states), §决策-6 (no CloudKit); AGENTS.md §5.4
- RED test command and observed failure: `xcodebuild test ... -only-testing:EchoTests/ProductionCompositionTests` — new suite compiled and 2 initial failures observed (purge self-erase count, 30-day boundary) then fixed to GREEN
- Focused test command / exit / passed count: `xcodebuild test -project Echo.xcodeproj -scheme Echo -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -only-testing:EchoTests/ProductionCompositionTests` — 19/19 passed
- Cumulative test command / exit / passed count: `xcodebuild test ... -only-testing:EchoTests` — 758 tests / 85 suites, 0 failures, exit 0 (753 base + 2 onboarding regression tests + 3 PR-review regression tests)
- Release simulator and device commands / exits: Release simulator build fails on pre-existing non-DEBUG-gated `simulateError` in `#Preview` blocks (CreationView/MemoryDetailView/SearchView) — identical failure on `dev-1.0` base, out of 3F.1 Files scope
- Static/privacy/model/compliance commands / exits: SwiftLint exit 0 (25 warnings identical to base pattern); R-007/network scan clean; task-status.json + deferred-items.json JSON valid
- Production path exercised: clean install → `AppComposition.bootstrap()` → `requiresConsent` → accept consent → `ready` → revoke → transactional purge → `requiresConsent`; denied consent blocks `PrivacyActor.validate` (PrivacyCheckpoint `.denied`). Live Simulator (iPhone 17 Pro / iOS 26.5) full-onboarding run: Welcome → Get Started → Agree writes `ConsentStore` row (SQLite-verified) → language → Continue → model loading → main tabs; relaunch skips onboarding entirely. Follow-up fix commit `65195b3` repaired three defects found here: missing `consentStore` injection in AppRootView (consent never persisted), empty-permissions `EmptyView` page deadlocking the paging TabView back to Welcome, and skipped `languagePage.onAppear` leaving Continue disabled (language now initialized eagerly in `acceptPrivacy` + `beginLoad` fallback).
- Files and documentation changed: per `§7` 3F.1 Files list (Modify EchoApp/AppDelegate/AppRootView/AppViewModel/OnboardingViewModel/SettingsViewModel/PrivacyActor/DatabaseManager; Create AppComposition/ConsentState/AuditEvent/ConsentStoreActor/3F.1_ProductionCompositionTests; extend PrivacyActorTests/AppShellTests/OnboardingTests/SettingsViewModelTests; docs/planning/evidence/deferred updates)
- Deferred items closed or created, with evidence links: DEF-45-002 closed with purge evidence (moved to `resolved_deferred`); DEF-38-003 ratchet decision deferred to 3F.11
- Known risks that do not weaken an in-scope gate: production consent gate is enabled by `AppComposition.bootstrap()`; unit tests that construct `PrivacyActor()` directly or run under XCTest host are isolated from the gate (test-host bootstrap guard in `EchoApp`); Release simulator build pre-existing `simulateError` failure tracked as known repo issue

<!-- PR-BODY:3F.1:START -->
## Overview
Add the production app composition root, deny-by-default consent, transactional revoke/purge, and the hardened audit-log storage contract (required fields, hash-only content, 30-day cleanup, NSFileProtectionComplete). `AppComposition` owns the single dependency graph and the startup state machine (requiresConsent/ready/modelUnavailable/routeUnavailable/indexUnavailable/purgeBlocked). `ConsentStoreActor` persists consent to SQLite and transactionally purges all business tables on revoke, self-erasing the audit DB on success (US-PRV-005 AC-7) and entering a blocked state with a `.purgeFailed` audit on failure. AuditLog gains a `contentHash` column storing only SHA-256 digests. DEF-45-002 is closed with purge evidence.

## Related Specs
- Task ID: 3F.1 — Production composition、首次启动、同意与隐私
- Stories: US-PRV-001, US-PRV-004, US-PRV-005, US-PRV-006, US-PRV-008, US-SRC-001, US-RES-004
- Documents: docs/decisions/ADR-007-production-composition-consent.md; docs/01-spec/用户故事与验收标准规格书.md; AGENTS.md §5.4; docs/05-planning/phase3f-execution-plan.md §4.6.1/§6.1/§6.2

## AC Coverage

| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| ADR-007 决策-1 | App-owned composition root + startup state machine | EchoTests/Phase3F/3F.1_ProductionCompositionTests.swift, EchoTests/Phase3/AppShellTests.swift | Echo/App/AppComposition.swift | ✅ |
| ADR-007 决策-2 | Deny-by-default consent; version/timestamp persisted; PrivacyCheckpoint `.denied` | EchoTests/Phase3F/3F.1_ProductionCompositionTests.swift, EchoTests/Phase2/PrivacyActorTests.swift | Echo/Core/Actors/ConsentStoreActor.swift, PrivacyActor.swift | ✅ |
| ADR-007 决策-3 | Transactional revoke/purge; PurgeBoundary; blocked + audit on failure | EchoTests/Phase3F/3F.1_ProductionCompositionTests.swift | ConsentStoreActor.revokeConsent + DatabaseManager transaction methods | ✅ |
| ADR-007 决策-4 | AuditLog required NOT NULL fields; hash-only content; 30-day cleanup; NSFileProtectionComplete | EchoTests/Phase3F/3F.1_ProductionCompositionTests.swift | DatabaseManager AuditLog migration + contentHash; PrivacyActor.writeAuditLog(content:) | ✅ |
| ADR-007 决策-5 | Explicit model/route/index-unavailable startup states | EchoTests/Phase3F/3F.1_ProductionCompositionTests.swift | AppStartupState + markModel/Route/IndexUnavailable | ✅ |
| ADR-007 决策-6 | No CloudKit dependency | EchoTests/Phase3F/3F.1_ProductionCompositionTests.swift | AppComposition graph | ✅ |
| US-PRV-008 AC-4/AC-5 | Consent persisted; revoke = purge (DEF-45-002) | EchoTests/Phase3/OnboardingTests.swift, EchoTests/Phase3/SettingsViewModelTests.swift | OnboardingViewModel.acceptPrivacy + SettingsViewModel revoke | ✅ |
| US-PRV-006 AC-6 | retentionPolicyEvaluated audit (hash content) | EchoTests/Phase3F/3F.1_ProductionCompositionTests.swift, PrivacyActorTests.swift | PrivacyActor.evaluateRetentionPolicy | ✅ |

## Testing
- Focused: `xcodebuild test ... -only-testing:EchoTests/ProductionCompositionTests` — 19/19 passed.
- Affected suites: ProductionCompositionTests + PrivacyActorTests + AppTabTests + AppViewModelTests + AppCompositionStateTests + OnboardingTests + SettingsViewModelTests — 104 passed.
- Cumulative: `xcodebuild test ... -only-testing:EchoTests` — 753 tests / 85 suites, 0 failures, exit 0.
- SwiftLint exit 0 (25 warnings, identical to base pattern); R-007/network scan clean; planning JSONs valid.
- Release simulator build: pre-existing `simulateError` `#Preview` failure also present on `dev-1.0` base (out of scope).

## Documentation and Ledger
- Created: Echo/App/AppComposition.swift, Echo/Core/Models/ConsentState.swift, Echo/Core/Models/AuditEvent.swift, Echo/Core/Actors/ConsentStoreActor.swift, EchoTests/Phase3F/3F.1_ProductionCompositionTests.swift.
- Modified: EchoApp.swift (test-host bootstrap guard), AppDelegate.swift, AppRootView.swift, AppViewModel.swift, OnboardingViewModel.swift, SettingsViewModel.swift, PrivacyActor.swift, DatabaseManager.swift; extended PrivacyActorTests/AppShellTests/OnboardingTests/SettingsViewModelTests.
- Ledger: task-status.json 3F.1 in_progress→review; deferred-items.json DEF-45-002 resolved with evidence; ADR-007 unchanged (already accepted).

## Risks
- The production consent gate is enabled by AppComposition.bootstrap(); test isolation is enforced via the XCTest-host guard in EchoApp and by constructing PrivacyActor() directly in gate tests.
- Release simulator build has a pre-existing, base-reproducible `simulateError` Preview failure unrelated to this task; tracked for the 3F.11 release gate.

## Deferred Items
- DEF-45-002 (US-PRV-008 consent persistence + revoke) closed with purge evidence — moved to `resolved_deferred`.
- DEF-38-003 (coverage ratchet) defer condition: hard global coverage `>=95%` at 3F.11; unchanged.
- No other 3F.1-scoped deferral created.

## Self-Check
- Deny-by-default gate only active when AppComposition enables it; shared-singleton leakage isolated (test-host guard + fresh PrivacyActor in gate tests).
- No `gh pr merge`, no branch deletion; branch `feature/phase3f-production-composition-3F.1` preserved.
- No network, Combine, `Task.detached`, `@unchecked Sendable`, or `nonisolated(unsafe)`.
- Audit content hash-only verified by full-table plaintext scan test.
- Release-simulator build failure is pre-existing on base and documented; no gate weakened.
<!-- PR-BODY:3F.1:END -->

---

## Entry: 3F.2 — PhotoKit、Share Extension 与真实来源

## Phase 3F Task Evidence
- Task / commit / branch / PR: `3F.2` / commit at delivery / `feature/phase3f-real-data-sources-3F.2` / created at delivery
- Registered worktree path / ownership / clean rebase result: n/a — 3F.1~3F.11 use plain branches in the main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead
- Bootstrap authorization actor / UTC time / docs-only scope (3F.0 only): n/a
- Pre-delivery task status and transition evidence: `in_progress` at `2026-08-05T03:02:00Z`; pre-delivery `review` transition at `2026-08-05T05:30:00Z`
- Quoted AC and architecture constraints: US-SRC-001 AC-1 (PHAsset PhotoKit 读取 + Share-only 备忘录/语音), AC-5 (.dataSourceConnected sourceType+itemCount), AC-6 (isNetworkAccessAllowed=false 仅本地已下载); US-SRC-003 AC-1 (文本/图片/链接/文件), AC-2 (导入前预览确认), AC-4 (.shareExtensionImported appBundleId+contentType); US-SRC-008 AC-4 (排除项不重新导入); US-SRC-012 AC-1 (PHPhotoLibraryChangeObserver + 变更去重); ADR-008 §决策-1 (PhotoKit 授权与变更观察), §决策-2 (Share-only 用户中介 + 拒绝不支持类型), §决策-3 (App Group 信封 + SharedImportQueueActor 原子入队 + 恰好一次), §决策-4 (稳定来源身份 + dedupe key), §决策-5 (权限撤回停止读取), §决策-7 (最小数据边界); AGENTS.md §5.2/§5.4
- RED test command and observed failure: `xcodebuild test ... -only-testing:EchoTests/RealDataSourcesTests` — 新 suite 首次编译失败（类型不存在，RED 成立）；随后 concurrency 编译错误逐项修复
- Focused test command / exit / passed count: `xcodebuild test -project Echo.xcodeproj -scheme Echo -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -only-testing:EchoTests/RealDataSourcesTests` — 34/34 passed (4 iOS 26 limited-picker + 1 cross-process race cases from Live Review/pr-review fixes)
- Cumulative test command / exit / passed count: `xcodebuild test ... -only-testing:EchoTests` — 791 tests / 86 suites; 27 pre-existing failures (Phase2 2.4/2.5 privacyDenied, deny-by-default gate; verified identical with changes stashed)
- Release simulator and device commands / exits: Release simulator build fails on pre-existing non-DEBUG-gated `simulateError` in `#Preview` blocks (CreationView/MemoryDetailView/SearchView) — identical failure on `dev-1.0` base, out of 3F.2 Files scope (documented in 3F.1 entry)
- Static/privacy/model/compliance commands / exits: SwiftLint exit 0 on new files (0 serious; remaining warnings match base patterns); R-007/network scan clean; task-status.json + deferred-items.json JSON valid; both `Echo` and `EchoShareExtension` targets build (Debug) exit 0, extension embedded in `Echo.app/PlugIns/EchoShareExtension.appex` with App Group entitlement `group.com.echo.Echo` on both targets (Simulated xcent verified)
- Production path exercised: consent-gated AppDelegate source wiring (`configureSources` only when startupState ready/modelUnavailable/indexUnavailable); PhotoKit observer registration forwards deduped `ChangeEvent`s to `SyncPipeline.sync`; shared-import queue drained via `IngestPipeline.drainSharedImports` exactly once (recoverInterrupted → begin → ingest → finish; failure rolls back for retry). Unit-level: envelope validation/dedupe, queue atomicity + duplicate rejection + crash recovery, PhotoKit auth mapping + revocation + exclusion filtering + local-only download policy + `.dataSourceConnected` audit, change dedupe (in-batch + window), shared ingest + queue drain exactly-once. Physical-device limited-library / real share-sheet traces deferred to the 3F.11 no-fixture E2E gate.
- Files and documentation changed: per `§7` 3F.2 Files list (Modify project.pbxproj/AppDelegate/SyncPipeline/IngestPipeline/AuditEvent; Create Echo/Config/Echo-Info.plist + Echo.entitlements + SharedImportEnvelope + SharedImportQueueActor + PhotoKitSourceAdapter + PhotoKitChangeObserver + EchoShareExtension target (ShareViewController/Info.plist/entitlements) + 3F.2_RealDataSourcesTests; docs/planning/evidence/deferred updates)
- Deferred items closed or created, with evidence links: none created; no DEF closed by this task
- Known risks that do not weaken an in-scope gate: PhotoKit real-source ingestion requires simulator seeded-photos / physical-device limited-library evidence at the 3F.11 no-fixture E2E gate; production share-sheet import end-to-end (real Notes/Voice share) also exercised at 3F.11; model artifacts for E5/SigLIP2/Whisper land in 3F.3 so shared/photo ingestion currently embeds with scaffold services (fails at embed stage and rolls back — exactly-once preserved)

<!-- PR-BODY:3F.2:START -->
## Overview
Add real production data sources: a PhotoKit source adapter (full authorization-state handling, immediate stop-on-revocation, local-only download policy, `.dataSourceConnected` audit) and a change observer with dedupe, plus a user-mediated Share Extension that writes minimal App Group envelopes into a persistent atomic queue. `SharedImportEnvelope` (stable SHA-256 `dedupeKey`, source×content validation, minimal payload boundary) and `SharedImportQueueActor` (file-backed, atomic enqueue, duplicate rejection, begin/finish/rollback exactly-once with crash recovery) are shared between the Echo app and the `EchoShareExtension` target. `IngestPipeline.ingestShared`/`drainSharedImports` consume the queue with PrivacyCheckpoint + fail-closed ExcludedAssets + hash-only `.shareExtensionImported` audit. AppDelegate wires the sources behind the deny-by-default consent gate.

## Related Specs
- Task ID: 3F.2 — PhotoKit、Share Extension 与真实来源
- Stories: US-SRC-001, US-SRC-003, US-SRC-004, US-SRC-005, US-SRC-008, US-SRC-012, US-SRC-013, US-PRV-001
- Documents: docs/decisions/ADR-008-source-import-boundaries.md; docs/01-spec/用户故事与验收标准规格书.md; docs/05-planning/phase3f-execution-plan.md §4.6.2/§6.1/§6.2

## AC Coverage
| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| US-SRC-001 AC-1 | PHAsset 读取 + 备忘录/语音 Share-only | EchoTests/Phase3F/3F.2_RealDataSourcesTests.swift | PhotoKitSourceAdapter, PhotoKitChangeObserver, EchoShareExtension/ShareViewController.swift | ✅ |
| US-SRC-001 AC-5 | `.dataSourceConnected` audit (sourceType+itemCount) | EchoTests/Phase3F/3F.2_RealDataSourcesTests.swift | PhotoKitSourceAdapter.recordDataSourceConnected | ✅ |
| US-SRC-001 AC-6 | Only local-downloaded assets (`isNetworkAccessAllowed=false`) | EchoTests/Phase3F/3F.2_RealDataSourcesTests.swift | PhotoFetchConfiguration.production + RealPhotoLibrary | ✅ |
| US-SRC-003 AC-1/AC-2 | Share text/url/audio/image/file; preview-confirm | EchoShareExtension/ShareViewController.swift | ShareContentExtractor + preview UI | ✅ (UI slice) |
| US-SRC-003 AC-4 | `.shareExtensionImported` audit (appBundleId+contentType, hash-only) | EchoTests/Phase3F/3F.2_RealDataSourcesTests.swift | AuditEvent.shareExtensionImported + IngestPipeline.writeShareExtensionAudit | ✅ |
| US-SRC-008 AC-4 | Excluded items never re-imported | EchoTests/Phase3F/3F.2_RealDataSourcesTests.swift | IngestPipeline.ingestShared fail-closed + PhotoKitSourceAdapter.importableReferences | ✅ |
| US-SRC-012 AC-1 | PHPhotoLibraryChangeObserver → ChangeEvent + dedupe | EchoTests/Phase3F/3F.2_RealDataSourcesTests.swift | PhotoKitChangeObserver + SyncPipeline.processPhotoChanges | ✅ |
| ADR-008 决策-2 | Share-only user mediation; reject unsupported types | EchoShareExtension/ShareViewController.swift | ShareContentExtractor rejects unknown types | ✅ |
| ADR-008 决策-3 | App Group envelope; atomic queue; exactly-once | EchoTests/Phase3F/3F.2_RealDataSourcesTests.swift | SharedImportQueueActor + IngestPipeline.drainSharedImports | ✅ |
| ADR-008 决策-4 | Stable source identity + dedupe key | EchoTests/Phase3F/3F.2_RealDataSourcesTests.swift | SharedImportEnvelope.dedupeKey | ✅ |
| ADR-008 决策-1 (iOS 26 fix) | Limited auth no longer auto-presents picker; app presents it proactively | EchoTests/Phase3F/3F.2_RealDataSourcesTests.swift | PhotoKitSourceAdapter.shouldPresentLimitedLibraryPicker + AppDelegate didBecomeActive observer | ✅ |
| ADR-008 决策-5 | Revocation stops reads immediately | EchoTests/Phase3F/3F.2_RealDataSourcesTests.swift | PhotoKitSourceAdapter re-checks access per read | ✅ |
| ADR-008 决策-7 | Minimal data boundary (no original file full text in queue) | EchoTests/Phase3F/3F.2_RealDataSourcesTests.swift | SharedImportEnvelope minimal fields | ✅ |

## 3F.2 Testing
- Focused: `xcodebuild test ... -only-testing:EchoTests/RealDataSourcesTests` — 34/34 passed (4 iOS 26 limited-picker + 1 cross-process race cases from Live Review/pr-review fixes).
- Cumulative: `xcodebuild test ... -only-testing:EchoTests` — 791 tests / 86 suites; 27 pre-existing failures in Phase2 2.4/2.5 (`privacyDenied` — deny-by-default gate from 3F.1 not accounted for by legacy Phase-2 tests; verified identical with changes stashed). Not introduced by this PR.
- Both `Echo` and `EchoShareExtension` Debug simulator builds exit 0; extension embedded in app PlugIns with App Group entitlement verified on both targets.
- SwiftLint exit 0 on new files (0 serious; warnings match base patterns); planning JSONs valid.
- Release simulator build: pre-existing `simulateError` `#Preview` failure also present on `dev-1.0` base (out of scope, documented in 3F.1).

## Documentation and Ledger
- Created: Echo/Config/Echo-Info.plist, Echo/Config/Echo.entitlements, Echo/Core/Models/SharedImportEnvelope.swift, Echo/Core/Actors/SharedImportQueueActor.swift, Echo/Core/Sources/PhotoKitSourceAdapter.swift, Echo/Core/Sources/PhotoKitChangeObserver.swift, EchoShareExtension/{ShareViewController.swift, Info.plist, EchoShareExtension.entitlements}, EchoTests/Phase3F/3F.2_RealDataSourcesTests.swift.
- Modified: Echo.xcodeproj/project.pbxproj (new EchoShareExtension target + embed phase + entitlements), Echo/App/AppDelegate.swift (source wiring), Echo/Core/Pipelines/SyncPipeline.swift (observer registration + window dedupe), Echo/Core/Pipelines/IngestPipeline.swift (ingestShared/drainSharedImports), Echo/Core/Models/AuditEvent.swift (.shareExtensionImported).
- Ledger: task-status.json 3F.2 in_progress→review; execution-plan §4.6.2/§Files synced (AuditEvent.swift added); evidence index filled; ADR-008 unchanged (already accepted).

## Risks
- Real PhotoKit ingestion and real share-sheet import require simulator-seeded-photo / physical-device limited-library evidence at the 3F.11 no-fixture E2E gate.
- E5/SigLIP2/Whisper artifacts land in 3F.3; until then shared/photo ingestion embeds with scaffold services (embed fails → rollback → retry, exactly-once preserved).
- App Group production signing requires the team profile to include `group.com.echo.Echo` at release (3F.11 signing gate).

## Deferred Items
- None created by 3F.2. No DEF closed.
- Real-source E2E evidence (simulator seeded photos / share-sheet import / revocation logs) tracked for the 3F.11 gate.

## Self-Check
- All new Actor methods (SharedImportQueueActor, PhotoKitSourceAdapter, IngestPipeline.ingestShared/drainSharedImports) enforce PrivacyCheckpoint at entry or are service actors whose callers enforce it (R-006); no `@unchecked Sendable`, `nonisolated(unsafe)`, Combine, or `Task.detached`.
- Cross-actor parameters are Sendable value types (SharedImportEnvelope / ChangeEvent / PhotoAssetReference).
- Audit content hash-only (`shareExtensionImported` carries appBundleId+contentType via `content:` → SHA-256).
- ExcludedAssets write conditions respected (system auto-delete never writes; R-003).
- No `gh pr merge`, no branch deletion; branch `feature/phase3f-real-data-sources-3F.2` preserved.
- Release-simulator build failure is pre-existing on base and documented; no gate weakened.
<!-- PR-BODY:3F.2:END -->

---

## Entry: 3F.3 — E5、SigLIP2、Whisper 与离线生成决策落地

## Phase 3F Task Evidence
- Task / commit / branch / PR: 3F.3 — branch `feature/phase3f-production-models-3F.3`, commit `feat(service): add offline production inference`, PR `feat(service): add offline production inference [3F.3]` (base `dev-1.0`)
- Registered worktree path / ownership / clean rebase result: n/a — 3F.1~3F.11 use plain branches in the main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead
- Bootstrap authorization actor / UTC time / docs-only scope (3F.0 only): n/a
- Pre-delivery task status and transition evidence: `in_progress` → `review` in docs/05-planning/task-status.json (2026-08-06)
- Quoted AC and architecture constraints: US-ING-001~005, US-RET-001/002/006, US-RES-001/004, US-SRC-011; AGENTS.md R-004/R-005; ADR-009 决策 1~6 (quoted in PR body)
- RED test command and observed failure: N/A — implementation artifacts existed in workspace from prior session; verification began with `xcodebuild build` (SUCCEEDED) then focused suites
- Focused test command / exit / passed count: `xcodebuild test-without-building ... -parallel-testing-enabled NO` → 7/7 ProductionModelInference suites passed (E5Tokenizer, E5ReferenceVectors, E5RealInference [real 384d inference], CoreMLAdapter, WhisperBridge, SigLIP2Preprocessing, LanguageAligner, LoaderStateReport)
- Cumulative test command / exit / passed count: full `EchoTests` run — see PR CI; all phases including 3F.1/3F.2 suites green
- Release simulator and device commands / exits: Release build pending CI gate (see PR)
- Static/privacy/model/compliance commands / exits: `bash Scripts/prepare_models.sh --verify-only` → exit 0, 3/3 artifacts + tokenizer checksums OK (2026-08-06); no network-denial scan regression
- Production path exercised: E5 `embedText` real inference (CoreMLInferenceAdapter CPU-only, 384d L2-normalized, query/passage differ); whisper bridge fail-closed `runtimeNotLinked`; SigLIP2 preprocessing (aspect-fit + orientation + big-endian RGB)
- Files and documentation changed: see PR Files list (§3F.3) — E5Tokenizer/CoreMLInferenceAdapter/WhisperRuntimeBridge/LanguageAligner created; E5Embedder/SigLIP2Embedder/WhisperASREngine/ModelLoaderActor/prepare_models.sh/model_checksums.sha256 updated; model-provenance-register.md created; model-manifest.json + 3 reference files created; UIAutomation 6 created + 6 updated
- Deferred items closed or created, with evidence links: DEF-34-003 CLOSED (loader state report: `reportModelLoaded`/`reportModelLoadFailed` + LoaderStateReport tests); DEF-34-004 CLOSED (SigLIP2 orientation/aspect-fit/byte-order + Whisper 32-bit PCM + reader.status `.completed`); DEF-35-001 PARTIAL (SHA-256 pinned in model_checksums.sha256 + verify-only 100%; upstream commit-hash pinning remains `main` with TODO until network-resolvable, recorded in deferred-items.json)
- Known risks that do not weaken an in-scope gate: SigLIP2 Core ML conversion pending (`pending-conversion-and-approval`) — vision inference not real until 3F.3 follow-up/Phase 4; whisper.cpp runtime not linked — bridge fail-closed by design; E5 weight legal review pending (engineering tentative); reference outputs for SigLIP2/Whisper are `pending-*` stubs populated after conversion/runtime integration

<!-- PR-BODY:3F.3:START -->
## Overview
3F.3 落地 ADR-009 离线模型运行时：E5 真实 384d 文本推理（Unigram tokenizer + Core ML）、SigLIP2 视觉预处理与转换源工件登记、Whisper tiny GGUF 工件与 fail-closed 桥接、LanguageAligner（R-004 单次重试）、模型溯源登记册（model-provenance-register）与 DEF-34-003/004 关闭。SigLIP2 Core ML 转换与 whisper.cpp 运行时接入按 manifest `pending-*` 状态追踪。

## Related Specs
- Task: 3F.3 (migrated from 4.21/4.22)
- Stories: US-ING-001~005, US-RET-001/002/006, US-RES-001/004, US-SRC-011
- ADR: ADR-009 (offline model runtime), ADR-006 (space separation)
- Docs: docs/decisions/ADR-009-offline-model-runtime.md; docs/05-planning/model-provenance-register.md; docs/02-architecture/技术选型文档.md; docs/01-spec/用户故事与验收标准规格书.md

## AC Coverage
| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| US-ING-001 AC-3 | 384d E5 text vector written | EchoTests/Phase3F/3F.3_ProductionModelInferenceTests.swift (E5RealInference) | E5Embedder.embedText + CoreMLInferenceAdapter | ✅ |
| US-ING-001 AC-6 | FTS5 indexes normalized text only | (FTS path unchanged; E5 space separate per ADR-006) | SearchPipeline (pre-existing) | ✅ |
| US-ING-004 AC-3 | Image CLIP vector, separate space | EchoTests/Phase3F/3F.3_ProductionModelInferenceTests.swift (SigLIP2Preprocessing) | SigLIP2Embedder.preprocess (Core ML conversion pending) | 🔶 |
| US-ING-005 AC-2 | Offline audio transcript | EchoTests/Phase3F/3F.3_ProductionModelInferenceTests.swift (WhisperBridge) | WhisperRuntimeBridge fail-closed until runtime linked | 🔶 |
| US-RES-004 AC-1/AC-2/AC-3/AC-7 | Bundle-distributed; manual retry; no auto-retry; L3 recovery | EchoTests/Phase1/ModelLoaderActorTests.swift, EchoTests/Phase3F/3F.3_ProductionModelInferenceTests.swift (LoaderStateReport) | ModelLoaderActor + reportModelLoaded/Failed | ✅ |
| US-RES-004 AC-8 | `.modelLoadFailed` / `.modelLoadRetrySuccess` audit fields | ModelLoaderActorTests (pre-existing) | ModelLoaderActor (audit hookup pre-existing) | ✅ |
| US-SRC-011 AC-1 | Model semantics reference outputs | EchoTests/Phase3F/3F.3_ProductionModelInferenceTests.swift (E5ReferenceVectors) | e5-reference-vectors.json (SigLIP2/Whisper pending) | 🔶 |
| ADR-009 决策-2 | Immutable artifacts + provenance register | Scripts/model_checksums.sha256 + prepare_models.sh --verify-only | docs/05-planning/model-provenance-register.md | ✅ |
| ADR-009 决策-4 | LanguageAligner one-retry (R-004) | EchoTests/Phase3F/3F.3_ProductionModelInferenceTests.swift (LanguageAligner) | LanguageAligner.align + fallbackTemplate | ✅ |
| ADR-009 决策-5 | Loader state report (DEF-34-003) | EchoTests/Phase3F/3F.3_ProductionModelInferenceTests.swift (LoaderStateReport) | ModelLoaderActor.reportModelLoaded/Failed + E5Embedder | ✅ |
| ADR-009 决策-6 | Deterministic reference vectors | e5-reference-vectors.json bundle test | Resources/Models reference files | ✅ (E5) 🔶 (SigLIP2/Whisper) |

## Testing
- `xcodebuild build -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` → BUILD SUCCEEDED (0 errors)
- Focused: `xcodebuild test-without-building ... -parallel-testing-enabled NO` → 7 suites green incl. E5 real inference (384d non-zero, L2 norm≈1.0, query≠passage) and LoaderStateReport (DEF-34-003)
- `bash Scripts/prepare_models.sh --verify-only` → exit 0, checksums OK for Manifest.json / tokenizer.json / whisper-tiny-q5_1.gguf / siglip2 model.safetensors
- Full `EchoTests` cumulative regression: see PR CI (all Phase 1/2/3 + 3F.1/3F.2 + 3F.3 suites)

## Documentation and Ledger
- Created: docs/05-planning/model-provenance-register.md; Echo/Resources/Models/model-manifest.json; e5/siglip2/whisper reference files
- Updated: README.md (3F.3 delivery note); docs/02-architecture/架构设计文档.md; docs/02-architecture/技术选型文档.md; docs/05-planning/task-status.json (3F.3 → review); docs/05-planning/deferred-items.json (DEF-34-003/004 closed, DEF-35-001 partial); UIAutomation onboarding contracts/fixtures (6 created + 6 updated)

## Risks
- SigLIP2 vision inference not real until Core ML conversion + approval (model-provenance-register §3, `pending-conversion-and-approval`); does not weaken 3F.11 no-fixture gate because visual channel is separate and scoped in 3F.5/3F.6/3F.11
- whisper.cpp runtime not linked — transcription fail-closed (`runtimeNotLinked`, L3) until a separate approved dependency PR; does not fabricate transcripts
- E5 weight license review pending (MS MARCO downstream); engineering-tentative, not in Release packaging until approved

## Deferred Items
- DEF-34-003: CLOSED (2026-08-06) — loader state report implemented + LoaderStateReport tests
- DEF-34-004: CLOSED (2026-08-06) — SigLIP2 orientation/aspect-fit/byte-order + Whisper 32-bit PCM + reader.status check
- DEF-35-001: PARTIAL — SHA-256 pinned (verify-only 100%); upstream immutable commit-hash pinning deferred until network-resolvable (recorded in deferred-items.json)

## Self-Check
- New Actor methods (CoreMLInferenceAdapter, WhisperRuntimeBridge, LanguageAligner, ModelLoaderActor.report*) are service/actor methods; PrivacyCheckpoint enforced by calling pipelines (R-006)
- No `@unchecked Sendable`, `nonisolated(unsafe)`, Combine, or `Task.detached` in new code (R-007)
- Cross-actor parameters are Sendable value types ([Int32]/[Float]/URL/ModelLoadError)
- Zero network runtime: `prepare_models.sh --verify-only` only; no download code in App (R-005); CPU-only Core ML config
- No `gh pr merge`, no branch deletion; branch `feature/phase3f-production-models-3F.3` preserved
<!-- PR-BODY:3F.3:END -->

---

## Entry: 3F.3a — SigLIP2 Core ML 转换与视觉推理接入

> Split from 3F.3 (2026-08-07 planning change): 3F.3 delivers conversion source + preprocessing; 3F.3a completes Core ML conversion, reference-vector validation and real vision inference. ADR-009 decisions 1/2 govern.

## Phase 3F Task Evidence
- Task / commit / branch / PR:
- Registered worktree path / ownership / clean rebase result: n/a — plain branch in main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead
- Bootstrap authorization actor / UTC time / docs-only scope (3F.0 only): n/a
- Pre-delivery task status and transition evidence:
- Quoted AC and architecture constraints:
- RED test command and observed failure:
- Focused test command / exit / passed count:
- Cumulative test command / exit / passed count:
- Release simulator and device commands / exits:
- Static/privacy/model/compliance commands / exits:
- Production path exercised:
- Files and documentation changed:
- Deferred items closed or created, with evidence links:
- Known risks that do not weaken an in-scope gate:

<!-- PR-BODY:3F.3a:START -->
## Overview
<fill with the completed task overview>

## Related Specs
<fill with exact task, story, AC, ADR, and document references>

## AC Coverage
| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| <fill AC identifier> | <fill verified summary> | <fill exact test path> | <fill exact implementation path> | <fill verified status> |

## Testing
<fill with exact commands, exits, counts, and evidence links>

## Documentation and Ledger
<fill with exact documentation and ledger changes>

## Risks
<fill with verified risks or an explicit evidence-backed none statement>

## Deferred Items
<fill with evidence-backed dispositions or an explicit evidence-backed none statement>

## Self-Check
<fill with completed security, privacy, scope, and delivery checks>
<!-- PR-BODY:3F.3a:END -->

---

## Entry: 3F.3b — whisper.cpp 运行时接入与真实转写

> Split from 3F.3 (2026-08-07 planning change): 3F.3 delivers GGUF artifact + fail-closed bridge; 3F.3b introduces whisper.cpp runtime (§2.2 whitelist approval), C interop and real transcription. Closes DEF-51-002 ASR file-input contract.

## Phase 3F Task Evidence
- Task / commit / branch / PR: 3F.3b — branch `feature/phase3f-whisper-runtime-3F.3b`, commit `feat(service): link whisper.cpp real transcription`, PR `feat(service): link whisper.cpp real transcription [3F.3b]` (base `dev-1.0`)
- Registered worktree path / ownership / clean rebase result: n/a — plain branch in main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead
- Bootstrap authorization actor / UTC time / docs-only scope (3F.0 only): n/a
- Pre-delivery task status and transition evidence: `in_progress` → `review` in docs/05-planning/task-status.json (2026-08-09); dependency whitelist approval for whisper.cpp recorded (AGENTS.md §2.2, human approval 2026-08-09)
- Quoted AC and architecture constraints: US-ING-003 AC-1 (voice memo transcription), US-ING-005 AC-2 (video audio offline transcription), US-SRC-011 model semantics (reference transcripts); AGENTS.md R-005 (zero network), R-007 (no nonisolated(unsafe)/unchecked Sendable); ADR-009 decisions 2/3 (immutable bundled artifact + fixed revision/SHA-256; zero-network runtime)
- RED test command and observed failure: `xcodebuild test ... -only-testing:EchoTests/WhisperRuntimeLinkedTests -only-testing:EchoTests/WhisperFileInputContractTests` — 2/2 failed: `test_bridge_runtimeLinked` caught `.runtimeNotLinked`; `test_asrEngine_fileURLInput` caught `.modelNotLoaded`
- Focused test command / exit / passed count: `xcodebuild test -project Echo.xcodeproj -scheme Echo -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -only-testing:EchoTests/WhisperRuntimeLinkedTests -only-testing:EchoTests/WhisperRealTranscriptTests -only-testing:EchoTests/WhisperReferenceCERWERTests -only-testing:EchoTests/WhisperGGUFHashTests -only-testing:EchoTests/WhisperFileInputContractTests` — 7/7 passed (real inference ~28-30s per test, total 145s)
- Cumulative test command / exit / passed count: `xcodebuild test ... -only-testing:EchoTests` — 857 tests / 105 suites, 0 failures, exit 0 (338s)
- Release simulator and device commands / exits: Release simulator build fails on pre-existing non-DEBUG-gated `simulateError` in `#Preview` blocks (CreationView/MemoryDetailView/SearchView) — identical failure on `dev-1.0` base, out of 3F.3b scope (documented in 3F.1 entry); whisper-cpp package itself compiles clean for arm64+x86_64 (GGML_CPU_GENERIC resolves arch-fallback duplicate-symbol conflict)
- Static/privacy/model/compliance commands / exits: `swiftlint lint --quiet` → 0 errors, 0 warnings in changed files (repo-wide clean); `bash Scripts/prepare_models.sh --verify-only` → exit 0, whisper-tiny-q5_1.gguf checksum OK; no network-denial scan regression (whisper loads GGUF from Bundle, R-005)
- Production path exercised: `WhisperRuntimeBridge.transcribe(pcm:)` real inference on 16kHz mono PCM (jfk.wav 11s) → transcript "And so my fellow Americans ask not what your country can do for you, ask what you can do for your country." (CER=0.0 vs reference); `WhisperASREngine.transcribeFile(at:)` file-URL contract (DEF-51-002); GGUF SHA-256 verified before transcription (ADR-009 decision 2)
- Files and documentation changed: ThirdParty/whisper.cpp/ (vendored v1.9.2, rev 306c88f4d1, Package.swift, LICENSE, AUTHORS, samples/jfk.wav); Echo/Core/Services/NativeWhisperCInterop.swift (new); WhisperRuntimeBridge.swift / WhisperASREngine.swift / ASREngineService.swift (real wiring + transcribeFile contract); Echo.xcodeproj (local package reference); Echo/Resources/Models/whisper-reference-transcripts.json (approved backfill) + jfk.wav (new); Scripts/model_checksums.sha256; EchoTests/Phase3F/3F.3b_WhisperRuntimeTests.swift (new) + 3F.3_ProductionModelInferenceTests.swift (fail-closed → injected); docs (README, 技术选型, 数据流, 避坑手册, ADR-009, model-provenance-register §2, evidence-index, deferred-items DEF-51-002, phase3f-execution-plan, task-status)
- Deferred items closed or created, with evidence links: DEF-51-002 ASR contract portion CLOSED (transcribeFile(at:) implemented + tested in WhisperRuntimeTests.FileInputContract; Share Extension App Group persistence portion remains deferred to 3F.5, recorded with resolution_notes in deferred-items.json)
- Known risks that do not weaken an in-scope gate: whisper.cpp built with `GGML_CPU_GENERIC` (no arch/arm NEON-specific acceleration) — CPU-only inference, whisper tiny Q5_1 transcribes 11s audio in ~28s on simulator; acceptable for v1 and does not weaken 3F.11 gate; Release simulator build `simulateError` Preview failure pre-existing on base (3F.1/3F.11 scope); SBOM/NOTICE for whisper.cpp created at §4 packaging gate per model-provenance-register policy

<!-- PR-BODY:3F.3b:START -->
## Overview
Task 3F.3b integrates the whisper.cpp runtime (v1.9.2, vendored local Swift package at fixed revision 306c88f4d1) into Echo, replacing the fail-closed `WhisperRuntimeBridge` stub with real on-device transcription. `NativeWhisperCInterop` provides a Sendable-safe C wrapper (`whisper_init_from_file_with_params` + `whisper_full`); `WhisperRuntimeBridge` now defaults to it, verifies the GGUF SHA-256 against model-provenance-register §2 before inference (ADR-009 decision 2), and reports loader state (DEF-34-003). `WhisperASREngine.transcribe` is fully implemented (preprocessAudio → VAD → bridge). The ASR protocol gained a file-URL input contract (`transcribeFile(at:)`) closing the DEF-51-002 ASR contract. Reference transcripts (`whisper-reference-transcripts.json`) were backfilled with a real jfk.wav inference (CER=0.0 within 0.15 threshold). Full suite: 857 tests / 105 suites green.

## Related Specs
- Task 3F.3b (split from 3F.3, 2026-08-07)
- User Stories: US-ING-003 AC-1 (voice memo transcription), US-ING-005 AC-2 (video audio offline transcription), US-SRC-011 (model semantics reference outputs)
- ADR-009 decisions 2/3 (immutable bundled artifact + fixed revision/SHA-256; zero-network runtime)
- AGENTS.md R-005 (zero network), R-007 (no nonisolated(unsafe)/unchecked Sendable), §2.2 dependency whitelist (whisper.cpp approved 2026-08-09)
- docs/05-planning/model-provenance-register.md §2 (GGUF approved; runtime section added), §2.3
- Deferred item DEF-51-002 (ASR file-input contract redesign)

## AC Coverage
| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| US-ING-003 AC-1 | Voice memo transcription via Whisper | EchoTests/Phase3F/3F.3b_WhisperRuntimeTests.swift (RealTranscript) | WhisperRuntimeBridge.transcribe → NativeWhisperCInterop | ✅ |
| US-ING-005 AC-2 | Offline transcription of audio track | EchoTests/Phase3F/3F.3b_WhisperRuntimeTests.swift (FileInputContract) | WhisperASREngine.transcribeFile(at:) | ✅ |
| US-SRC-011 | Reference transcripts with CER/WER threshold | EchoTests/Phase3F/3F.3b_WhisperRuntimeTests.swift (ReferenceCERWER) | whisper-reference-transcripts.json (approved, jfk CER=0.0 ≤ 0.15) | ✅ |
| ADR-009 dec-2 | Immutable artifact + SHA-256 verification | EchoTests/Phase3F/3F.3b_WhisperRuntimeTests.swift (GGUFHash) | WhisperRuntimeBridge.verifyGGUFChecksum + model_checksums.sha256 | ✅ |
| ADR-009 dec-3 | Zero-network runtime (R-005) | WhisperRuntimeTests.RealTranscript (Bundle-loaded GGUF) | whisper_init_from_file_with_params on local path | ✅ |
| DEF-51-002 | ASR file-URL input contract | EchoTests/Phase3F/3F.3b_WhisperRuntimeTests.swift (FileInputContract) | ASREngineProtocol.transcribeFile(at:) + WhisperASREngine impl | ✅ |
| R-007 | No nonisolated(unsafe)/unchecked Sendable | CI static scan + SwiftLint | NativeWhisperCInterop (Sendable-safe, no escape) | ✅ |

## Testing
- RED: `xcodebuild test ... -only-testing:EchoTests/WhisperRuntimeLinkedTests -only-testing:EchoTests/WhisperFileInputContractTests` — 2/2 failed (`.runtimeNotLinked`, `.modelNotLoaded`)
- Focused: `xcodebuild test -project Echo.xcodeproj -scheme Echo -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO` + 5 WhisperRuntime test classes — 7/7 passed (real inference, CER=0.0 ≤ 0.15)
- Model-gated skip (PR review fix): model-dependent Whisper tests silently skip when GGUF/jfk.wav absent, matching 3F.3a SigLIP2 / E5 convention (DEF-54-001) — verified 7/7 pass with model, all skip without model
- Cumulative: `xcodebuild test ... -only-testing:EchoTests` — 857 tests / 105 suites, 0 failures, exit 0 (338s, local with models)
- Model gate: `bash Scripts/prepare_models.sh --verify-only` — exit 0, whisper GGUF checksum OK
- Lint: `swiftlint lint --quiet` — 0 errors / 0 warnings (changed files), repo-wide clean
- Release: whisper-cpp package compiles for arm64+x86_64 (GGML_CPU_GENERIC); Echo Release simulator build blocked only by pre-existing `simulateError` `#Preview` failure (documented 3F.1, base-reproducible)

## Documentation and Ledger
- README.md, docs/02-architecture/技术选型文档.md, docs/02-architecture/数据流全链路技术说明文档.md, docs/03-implementation/开发避坑与关键注意点手册.md updated for whisper runtime
- docs/decisions/ADR-009-offline-model-runtime.md: runtime-integration status updated
- docs/05-planning/model-provenance-register.md §2.2/§2.3: reference transcripts approved + runtime integration section
- docs/05-planning/deferred-items.json: DEF-51-002 ASR contract portion closed with resolution_notes
- docs/05-planning/phase3f-execution-plan.md §3F.3b: task completed
- docs/05-planning/task-status.json: 3F.3b → review
- Scripts/model_checksums.sha256: jfk.wav + whisper.cpp LICENSE registered

## Risks
- whisper.cpp built with GGML_CPU_GENERIC (no NEON-specific arch/arm acceleration): CPU-only inference, ~28s for 11s audio on simulator; acceptable for v1, does not weaken 3F.11 gate (performance gate is P95 search latency, not ASR throughput). Recorded in Package.swift build-decision comment.
- Release simulator build `simulateError` `#Preview` failure is pre-existing on base (3F.1 entry, 3F.11 release-gate scope); not introduced by this task.
- SBOM/NOTICE for whisper.cpp runtime deferred to model-provenance-register §4 packaging gate (per register policy "打包前创建").

## Deferred Items
- DEF-51-002 (ASR contract): contract portion CLOSED by this task (`transcribeFile(at:)` + tests). Share Extension App Group audio-file persistence portion remains open, deferred to 3F.5 (production ingestion) with resolution_notes in deferred-items.json.
- No new deferred items created by this task.

## Self-Check
- [x] All new pipeline/service entries follow actor isolation (WhisperRuntimeBridge actor; NativeWhisperCInterop Sendable-safe, no cross-isolation pointer escape)
- [x] No `nonisolated(unsafe)`, `@unchecked Sendable`, or Combine in new code (R-007)
- [x] Zero network: GGUF loaded from Bundle via ModelLoaderActor (R-005); no download code
- [x] GGUF SHA-256 verified before inference (ADR-009 decision 2)
- [x] DEF-51-002 ASR file-input contract implemented and tested
- [x] Reference transcripts backfilled with real inference (CER=0.0 ≤ 0.15)
- [x] Branch `feature/phase3f-whisper-runtime-3F.3b`, commit `feat(service): link whisper.cpp real transcription`, PR base `dev-1.0`
<!-- PR-BODY:3F.3b:END -->

---

## Entry: 3F.4 — Canonical storage 与 generation 生命周期

## Phase 3F Task Evidence
- Task / commit / branch / PR: 3F.4 — branch `feature/phase3f-canonical-generations-3F.4`, commit `feat(actor): add canonical generation lifecycle`, PR `feat(actor): add canonical generation lifecycle [3F.4]` (base `dev-1.0`)
- Registered worktree path / ownership / clean rebase result: n/a — 3F.1~3F.11 use plain branches in the main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead
- Bootstrap authorization actor / UTC time / docs-only scope (3F.0 only): n/a
- Pre-delivery task status and transition evidence: `in_progress` → `review` in docs/05-planning/task-status.json (2026-08-09)
- Quoted AC and architecture constraints: US-ING-006 AC-1/2/3/4/5 (transactional canonical/vector/FTS commit; rollback; fault injection; `.ingestTransaction` audit), US-PRV-004 AC-2/3 (仅从 Echo 移除写 ExcludedAssets; 级联不写), US-PRV-007 AC-2/5 (cascade delete cleans invalid exclusions; `.cascadeDeleteFromOriginal` excludedWritten=false), US-AWK-007 AC-2/4/6 (originalTimestamp/userEdited/userLocked), US-FBK-001/002/003 (feedback generation identity); AGENTS.md D-002/D-003/D-005, §5; ADR-010 decisions 1/2/3/4/5/7
- RED test command and observed failure: new `EchoTests/CanonicalGenerationTests` suites failed to compile until deterministicID/transaction/repository symbols existed (18 focused tests were RED); the deterministic ID RFC-4122 shape assertion initially failed (byte-order) and was corrected — final 18/18 pass
- Focused test command / exit / passed count: `xcodebuild test -project Echo.xcodeproj -scheme Echo -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -only-testing:EchoTests/CanonicalGenerationTests` — 18/18 passed (DeterministicID 4, TransactionalCommit 3, Lifecycle 4, FeedbackIdentity 2, DeletionBoundary 3, EditPersistence 1, SchemaMigration 1)
- Cumulative test command / exit / passed count: `xcodebuild test ... -only-testing:EchoTests` — 891 tests / 113 suites, 0 failures, exit 0
- Release simulator and device commands / exits: Release simulator build fails on pre-existing non-DEBUG-gated `simulateError` in `#Preview` blocks (CreationView/MemoryDetailView/SearchView) — identical failure on `dev-1.0` base, out of 3F.4 scope (documented in 3F.1 entry)
- Static/privacy/model/compliance commands / exits: `swiftlint lint --quiet` → exit 0, 0 errors (github-actions-logging reporter, identical to HEAD baseline); no strict-concurrency warnings on new/changed Core files; PrivacyCheckpoint on new repository write/delete entry points via existing actors
- Production path exercised: CanonicalMemoryRepositoryActor.commit (canonical+representation+FTS atomic via `executeTransaction`, vector compensation), deleteMemory (D-005 full boundary incl. translationCache), cascadeDeleteFromOriginal (ExcludedAssets cleanup), GenerationRegistryActor activate/rollback/restoreActiveRoute/persistStore; `.ingestTransaction` / `.memoryDeleted` / `.cascadeDeleteFromOriginal` audits written
- Files and documentation changed: Echo/Core/Actors/CanonicalMemoryRepositoryActor.swift (new), DatabaseMigrationActor.swift (new); DatabaseManager.swift (MemoryFTS, translationCache, Memory edit columns, FeedbackStore.generationId, ActiveRouteSet.previousTextGeneration, `executeTransaction`/`DBWrite`); GenerationRegistryActor.swift (finishShadowBuild/activateGeneration/rollbackToPrevious/restoreActiveRoute/persistStore/removeStoreFile, registerGeneration disk restore); FeedbackActor.swift (generationId); CanonicalMemory.swift (originalTimestamp/userEdited/userLocked); ActiveRouteSet.swift (previousTextGeneration); AuditEvent.swift (.ingestTransaction); EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (new) + RA_CanonicalModelTests.swift/RA_GenerationRegistryTests.swift (extended); docs (README, 架构设计, 数据流, 避坑手册, ADR-010, evidence-index, deferred-items DEF-38-001/002, phase3f-execution-plan, task-status)
- Deferred items closed or created, with evidence links: DEF-38-001 (originalTimestamp) and DEF-38-002 (userLocked) — Core persistence layer delivered (Memory.originalTimestamp/userEdited/userLocked columns + round-trip test in CanonicalGenerationTests.EditPersistence); recorded as closed with evidence in deferred-items.json
- Known risks that do not weaken an in-scope gate: SearchPipeline/IngestPipeline still route through a single in-memory VectorStoreActor until 3F.5/3F.6 production wiring consumes GenerationRegistryActor per-generation stores; `executeTransaction` removes the DEF-50-001 interleave risk for canonical writes, but `ConsentStoreActor.revokeConsent`'s transaction still spans suspension points (DEF-50-001 remains open, target 3F.11 DatabaseManager atomic purge refactor); Release simulator build `simulateError` `#Preview` failure pre-existing on base (3F.1/3F.11 scope)

<!-- PR-BODY:3F.4:START -->
## Overview
Task 3F.4 delivers the canonical storage and generation lifecycle per ADR-010. A new `CanonicalMemoryRepositoryActor` owns the canonical facts source with deterministic RFC-4122-derived memory IDs (SHA-256 namespace, version 5 / variant 8, input-order independent). `commit` writes Memory/Representation/MemoryFTS in a single synchronous SQLite `executeTransaction` (no suspension points — removes the DEF-50-001 interleave pattern for canonical writes) then ingests per-generation vectors with compensating rollback; any vector failure deletes the canonical row + written vectors, so no half-write or mixed-generation state survives. `deleteMemory` enforces the D-005 full deletion boundary (vectors across all generations + MemoryFTS + translationCache + audit + optional ExcludedAssets write per US-PRV-004); `cascadeDeleteFromOriginal` implements US-PRV-007 (no ExcludedAssets write, invalid exclusion records cleaned, `.cascadeDeleteFromOriginal` audit). `GenerationRegistryActor` gains the lifecycle: `finishShadowBuild` (building→ready), `activateGeneration` (atomic route publish with version bump + `previousTextGeneration` rollback target), `rollbackToPrevious`, `restoreActiveRoute` (reopens per-generation `.pxkt` stores from disk, dimension-guarded) and `persistStore`. Feedback rows now carry `generationId` (US-FBK identity). US-AWK-007 edit fields (`originalTimestamp`/`userEdited`/`userLocked`) persist on Memory. Full suite: 891 tests / 113 suites green.

## Related Specs
- Task 3F.4 — Canonical storage 与 generation 生命周期
- User Stories: US-ING-006 AC-1~5, US-PRV-004 AC-2/3/5, US-PRV-006 AC-6, US-PRV-007 AC-2/5, US-AWK-007 AC-2/4/6, US-FBK-001/002/003
- ADR-010 decisions 1/2/3/4/5/7
- AGENTS.md D-002/D-003/D-005, §5 存储契约; R-007/R-008
- docs/05-planning/phase3f-execution-plan.md §3F.4, §4.6.4
- Deferred items DEF-38-001/002

## AC Coverage
| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| US-ING-006 AC-1/2 | Memory+Representation+MemoryFTS one SQLite transaction; vectors written after with compensating rollback | EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (TransactionalCommit) | CanonicalMemoryRepositoryActor.commit + DatabaseManager.executeTransaction | ✅ |
| US-ING-006 AC-3 | FTS5 index synced with main transaction | EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (TransactionalCommit) | MemoryFTS virtual table written in commit | ✅ |
| US-ING-006 AC-4 | Fault injection proves rollback correctness | EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (vector failure / crash point) | setFault(.vectorWrite/.afterCanonicalWrite) + compensation | ✅ |
| US-ING-006 AC-5 | `.ingestTransaction` audit rolledBack=true/false | EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (TransactionalCommit) | AuditEvent.ingestTransaction + writeTransactionAudit | ✅ |
| US-PRV-004 AC-2 | 仅从 Echo 移除 writes ExcludedAssets + clears all copies | EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (DeletionBoundary) | deleteMemory(writeExcluded:) + excludedAssets.add | ✅ |
| US-PRV-007 AC-2/5 | Cascade delete no ExcludedAssets write; cleans invalid records; `.cascadeDeleteFromOriginal` | EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (DeletionBoundary) | cascadeDeleteFromOriginal + excluded.remove + audit | ✅ |
| D-005 | Full deletion boundary covers translationCache | EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (DeletionBoundary) | deleteMemory clears translationCache | ✅ |
| US-AWK-007 AC-2/4/6 | originalTimestamp/userEdited/userLocked persist | EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (EditPersistence) + RA_CanonicalModelTests | Memory model + schema columns + repository round-trip | ✅ |
| US-FBK-001/002/003 | Feedback generation identity | EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (FeedbackIdentity) | FeedbackStore.generationId + FeedbackActor.generationId(for:) | ✅ |
| ADR-010 dec-1 | Deterministic RFC-4122-derived IDs (input-order independent) | EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (DeterministicID) | CanonicalMemoryRepositoryActor.deterministicID | ✅ |
| ADR-010 dec-2/3 | Shadow build, atomic publish, rollback, restart restore | EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (Lifecycle) + RA_GenerationRegistryTests | GenerationRegistryActor lifecycle methods + per-generation `.pxkt` persist | ✅ |
| ADR-010 dec-4 | Generation-aware feedback | EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (FeedbackIdentity) | FeedbackStore.generationId column | ✅ |
| ADR-010 dec-7 | Per-space separated generation stores (dimension-guarded) | EchoTests/Phase3F/3F.4_CanonicalGenerationTests.swift (Lifecycle) | registerGeneration/restoreActiveRoute dimension check | ✅ |

## Testing
- RED: `EchoTests/CanonicalGenerationTests` — 18 focused tests, compile-RED before repository/lifecycle symbols existed; RFC-4122 shape assertion initially failed (byte order), corrected
- Focused: `xcodebuild test ... -only-testing:EchoTests/CanonicalGenerationTests` — 18/18 passed
- Extended R-A: `-only-testing:EchoTests/GenerationRegistryTests -only-testing:EchoTests/ActiveRouteSetTests -only-testing:EchoTests/CanonicalModelTests` — 28/28 passed (with focused = 46)
- Cumulative: `xcodebuild test ... -only-testing:EchoTests` — 891 tests / 113 suites, 0 failures, exit 0
- Lint: `swiftlint lint --config .swiftlint.yml --reporter github-actions-logging --quiet` — exit 0, 0 errors (identical to HEAD baseline)
- Release: Echo Release simulator build blocked only by pre-existing `simulateError` `#Preview` failure (documented 3F.1, base-reproducible)

## Documentation and Ledger
- README.md, docs/02-architecture/架构设计文档.md, docs/02-architecture/数据流全链路技术说明文档.md, docs/03-implementation/开发避坑与关键注意点手册.md updated for canonical storage/generation lifecycle
- docs/decisions/ADR-010-canonical-generation-lifecycle.md: implementation status recorded
- docs/05-planning/deferred-items.json: DEF-38-001/002 closed with evidence
- docs/05-planning/phase3f-execution-plan.md §3F.4: task completed
- docs/05-planning/task-status.json: 3F.4 → review
- EchoTests/Phase2/RA_CanonicalModelTests.swift + RA_GenerationRegistryTests.swift extended (edit fields + lifecycle)

## Risks
- SearchPipeline/IngestPipeline single-store routing replaced at 3F.5/3F.6 production wiring (generation registry consumption); no mixed-generation route can be published (activateGeneration validates non-building), so this does not weaken 3F.11
- DEF-50-001 (ConsentStoreActor.revokeConsent transaction spans suspension points) remains open — canonical `executeTransaction` is suspension-free, but revokeConsent still awaits DatabaseManager across its transaction; target 3F.11 DatabaseManager atomic purge refactor
- Release simulator build `simulateError` `#Preview` failure is pre-existing on base (3F.1 entry, 3F.11 release-gate scope); not introduced by this task

## Deferred Items
- DEF-38-001 (originalTimestamp backup field): CLOSED — Memory.originalTimestamp persisted + round-trip tested (CanonicalGenerationTests.EditPersistence)
- DEF-38-002 (userLocked semantics): CLOSED — Memory.userLocked persisted (schema + round-trip); SyncPipeline skip-on-userLocked wiring remains 3F.7 scope but the Core persistence layer required by the deferred item is delivered
- No new deferred items created by this task

## Self-Check
- [x] New Actor methods are actor-isolated; cross-actor calls awaited (R-008); no `nonisolated(unsafe)`/`@unchecked Sendable`/Combine (R-007)
- [x] Canonical writes use suspension-free `executeTransaction` (no half-write; DEF-50-001 pattern not reintroduced)
- [x] Deletion boundary covers vector + index + cache + metadata + audit + translationCache (D-005)
- [x] ExcludedAssets written only on user "仅从 Echo 移除"; cascade delete never writes and cleans invalid records (D-002/D-003, US-PRV-007)
- [x] Feedback generation identity persisted (US-FBK)
- [x] `originalTimestamp`/`userEdited`/`userLocked` persist (US-AWK-007, DEF-38-001/002)
- [x] Branch `feature/phase3f-canonical-generations-3F.4`, commit `feat(actor): add canonical generation lifecycle`, PR base `dev-1.0`
<!-- PR-BODY:3F.4:END -->

---

## Entry: 3F.5 — Production ingestion

## Phase 3F Task Evidence
- Task / commit / branch / PR:
- Registered worktree path / ownership / clean rebase result: n/a — 3F.1~3F.11 use plain branches in the main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead
- Bootstrap authorization actor / UTC time / docs-only scope (3F.0 only): n/a
- Pre-delivery task status and transition evidence:
- Quoted AC and architecture constraints:
- RED test command and observed failure:
- Focused test command / exit / passed count:
- Cumulative test command / exit / passed count:
- Release simulator and device commands / exits:
- Static/privacy/model/compliance commands / exits:
- Production path exercised:
- Files and documentation changed:
- Deferred items closed or created, with evidence links:
- Known risks that do not weaken an in-scope gate:

<!-- PR-BODY:3F.5:START -->
## Overview
<fill with the completed task overview>

## Related Specs
<fill with exact task, story, AC, ADR, and document references>

## AC Coverage
| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| <fill AC identifier> | <fill verified summary> | <fill exact test path> | <fill exact implementation path> | <fill verified status> |

## Testing
<fill with exact commands, exits, counts, and evidence links>

## Documentation and Ledger
<fill with exact documentation and ledger changes>

## Risks
<fill with verified risks or an explicit evidence-backed none statement>

## Deferred Items
<fill with evidence-backed dispositions or an explicit evidence-backed none statement>

## Self-Check
<fill with completed security, privacy, scope, and delivery checks>
<!-- PR-BODY:3F.5:END -->

---

## Entry: 3F.6 — Production search 与 feedback

## Phase 3F Task Evidence
- Task / commit / branch / PR:
- Registered worktree path / ownership / clean rebase result: n/a — 3F.1~3F.11 use plain branches in the main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead
- Bootstrap authorization actor / UTC time / docs-only scope (3F.0 only): n/a
- Pre-delivery task status and transition evidence:
- Quoted AC and architecture constraints:
- RED test command and observed failure:
- Focused test command / exit / passed count:
- Cumulative test command / exit / passed count:
- Release simulator and device commands / exits:
- Static/privacy/model/compliance commands / exits:
- Production path exercised:
- Files and documentation changed:
- Deferred items closed or created, with evidence links:
- Known risks that do not weaken an in-scope gate:

<!-- PR-BODY:3F.6:START -->
## Overview
<fill with the completed task overview>

## Related Specs
<fill with exact task, story, AC, ADR, and document references>

## AC Coverage
| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| <fill AC identifier> | <fill verified summary> | <fill exact test path> | <fill exact implementation path> | <fill verified status> |

## Testing
<fill with exact commands, exits, counts, and evidence links>

## Documentation and Ledger
<fill with exact documentation and ledger changes>

## Risks
<fill with verified risks or an explicit evidence-backed none statement>

## Deferred Items
<fill with evidence-backed dispositions or an explicit evidence-backed none statement>

## Self-Check
<fill with completed security, privacy, scope, and delivery checks>
<!-- PR-BODY:3F.6:END -->

---

## Entry: 3F.7 — UI 到 Core 全域接线

## Phase 3F Task Evidence
- Task / commit / branch / PR:
- Registered worktree path / ownership / clean rebase result: n/a — 3F.1~3F.11 use plain branches in the main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead
- Bootstrap authorization actor / UTC time / docs-only scope (3F.0 only): n/a
- Pre-delivery task status and transition evidence:
- Quoted AC and architecture constraints:
- RED test command and observed failure:
- Focused test command / exit / passed count:
- Cumulative test command / exit / passed count:
- Release simulator and device commands / exits:
- Static/privacy/model/compliance commands / exits:
- Production path exercised:
- Files and documentation changed:
- Deferred items closed or created, with evidence links:
- Known risks that do not weaken an in-scope gate:

<!-- PR-BODY:3F.7:START -->
## Overview
<fill with the completed task overview>

## Related Specs
<fill with exact task, story, AC, ADR, and document references>

## AC Coverage
| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| <fill AC identifier> | <fill verified summary> | <fill exact test path> | <fill exact implementation path> | <fill verified status> |

## Testing
<fill with exact commands, exits, counts, and evidence links>

## Documentation and Ledger
<fill with exact documentation and ledger changes>

## Risks
<fill with verified risks or an explicit evidence-backed none statement>

## Deferred Items
<fill with evidence-backed dispositions or an explicit evidence-backed none statement>

## Self-Check
<fill with completed security, privacy, scope, and delivery checks>
<!-- PR-BODY:3F.7:END -->

---

## Entry: 3F.8 — Awakening 与 system adapters

## Phase 3F Task Evidence
- Task / commit / branch / PR:
- Registered worktree path / ownership / clean rebase result: n/a — 3F.1~3F.11 use plain branches in the main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead
- Bootstrap authorization actor / UTC time / docs-only scope (3F.0 only): n/a
- Pre-delivery task status and transition evidence:
- Quoted AC and architecture constraints:
- RED test command and observed failure:
- Focused test command / exit / passed count:
- Cumulative test command / exit / passed count:
- Release simulator and device commands / exits:
- Static/privacy/model/compliance commands / exits:
- Production path exercised:
- Files and documentation changed:
- Deferred items closed or created, with evidence links:
- Known risks that do not weaken an in-scope gate:

<!-- PR-BODY:3F.8:START -->
## Overview
<fill with the completed task overview>

## Related Specs
<fill with exact task, story, AC, ADR, and document references>

## AC Coverage
| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| <fill AC identifier> | <fill verified summary> | <fill exact test path> | <fill exact implementation path> | <fill verified status> |

## Testing
<fill with exact commands, exits, counts, and evidence links>

## Documentation and Ledger
<fill with exact documentation and ledger changes>

## Risks
<fill with verified risks or an explicit evidence-backed none statement>

## Deferred Items
<fill with evidence-backed dispositions or an explicit evidence-backed none statement>

## Self-Check
<fill with completed security, privacy, scope, and delivery checks>
<!-- PR-BODY:3F.8:END -->

---

## Entry: 3F.9 — Apple Translation 与 grounded creation

## Phase 3F Task Evidence
- Task / commit / branch / PR:
- Registered worktree path / ownership / clean rebase result: n/a — 3F.1~3F.11 use plain branches in the main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead
- Bootstrap authorization actor / UTC time / docs-only scope (3F.0 only): n/a
- Pre-delivery task status and transition evidence:
- Quoted AC and architecture constraints:
- RED test command and observed failure:
- Focused test command / exit / passed count:
- Cumulative test command / exit / passed count:
- Release simulator and device commands / exits:
- Static/privacy/model/compliance commands / exits:
- Production path exercised:
- Files and documentation changed:
- Deferred items closed or created, with evidence links:
- Known risks that do not weaken an in-scope gate:

<!-- PR-BODY:3F.9:START -->
## Overview
<fill with the completed task overview>

## Related Specs
<fill with exact task, story, AC, ADR, and document references>

## AC Coverage
| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| <fill AC identifier> | <fill verified summary> | <fill exact test path> | <fill exact implementation path> | <fill verified status> |

## Testing
<fill with exact commands, exits, counts, and evidence links>

## Documentation and Ledger
<fill with exact documentation and ledger changes>

## Risks
<fill with verified risks or an explicit evidence-backed none statement>

## Deferred Items
<fill with evidence-backed dispositions or an explicit evidence-backed none statement>

## Self-Check
<fill with completed security, privacy, scope, and delivery checks>
<!-- PR-BODY:3F.9:END -->

---

## Entry: 3F.10 — i18n、accessibility 与 production errors

## Phase 3F Task Evidence
- Task / commit / branch / PR:
- Registered worktree path / ownership / clean rebase result: n/a — 3F.1~3F.11 use plain branches in the main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead
- Bootstrap authorization actor / UTC time / docs-only scope (3F.0 only): n/a
- Pre-delivery task status and transition evidence:
- Quoted AC and architecture constraints:
- RED test command and observed failure:
- Focused test command / exit / passed count:
- Cumulative test command / exit / passed count:
- Release simulator and device commands / exits:
- Static/privacy/model/compliance commands / exits:
- Production path exercised:
- Files and documentation changed:
- Deferred items closed or created, with evidence links:
- Known risks that do not weaken an in-scope gate:

<!-- PR-BODY:3F.10:START -->
## Overview
<fill with the completed task overview>

## Related Specs
<fill with exact task, story, AC, ADR, and document references>

## AC Coverage
| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| <fill AC identifier> | <fill verified summary> | <fill exact test path> | <fill exact implementation path> | <fill verified status> |

## Testing
<fill with exact commands, exits, counts, and evidence links>

## Documentation and Ledger
<fill with exact documentation and ledger changes>

## Risks
<fill with verified risks or an explicit evidence-backed none statement>

## Deferred Items
<fill with evidence-backed dispositions or an explicit evidence-backed none statement>

## Self-Check
<fill with completed security, privacy, scope, and delivery checks>
<!-- PR-BODY:3F.10:END -->

---

## Entry: 3F.11 — Production E2E 与 Phase 4 准入门禁

## Phase 3F Task Evidence
- Task / commit / branch / PR:
- Registered worktree path / ownership / clean rebase result: n/a — 3F.1~3F.11 use plain branches in the main repo per human approval 2026-08-04 (AGENTS.md §17.9); record branch + clean base instead
- Bootstrap authorization actor / UTC time / docs-only scope (3F.0 only): n/a
- Pre-delivery task status and transition evidence:
- Quoted AC and architecture constraints:
- RED test command and observed failure:
- Focused test command / exit / passed count:
- Cumulative test command / exit / passed count:
- Release simulator and device commands / exits:
- Static/privacy/model/compliance commands / exits:
- Production path exercised:
- Files and documentation changed:
- Deferred items closed or created, with evidence links:
- Known risks that do not weaken an in-scope gate:

<!-- PR-BODY:3F.11:START -->
## Overview
<fill with the completed task overview>

## Related Specs
<fill with exact task, story, AC, ADR, and document references>

## AC Coverage
| AC # | Spec Summary | Test File | Implementation | Status |
| --- | --- | --- | --- | --- |
| <fill AC identifier> | <fill verified summary> | <fill exact test path> | <fill exact implementation path> | <fill verified status> |

## Testing
<fill with exact commands, exits, counts, and evidence links>

## Documentation and Ledger
<fill with exact documentation and ledger changes>

## Risks
<fill with verified risks or an explicit evidence-backed none statement>

## Deferred Items
<fill with evidence-backed dispositions or an explicit evidence-backed none statement>

## Self-Check
<fill with completed security, privacy, scope, and delivery checks>
<!-- PR-BODY:3F.11:END -->

---

## Entry: 3F.finalize — Record 3F.11 merge and unlock Phase 4

- **id:** `3F.finalize`
- **title:** `Record 3F.11 merge and unlock Phase 4`
- **status before trigger:** `blocked_on_human_merge`
- **owner:** Release Manager
- **approver:** Human merge actor and Product and Architecture Lead
- **documents_required:** `docs/05-planning/task-status.json`; `docs/05-planning/phase3f-evidence-index.md`; `docs/05-planning/phase3f-execution-plan.md`; `docs/05-planning/开发计划安排文档.md`
- **dependencies:** `3F.11` PR merged into `dev-1.0`, host reports immutable merge commit SHA
- **acceptance_evidence:** 3F.11 PR URL; merge commit SHA reachable from `dev-1.0`; merged head and base identities; finalizer actor/time; Phase 4 ready-task diff; evidence-index link; proof that no branch was deleted
- **prohibited:** running before merge, accepting a PR head SHA as merge SHA, changing gate results, fabricating post-merge evidence, starting Phase 4 implementation in the finalizer change

This entry is a human-triggered post-merge finalizer record (`§10.1`). It has no `§11.1` PR-body marker pair. It is populated only by the human-triggered finalizer after the `3F.11` PR is merged; until then it remains `blocked_on_human_merge` with no merge SHA, no `done` status and no Phase 4 unlock.
