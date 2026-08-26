# App Store Privacy Disclosure

对应规格: docs/decisions/ADR-014-release-compliance-boundary.md §决策-4 (发布制品)
任务: 3F.11 - Production E2E 与 Phase 4 准入门禁
生成时间: 2026-08-12

Echo is a fully on-device AI memory assistant. All processing happens locally
on the user's device; no user data is ever uploaded, transmitted or shared.

## 1. Data Collection Disclosure (App Store Connect answers)

| App Store question | Answer |
| --- | --- |
| Does this app collect data? | No |
| Data collection across third parties | No data collected or shared |
| Data linked to user identity | None |
| Data used for tracking | No tracking |

**Collected data types:** None. `PrivacyInfo.xcprivacy` declares an empty
`NSPrivacyCollectedDataTypes` array for both the Echo app and the
EchoShareExtension.

**Rationale (R-001):** Echo's absolute red line is that no data ever leaves the
device. Photo/video/voice/text memories are indexed and searched entirely
on-device. The Share Extension writes shared content only into the app group
container (`group.com.echo.Echo`) for the host app to consume — it never
uploads anywhere.

## 2. Required-Reason API (NSPrivacyAccessedAPITypes)

| API category | Reason | Purpose |
| --- | --- | --- |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | Persist app preferences, settings and state (language, consent, auto-sync toggle) in the app's own UserDefaults. |

No file-timestamp, system-boot-time, disk-space or other required-reason API
categories are used by either target.

## 3. Permissions and Purpose Strings

| Permission | Info.plist purpose string |
| --- | --- |
| Photos (read) | "Echo reads your photos and videos on this device to build searchable memories. Everything stays on your device." |
| Photos (add) | "Echo never writes to your photo library." |
| Location (when in use) | "Echo uses your location to surface memories when you arrive at meaningful places. Location data never leaves your device." |
| Location (always + when in use) | "Echo uses your location to surface memories when you arrive at meaningful places, including in the background for geofence monitoring. Location data never leaves your device." |
| HealthKit (share) | "Echo reads heart rate variability samples to gently surface positive memories when you may feel low. Only minimized samples are used and never leave your device." |
| HealthKit (update) | "Echo never writes to your health data." |

## 4. Third-Party SDKs and Networking

- **No networking code** in either executable target (validated by
  `Scripts/validate_release_compliance.py` networking scan and CI static ban
  gate).
- **No analytics, crash-reporting, advertising or tracking SDKs.**
- **Local SPM dependencies:** ProximaKit (HNSW vector store, Apache-2.0) and
  whisper.cpp (vendored, MIT), both on-device only.
- **Models:** bundled in the app (multilingual-e5-small, SigLIP2, Whisper
  tiny); no runtime download.

## 5. External Privacy Policy

A human-facing privacy policy is published alongside the App Store listing
before release submission (Release Manager responsibility in 3F.11 gate). The
policy text must remain consistent with this disclosure: no data collection,
no third-party sharing, no tracking.
