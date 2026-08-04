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
- Invariant review of the diff: 72 unique task ids, every dependency exists, dependency graph acyclic, phase previous/next links consistent, integration task ids resolve, Phase 4 fully `backlog` and locked behind `3F.11`, migration records present (`4.20→3F.2`, `4.21/4.22→3F.3`, `4.12/4.13/4.23/4.24/4.25→5.6..5.10`, `5.5→5.11`), story matrix gate 66/66.
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
- Cumulative test command / exit / passed count: `xcodebuild test ... -only-testing:EchoTests` — 753 tests / 85 suites, 0 failures, exit 0
- Release simulator and device commands / exits: Release simulator build fails on pre-existing non-DEBUG-gated `simulateError` in `#Preview` blocks (CreationView/MemoryDetailView/SearchView) — identical failure on `dev-1.0` base, out of 3F.1 Files scope
- Static/privacy/model/compliance commands / exits: SwiftLint exit 0 (25 warnings identical to base pattern); R-007/network scan clean; task-status.json + deferred-items.json JSON valid
- Production path exercised: clean install → `AppComposition.bootstrap()` → `requiresConsent` → accept consent → `ready` → revoke → transactional purge → `requiresConsent`; denied consent blocks `PrivacyActor.validate` (PrivacyCheckpoint `.denied`)
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

<!-- PR-BODY:3F.2:START -->
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
<!-- PR-BODY:3F.2:END -->

---

## Entry: 3F.3 — E5、SigLIP2、Whisper 与离线生成决策落地

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

<!-- PR-BODY:3F.3:START -->
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
<!-- PR-BODY:3F.3:END -->

---

## Entry: 3F.4 — Canonical storage 与 generation 生命周期

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

<!-- PR-BODY:3F.4:START -->
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
