# Profile2Blueprint

A native macOS app that migrates **Jamf Pro classic macOS configuration profiles** into **Jamf Platform Blueprints**, using the Apple-supported in-place Classic → DDM transform. It turns a manual, API-driven workflow into a safe, reviewable, GUI-driven one.

> **Status:** verified end to end against a live Jamf tenant — create, server-side verify, deploy, the in-place transform on a device, and classic scope cleanup with restore. Still validate each migration on a test device before fleet-wide use.

## How it works

Apple lets a classic (imperative) MDM profile be transformed in place into a DDM-managed profile — no enforcement gap, no conflict — when all of these hold:

1. The classic profile was installed by MDM.
2. DDM is enabled on the device.
3. The top-level `PayloadIdentifier` and `PayloadUUID` of the DDM legacy profile match the classic profile's.
4. The number of payloads in `PayloadContent` matches.
5. Each payload's `PayloadType`, `PayloadIdentifier` and `PayloadUUID` match, in the same order.

The app walks that workflow stage by stage: **fetch → validate → distill (plist → JSON) → map scope → build → create (not deployed) → verify → deploy**, with an explicit confirmation gate before anything irreversible. Rules 1–2 can't be checked through the API; the app says so and leaves them to you.

## Features

- **Tenant management** — multiple saved tenants (us / eu / apac, optional host override). OAuth client secrets live only in the Keychain.
- **Profiles list** — every classic macOS profile with an eligibility badge: ✅ Ready, ⚠️ Needs attention (with reasons), ⛔ Blocked (with reasons). Selecting target groups resolves the pick-a-group warnings; information-loss warnings still require an explicit acknowledgement.
- **Profile detail** — Source (metadata, scope, payload tree), Scope mapping (exact-name auto-match with pickers for the rest), Blueprint Preview (the exact JSON that will be POSTed), Diff (the five rules as a checklist plus side-by-side JSON), and Migrate.
- **Safety model**
  - Dry run is the default; creating a blueprint never deploys it.
  - Verification compares identifiers, payload order and count, setting values and scope against the server's read-back, tolerating documented server canonicalisation.
  - Deploy requires a per-blueprint confirmation listing the target groups and device count, and is refused when verification failed.
  - The HTTP layer refuses any request that isn't a GET, a blueprint create, a blueprint deploy or (only when explicitly enabled) a scope-only classic profile update — before it reaches the network.
- **Classic cleanup (opt-in)** — after a fully clean deployment (0 failed, 0 pending), the app can remove the classic profile's scope targets. Guarded three times: a per-tenant setting that is off by default, a per-profile opt-in, and a confirmation. The original scope is backed up locally and can be restored.
- **Batch migration** — per-item summaries, one deploy confirmation listing every target.
- **Sessions persist** — a created blueprint re-attaches after a relaunch and resumes at its current stage; after a deployment the device report refreshes automatically until every device reports in.
- **History** — a local log of every migration action, exportable as Markdown or JSON.
- **Activity** — a local log of everything the app does: token requests, every API call (status, duration, trace ID), retries, refused writes and settings changes. Secrets are never logged.
- **Offline demo mode** — the full flow, including deploy and unscope/restore, against bundled fixtures. No tenant required.

## Requirements

- macOS 14+, Xcode with the macOS 26/27 SDK (Swift 6, strict concurrency).
- A [Jamf Account](https://account.jamf.com) API integration scoped to the **platform environment**, with:
  - `device-groups:read`
  - `configuration-profiles:read`
  - `blueprints:create`, `blueprints:read`, `blueprints:deploy`
  - `configuration-profiles:update` — only if you enable classic scope changes

## Getting started

1. Build and run the `Profile2Blueprint` scheme.
2. Either switch on **Offline demo mode** in the sidebar, or add a tenant: pick the region, paste the platform **Environment ID**, **Client ID** and **Client secret**, then **Test Connection** (requests a token and lists computer device groups).
3. Open **Profiles**, pick a ✅ Ready profile, review the Scope and Blueprint Preview tabs, then run the Migrate flow.

## Architecture

```
Profile2Blueprint/
  App/        AppModel, Workspace, MigrationSession, HistoryLog, ActivityLog
  Models/     Tenant, ClassicProfile, PlistValue/JSONValue (order-preserving),
              Blueprint, EligibilityReport, MigrationRecord, ActivityEvent
  Services/
    Auth/        TokenProvider (actor), KeychainStore
    API/         HTTPClient (allow-list, retry/backoff, activity logging),
                 ClassicAPI, DeviceGroupsAPI, BlueprintsAPI, ClassicScopeWriter
    Migration/   PlistParser, ClassicXMLParser, PlistToJSON, ScopeMapper,
                 EligibilityChecker, BlueprintBuilder, FidelityVerifier,
                 MigrationPipeline (actor, staged state machine), ClassicScopeService
    Persistence/ TenantStore, HistoryStore, ActivityStore, ScopeBackupStore,
                 SessionStateStore
  Features/    Connect, ProfileList, ProfileDetail, ScopeMapping, Review,
               Deploy, Batch, History, Activity, About
  Resources/   Fixtures (demo profiles and in-memory demo servers)
Profile2BlueprintTests/   Swift Testing suite (300+ tests, mock URLProtocol)
```

Each API sits behind a protocol with live and demo implementations, so the pipeline and UI run unchanged against fixtures.

## Known limitations

- Scope limitations and exclusions have no blueprint equivalent and are not carried over (the eligibility checker warns about this).
- User-level profiles, and `com.apple.font` / `com.apple.webClip.managed` payloads, cannot be migrated (API restriction).
- The classic scope update (`PUT /osxconfigurationprofiles/id/{id}`) uses the Classic API's partial-XML convention; Jamf's OpenAPI specs do not document the request body, so re-verify after major Jamf Pro upgrades.
