# Changelog

All notable changes to the Echo project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added (Phase 3F — Feature completion and production integration)

- **Production composition and consent (3F.1)**: AppComposition composition root,
  deny-by-default consent (ConsentStoreActor), transactional revoke/purge
  (PurgeBoundary), explicit startup states (requiresConsent / ready /
  modelUnavailable / routeUnavailable / indexUnavailable / purgeBlocked /
  bootstrapFailed), hash-only audit logs with 30-day cleanup and
  NSFileProtectionComplete.
- **Real data sources (3F.2)**: PhotoKitSourceAdapter with limited-library
  picker flow, PhotoKitChangeObserver, EchoShareExtension (Share Sheet) with
  App Group envelope queue (group.com.echo.Echo), dedupe and exactly-once
  consumption.
- **Offline model inference (3F.3 / 3F.3a / 3F.3b)**: multilingual-e5-small
  real 384d text embeddings (Unigram tokenizer + Core ML), SigLIP2
  preprocessing and conversion lineage (reference-vector cosine > 0.995),
  whisper.cpp v1.9.2 runtime with GGUF SHA-256 verification, LanguageAligner
  (R-004 single-retry language alignment).
- **Canonical storage and generation lifecycle (3F.4)**: CanonicalMemoryRepositoryActor
  (deterministic IDs, transactional CRUD, cascade delete), GenerationRegistryActor
  (shadow build / atomic publish / rollback / restart recovery / per-generation
  .pxkt persistence), feedback generation identity.
- **Production ingestion (3F.5)**: IngestPipeline.ingestProductionPhoto/Video/
  SharedText/SharedAudio writing canonical + per-generation vectors + FTS in one
  transaction, TaskQueueActor serial queue with ProgressActor resume, SyncPipeline
  production replace/delete routing.
- **Production search and feedback (3F.6)**: multi-channel generation-routed
  search (text_dense / vision_dense / ocr_text / lexical) with RRF fusion,
  channel timeouts and partial results (US-RET-008), policy-aware result cache
  (US-RET-007), follow-up query tracking (US-RET-005), query-conditioned
  feedback re-ranking, cross-app intent parsing and temporal fusion (US-SRC-010),
  bounded subjective re-ranking (US-SRC-011).
- **UI to Core wiring (3F.7)**: DataOverviewService (US-SRC-009), ECHOMIG1
  encrypted device-migration package (AES-GCM-256 + HKDF-SHA256, RFC 8785 JCS
  manifest), LiveAppAdapters wiring the default app to real Core services.
- **Awakening and system adapters (3F.8)**: CoreLocationProvider (geofencing),
  HealthKitSystemProvider (minimized samples, denied sources not queried),
  LocalNotificationAdapter + NotificationResponseRouter, AwakeningCardRepositoryActor
  (SQLite persistence + restart dedupe).
- **Apple Translation and grounded creation (3F.9)**: AppleTranslationService
  with LanguageAvailability checks, PersistentTranslationCache (TTL 7d across
  relaunch), TerminologyTable, CreativePipeline grounded generation with
  provenance anchors, CreationExportService (Markdown / PDF / system share).
- **i18n, accessibility and production errors (3F.10)**: LanguageCenter unified
  language switch (UI + AI), Localizable.xcstrings bilingual catalog
  (336 keys, 100% zh-Hans/en-US parity), L1~L4 error classification with
  localized copy, SystemMonitor low-power/thermal degradation wiring, VoiceOver
  announcements.
- **Release compliance (3F.11)**: per-target release compliance validator
  (Scripts/validate_release_compliance.py) covering Echo and EchoShareExtension
  networking / linked-SDK / secret / entitlement / privacy-manifest /
  required-reason API / purpose-string findings, PrivacyInfo.xcprivacy manifests,
  Release.xcconfig, no-fixture production E2E, phase 3F integration suite.

### Changed

- UI layer reorganized into feature domains (AppShell, Home, Search, Detail,
  Settings, Onboarding, Awakening, BackgroundTask, Creation, Degradation,
  ResumeProgress, Translation).
- Search upgraded from a single legacy vector store to generation-routed
  per-model index instances managed by GenerationRegistryActor.

### Removed

- personIds search filter (US-SRC-006 removed from v1.0 — PHAsset exposes no
  People identity labels; R-5.3 decision).
- Automatic/background access to Notes, Voice Memos and iMessage (iOS public
  API limitation; approved path is Photos + explicit Share Extension, R-5.2).

## [0.1.0] - 2026-07-04 (Phase 1 — Foundation)

- Xcode project with Swift 6 strict concurrency.
- ProximaKit 1.7 HNSW vector store wrapped in VectorStoreActor.
- SQLite schema: ExcludedAssets, Feedback, TaskProgress, PendingOperations,
  AuditLog, UserPolicyStore.
- Model bundle: MobileCLIP-B LT, multilingual-e5-small, SenseVoice.
- ModelLoaderActor manual load/retry.
- CI (GitHub Actions): SwiftLint, unit tests, coverage gate.
- PrivacyActor stub + UserPolicy.

[Unreleased]: https://github.com/logan-suu/Echo/compare/dev-1.0...HEAD
[0.1.0]: https://github.com/logan-suu/Echo/releases/tag/v0.1.0
