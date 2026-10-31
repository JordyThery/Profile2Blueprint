# Profile2Blueprint: instructions for Claude

At the start of every conversation, run ../JTKit/Scripts/check-versions.sh (or fetch it from GitHub if ../JTKit isn’t there) and mention the result in one line if anything is out of date.

Shared code and the standards for every app: see JTKit’s CLAUDE.md and ROADMAP.md (github.com/JordyThery/JTKit, or ../JTKit in the workspace).

## What the app does

A macOS app for Jamf admins that migrates Jamf Pro classic configuration profiles (macOS and mobile device) into Jamf Platform Blueprints, using Apple’s in-place Classic → DDM transform. It grades each profile, maps its scope to platform device groups, creates the Blueprint, checks it against the server’s read-back (the fidelity check), deploys only after confirmation, and can optionally clear the classic profile’s scope afterwards. Demo Mode (JTKit) runs the whole flow without a tenant.

## How to work on it

- App-only work: open `Profile2Blueprint.xcodeproj`. This folder’s notes load and it builds against the published JTKit.
- Anything that changes JTKit: work in `~/Developer/Apps.xcworkspace`.
- Never have the app open in both at once.
- Build releases from the app’s own project, so they use the published JTKit version.
- After merging into main, push main to origin straight away (keep GitHub in sync).
- Jordy is not a programmer: explain changes in plain language, in small steps.

## Architecture

- `App/`: `AppModel` (tenants, current tenant, demo mode, builds JTKit’s client, owns one store per file and each tenant’s live `ClassicWriteSwitch`), `Workspace`, `MigrationSession` (one profile’s migration in the UI), `HistoryLog`, `ActivityEntries`, `DemoFiles`, `Log`.
- `Models/`: `Tenant` (with naming, description template, Jamf Pro links, classic-cleanup switch), `ClassicProfile`, `PlistValue` (order-preserving), `ProfilePlatform`, `EligibilityReport`, `MigrationRecord`, `Blueprint` (the create request), `APIError`, `LosslessJSON+App`.
- `Services/API/`: `RequestPolicy` (the app’s allow-list), `ClassicAPI`, `ClassicScopeWriter`.
- `Services/Migration/`: `PlistParser`, `ClassicXMLParser`, `PlistToJSON` (+ `PlistJSONComparator`), `ScopeMapper`, `EligibilityChecker`, `BlueprintBuilder`, `FidelityVerifier`, `MigrationPipeline` (actor, staged: fetch → validate → build → create → verify → deploy; stages must run in order), `ClassicScopeService` (+ `ScopeBackupStore`).
- `Services/Persistence/`: `TenantStore`, `HistoryStore`, `SessionStateStore`, `StoredList` (the unreadable-copy rule for the other three files). `Services/Auth/KeychainStore`: the Keychain location.
- `Features/`: Connect (toolbar picker, Settings tab), ProfileList, ProfileDetail, ScopeMapping, Review, Deploy, Batch, History, Shared.
- `Resources/Fixtures/`: `DemoFixtures` (Contoso’s Classic profiles, the app’s extra device group), `DemoClassicServer` (the Classic API behind JTKit’s demo Platform server, and `MigrationEnvironment.demo`).

From JTKit: `JamfPlatform.Client`, `JamfPlatform.TokenProvider`, `RequestRecorder`, Blueprints, device groups, deploy watch and `PollingPolicy`, `JamfPlatform.APIError` and `PermissionCheck`/`PermissionProblem`, `LosslessJSON`, `JamfRegion`, `JamfClassic` (paths, list unwrapping, privileges), `ConnectionStore` + `ConnectionPicker` + `ConnectionCommands`, `KeychainSecretStore`, `ActivityLog` + `ActivityLogWindow`, `SettingsWindow`, `AboutWindow`, `UpdateChecker`, `DemoMode` + `DemoModeToggle` + `DemoJamfPlatformServer` (demo mode). Test helpers come from `JTKitTestSupport`.

App-specific, stays here: the migration engine, eligibility and fidelity checks, Classic profile parsing, `ClassicScopeService` and its allow-list rule, History, the demo Classic profiles, the 30-minute report watch (`WatchPolicy`).

When something is needed that JTKit could share, extend JTKit instead of adding another copy here.

## Rules and decisions

- **Creating never deploys.** Deploy is a separate step with a confirmation listing groups and device count, refused when verification failed.
- **The allow-list (`RequestPolicy`) is the safety net.** Allowed: any GET; POST to create or deploy a Blueprint; a classic profile PUT whose XML has only `<scope>`, and only when the tenant’s classic-cleanup switch is on. Everything else (PATCH, DELETE, undeploy, group writes) is refused. Don’t widen it without Jordy.
- **Classic cleanup is guarded three times:** per-tenant `allowClassicScopeChanges` (off by default, with a confirmation; read live at every scope change through `ClassicWriteSwitch`), a per-profile opt-in, and a clean deploy report (0 failed, 0 pending). The automatic cleanup also needs `ScopeCoverage`: every classic scope target must be a group whose exact-name platform group is one of the Blueprint’s groups; otherwise it holds back and only a manual unscope (whose confirmation names the uncovered targets) can run. It runs at most once per profile (`ScopeBackupStore.hasScopeChange`), so a Restore is never undone. The original scope is backed up and can be restored; each backup records its write outcome (`ScopeWriteState`), and a pending one is settled by reading the profile.
- **In-place transform is the whole point.** Never adopt jamf-cli’s `--strip-defaults`, MCX rewrapping, native DDM conversion (`--convert`) or synthesized identifiers: each changes the payloads, so the takeover fails. Block the profile instead.
- **Sites: don’t build yet.** Until the public Blueprints API has a site field, possible small changes (only if asked): a site-filtered profile list, raising the `.site` finding from info to a warning, a README limitation line. `ClassicProfile.site` is already parsed.
- **Jamf School: not supported.** A Jamf School platform environment offers only Blueprints and device actions, no configuration-profiles or device-groups capability, so profiles can’t be read and a Blueprint can’t be scoped. Don’t build a Jamf School-native API path.
- **Local Jamf Pro accounts can’t work:** Blueprints exist only behind the Platform API gateway, which needs a Jamf Account integration.
- **Exclusions and limitations are not carried over**; the checker warns. jamf-cli shows exclusions could be carried as a step `activationPredicate` (`NONE @property(jamf.device.groups) IN {...}`) when the classic profile doesn’t exclude the same group; not built.
- **History stays in the app** (`history.json`); JTKit’s in-memory activity log is not a substitute. The old `activity.json` stays on disk untouched and unread.
- **Demo Mode** is JTKit’s switch (`DemoMode`, saved under `demoMode`), never a tenant. In the slot of JTKit’s connection picker and Connection menu only (no sidebar switch); "Try Demo Mode" on the No Tenant page. The client is built from JTKit’s demo connection "Contoso (Demo)" on JTKit’s demo network, with the app’s allow-list (scope-only Classic writes allowed); JTKit’s demo Platform server answers Blueprints and device groups, and routes `proclassic/…` to `DemoClassicServer`, so Classic reads and scope writes run the real `LiveClassicAPI`/`LiveClassicScopeWriter`. Demo history, scope backups and sessions go to `DemoMode.scratchDirectory`. The demo environment keeps no Environment ID, so a demo scope backup is matched by name and never restored on a real tenant (nor one named "Offline demo", the earlier name). Test Connection and Load Environments always use the real tenant and network. No unsaved-work question (sessions are saved per tenant). `-JTKitSandbox YES` keeps tenants, secrets, history, scope backups and sessions in the temporary folder and memory (`AppModel.sandbox(demo:)`), with no update check.
- **Preserve stored data:** Application Support/Profile2Blueprint/`tenants.json` (with `currentTenantID`), `sessions.json`, `history.json`, `scope-backups.json`; Keychain service `be.jordythery.profile2blueprint.oauth-client-secret`, account = tenant UUID; UserDefaults `demoMode`; saved region values.
- Request bodies are never recorded in the log (JTKit default): profiles can hold Wi-Fi passwords or SCEP challenges.

## Verified Jamf behavior

- Blueprint create takes only name, description, `scope.deviceGroups` and steps. The gateway answers 403 for any unknown path, so probing undocumented paths proves nothing.
- Assigning a site to an existing, undeployed migrated Blueprint in the Jamf Pro UI removed its payload component and target group (UI and API) and renamed the step to "Components in this blueprint".
- The API overwrites each payload’s `PayloadUUID` with its `PayloadIdentifier`, so a payload where the two differ is blocked. Top-level identity is stored as sent.
- Keys outside Apple’s schema are silently dropped and stop being enforced after takeover.
- The server rewrites some strings (CR/LF, trimmed edges, `&`/`<` escaped twice per Jamf PI-827, non-BMP characters); `PlistJSONComparator` tolerates exactly these.
- After cleanup, Jamf Pro logs a failed "Remove Configuration Profile" per device: expected, the Blueprint owns the profile now.
- Undeploying a Blueprint whose classic profile is gone removes the settings from devices. The app can’t undeploy.
- The Classic API works through the gateway with the environment-scoped token (`X-Environment-Id`). Profile lists are asked for as JSON (Jamf labels them `text/plain`); single profiles stay XML for the payload and the scope backup.
- The scope-only partial-XML PUT is verified live on macOS and mobile; the mobile takeover was verified on an iPhone.
- Payload-type tables (`EligibilityChecker`: blocked, supported, non-canonical) and the string-rewrite classes come from jamf-cli’s `internal/profileconvert`. They drift silently. When working on the app, compare with jamf-cli. If they changed, update the sets, `payloadTableProbeDate`, the user-facing text and the dates in WATCHLIST.md. The supported list is a warning only, never a blocker.

## Watchlist

What this app waits for from Apple, Jamf or Microsoft, or must recheck: see WATCHLIST.md.

## Testing

- Unit tests: Swift Testing in `Profile2BlueprintTests`, ⌘U in the app’s project. They use JTKit’s fake network (`MockURLProtocol`/`MockServer` from `JTKitTestSupport`); its handler is global, so suites that use it must be `.serialized`.
- The test target depends on the app. After a JTKit update, a link error from stale build files is fixed by a clean build (⇧⌘K).
- A test checks that the fidelity verdicts don’t depend on key order (source order, reversed, alphabetical). Keep it.
- Test data uses placeholders only (`example.jamfcloud.com`, regional `*.api.jamfcloud.com`, made-up IDs). Never a real tenant, hostname or Environment ID.
- Never run the long UI suites of Jamf Deployer or AppSettings2Blueprint unless Jordy asks for one by name.
- **UI tests** (`Profile2BlueprintUITests`, a macOS UI testing bundle, minimum macOS 14.0 like the app, uses `JTKitUITestSupport`): only `DemoSmokeUITests`, run by the release check through the "Profile2Blueprint Release Check" scheme. The app’s own scheme runs the unit tests only, so ⌘U never starts UI tests. Run a single UI test only when Jordy asks for it by name.
- **Release check** (ROADMAP step 11): `Scripts/release-check.sh` (scheme "Profile2Blueprint Release Check"; `--local-jtkit` before a JTKit version is tagged). Own-project build against the published JTKit and sign-in, unit tests, `DemoSmokeUITests` in demo mode (launch, About, Settings tabs, the connections editor adding and deleting a throwaway connection, migrating "Contoso – Security Baseline" with the scope screen asking which Design Macs, activity log, "— Demo" titles), live checks on jamf-test-a over the Platform API, report. Claude may run it unattended (nohup, poll). Tenants come only from the local allow-list outside git. Never name a tenant in this repo.
  - The app is sandboxed, so the test host reaches only its own container: the release check keeps the live folder (allow-list copy, ledger, results) in the container’s `tmp/JTKitReleaseCheck/`, readable by Jordy only (JTKit 0.12.2, `TEST_HOST_CONTAINER`). A crashed run’s folder is removed only after a later run has removed its objects.
  - Live checks (`LiveCheckTests.swift`, skipped on ⌘U), objects named `JTKTEST PB <run> – …`: an empty **static** Platform group (0 members checked before the Blueprint is made and again before deploying), an empty static Classic computer group (0 members checked), and a macOS profile with one Managed Preferences payload (made-up domain `com.example.jtktest`), created scoped to nothing, then scoped to the Classic group only. The test code makes these; the app has no create. The app’s own `Workspace` and `MigrationSession` (an in-memory tenant with classic scope changes on; history, scope backups and sessions in a temporary folder, never the real files) grade, map scope, dry-run, create, verify and deploy the Blueprint to the empty group. With no device in the group the deployment isn’t "clean", so the app must leave the Classic scope alone (checked); the check then runs the app’s own `ClassicScopeService.unscope` (backup, scope-only PUT, read back, payloads unchanged) and Restore from a reopened workspace, as after a relaunch. A fence on the scope writer refuses, and stops the check, if the app’s scope change would touch any profile but this run’s. Read back: the Blueprint holds the profile’s payload type and key, is scoped to the empty group and deployed. Removed: Blueprint, profile, both groups; the sweep also covers `JTKTEST` Classic profiles and computer groups.
  - Deleting test objects is done only by the test code through JTKit’s guarded network; the app’s allow-list still never sends DELETE, group writes or undeploy. Clearing and restoring a Classic profile’s scope runs only on this run’s own profile (asked for by Jordy on 2026-10-28).
  - The fingerprint compares the app’s whole Application Support folder in its container (`tenants.json` with the tenant in use and its backup, `history.json`, `scope-backups.json`, `sessions.json`, `activity.json`), `demoMode` and the Keychain item names starting `be.jordythery.profile2blueprint.`.

## Releasing

1. Bump `MARKETING_VERSION` (X.Y.Z) and `CURRENT_PROJECT_VERSION` in the project.
2. Update the README if features changed.
3. Archive from the app’s own project, sign with Developer ID, notarize, and zip as `Profile2Blueprint-X.Y.Z.zip`.
4. Tag `vX.Y.Z`, create the GitHub release with notes (the in-app updater shows them) and attach the zip.
5. Website: only when the app has its own page on jordythery.be and the release changes the app enough to make that page untrue or incomplete, update the page.

Before any of this, follow the release gate in JTKit/ROADMAP.md.
