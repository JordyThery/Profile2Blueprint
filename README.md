# Profile2Blueprint

A native macOS app that migrates **Jamf Pro classic macOS configuration profiles** into **Jamf Platform Blueprints**, using the Apple-supported in-place Classic → DDM transform. It turns a manual, API-driven workflow into a safe, reviewable one.

> **Status:** verified end to end against a live Jamf tenant — create, server-side verify, deploy, the in-place transform on a device, and classic scope cleanup with restore. Validate each migration on a test device before fleet-wide use.

## Install

Download the latest `Profile2Blueprint-x.y.zip` from [Releases](https://github.com/JordyThery/Profile2Blueprint/releases), unzip it, and move **Profile2Blueprint.app** to `/Applications`. The app is signed with a Developer ID certificate and notarized, so Gatekeeper verifies it instead of blocking it. Requires **macOS 14 or later**.

## Try it without a tenant

Switch on **Offline demo mode** in the sidebar. The full flow — eligibility, scope mapping, create, verify, deploy, unscope and restore — runs against bundled fixtures, with no network access and nothing to configure. This is the quickest way to see whether the app fits your environment.

## Connect to Jamf

In [Jamf Account](https://account.jamf.com), create an API integration scoped to the **platform environment** (tenant scope cannot reach the Blueprints API, and the scope level is fixed once the integration is created). Grant it:

| Capability | Actions | Needed for |
|---|---|---|
| `device-groups` | Read | Listing platform device groups to map classic scope onto |
| `configuration-profiles` | Read | Reading the classic profiles to migrate |
| `blueprints` | Create, Read, Deploy | Creating, verifying and deploying blueprints |
| `configuration-profiles` | Update | **Optional** — only to clear classic scope after a deployment |

Jamf Account presents these as per-capability checkboxes; the APIs refer to them as `device-groups:read`, `blueprints:create` and so on.

Then in the app: **Add Tenant** → pick the region → paste the platform **Environment ID**, **Client ID** and **Client secret** → **Test Connection** (requests a token and lists platform device groups) → **Save Changes**. Secrets are stored only in your Keychain.

## First migration

1. Open **Profiles**. Each classic macOS profile is graded ✅ Ready, ⚠️ Needs attention or ⛔ Blocked, with the reasons listed.
2. Select a ✅ Ready profile and review the **Scope** and **Blueprint Preview** tabs. Preview shows the exact JSON that will be sent.
3. Run **Migrate**. The blueprint is created but *not* deployed; the app then verifies it against the server's read-back. Deploying is a separate, explicitly confirmed step.

## How it works

Apple allows a classic (imperative) MDM profile to be transformed in place into a DDM-managed profile — no enforcement gap, no conflict — when all of these hold:

1. The classic profile was installed by MDM.
2. DDM is enabled on the device.
3. The top-level `PayloadIdentifier` and `PayloadUUID` of the DDM legacy profile match the classic profile's.
4. The number of payloads in `PayloadContent` matches.
5. Each payload's `PayloadType`, `PayloadIdentifier` and `PayloadUUID` match, in the same order.

The app walks that workflow stage by stage — **fetch → validate → distill (plist → JSON) → map scope → build → create → verify → deploy** — with an explicit confirmation gate before anything irreversible. Rules 1–2 cannot be checked through the API; the app says so and leaves them to you.

## Safety model

- Creating a blueprint never deploys it.
- Verification compares identifiers, payload order and count, setting values and scope against the server's read-back, tolerating documented server canonicalisation.
- Deploy requires a per-blueprint confirmation listing the target groups and device count, and is refused when verification failed.
- The HTTP layer refuses any request that isn't a GET, a blueprint create, a blueprint deploy or — only when explicitly enabled — a scope-only classic profile update, before it reaches the network.
- **Classic cleanup is opt-in.** After a fully clean deployment (0 failed, 0 pending), the app can remove the classic profile's scope targets. This is guarded three times: a per-tenant setting that is off by default, a per-profile opt-in, and a confirmation. The original scope is backed up locally and can be restored.
- Client secrets and tokens are never written to any log.

## Other features

- **Multiple tenants** — us / eu / apac, with an optional host override.
- **Blueprint name and description** — a per-tenant name prefix and suffix, and a description template with `{name}` and `{id}` tokens. All three are optional and default to the original wording, so a test environment can be labelled differently from production. Both stay editable per blueprint before creating.
- **Scope mapping** — exact-name auto-matching, with pickers for anything ambiguous or unmatched.
- **Diff** — the five rules as a checklist, plus side-by-side JSON.
- **Batch migration** — per-item summaries and one deploy confirmation listing every target.
- **Persistent sessions** — a created blueprint re-attaches after a relaunch and resumes at its current stage; after a deployment the device report refreshes until every device has reported in.
- **History** — every migration action, exportable as Markdown or JSON.
- **Activity** — everything the app does: token requests, every API call (status, duration, trace ID), retries, refused writes and settings changes.

## Build from source

Requires Xcode with the macOS 26 SDK or later (Swift 6, strict concurrency). Open the project and run the `Profile2Blueprint` scheme; there are no third-party dependencies. `⌘U` runs the test suite.

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
                 MigrationPipeline (actor, staged state machine),
                 ClassicScopeService (with ScopeBackupStore)
    Persistence/ TenantStore, HistoryStore, ActivityStore, SessionStateStore
  Features/    Connect, ProfileList, ProfileDetail, ScopeMapping, Review,
               Deploy, Batch, History, Activity, About
  Resources/   Fixtures (demo profiles and in-memory demo servers)
Profile2BlueprintTests/   Swift Testing suite (300+ cases, mock URLProtocol)
```

Each API sits behind a protocol with live and demo implementations, so the pipeline and UI run unchanged against fixtures.

## Known limitations

- Scope limitations and exclusions have no blueprint equivalent and are not carried over (the eligibility checker warns about this).
- User-level profiles cannot be migrated.
- 22 payload types are refused by the Blueprints API and are flagged as blocked before anything is sent — certificates and SCEP, VPN and per-app VPN, Extensible SSO, directory binding, legacy MCX FileVault, global HTTP proxy, web content filter, DNS settings, fonts and web clips among them. The payload-type tables come from Jamf's own [`jamf-cli`](https://github.com/Jamf-Concepts/jamf-cli/tree/main/internal/profileconvert), which wire-probed them; they are instance- and version-specific, so the API remains the authority.
- A payload type Jamf Pro spells differently from Apple (currently `com.apple.preferences.users`) blocks migration. Rewriting the type would break the rule that every payload type matches the installed profile.
- The classic scope update (`PUT /proclassic/osxconfigurationprofiles/id/{id}`) uses the Classic API's partial-XML convention. Jamf's OpenAPI specs do not document the request body, so re-verify after major Jamf Pro upgrades.

## Support

If Profile2Blueprint saves you time, you can [buy me a coffee](https://buymeacoffee.com/jordythery). ☕️

## License

[MIT](LICENSE)
