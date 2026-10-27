# Profile2Blueprint

A native macOS app that migrates **Jamf Pro classic configuration profiles** — macOS and mobile device — into **Jamf Platform Blueprints**, using the Apple-supported in-place Classic → DDM transform. It turns a manual, API-driven workflow into a safe, reviewable one.

> **Status:** verified end to end against live Jamf tenants — create, server-side verify, deploy, the in-place transform on a Mac and on an iPhone, and classic scope cleanup with restore. Validate each migration on a test device before fleet-wide use.

## Install

Download the latest `Profile2Blueprint-x.y.zip` from [Releases](https://github.com/JordyThery/Profile2Blueprint/releases), unzip it, and move **Profile2Blueprint.app** to `/Applications`. The app is signed with a Developer ID certificate and notarized, so Gatekeeper verifies it instead of blocking it. Requires **macOS 14 or later**.

## Try it without a tenant

Choose **Demo Mode** in the connection picker in the toolbar (or the Connection menu). The full flow — eligibility, scope mapping, create, verify, deploy, unscope and restore — runs against a sample tenant, “Contoso (Demo)”, answered inside the app: no tenant is contacted, nothing is saved to your tenants or the Keychain, and there is nothing to configure. Every window title ends in “— Demo” while it is on. This is the quickest way to see whether the app fits your environment.

## Connect to Jamf

In [Jamf Account](https://account.jamf.com), create an API integration scoped to the **platform environment** (tenant scope cannot reach the Blueprints API, and the scope level is fixed once the integration is created). Jamf's [Integrations Management guide](https://learn.jamf.com/r/en-US/jamf-account-documentation/Integrations_Management_in_Jamf_Account) covers the steps. Grant it:

| Capability | Actions | Needed for |
|---|---|---|
| `device-groups` | Read | Listing platform device groups to map classic scope onto |
| `configuration-profiles` | Read | Reading the classic profiles to migrate |
| `blueprints` | Create, Read, Deploy | Creating, verifying and deploying blueprints |
| `configuration-profiles` | Update | **Optional** — only to clear classic scope after a deployment |

Jamf Account presents these as per-capability checkboxes; the APIs refer to them as `device-groups:read`, `blueprints:create` and so on.

Then in the app: **Add Tenant** → pick the region → paste the platform **Environment ID**, **Client ID** and **Client secret** → **Test Connection** (requests a token and lists platform device groups) → **Save Changes**. Secrets are stored only in your Keychain. Optionally add the **Jamf Pro URL** you use in a browser to get **Open in Jamf Pro** links for the classic profile and its blueprint.

## First migration

1. Open **Profiles**. Every classic profile — macOS and mobile device — is graded ✅ Ready, ⚠️ Needs attention or ⛔ Blocked, with the reasons listed. A filter shows one platform at a time.
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
- **Classic cleanup is opt-in.** After a fully clean deployment (0 failed, 0 pending), the app can remove the classic profile's scope targets. This is guarded three times: a per-tenant setting that is off by default, a per-profile opt-in, and a confirmation. The original scope is backed up locally and can be restored. After the transform, Jamf Pro logs a *failed* “Remove Configuration Profile” command per device — the device refuses to let MDM remove a profile the blueprint now owns, which is expected.
- Client secrets and tokens are never written to any log.
- Apart from the Jamf gateway, the only address the app contacts is GitHub, once a day, to ask whether a newer release exists. Turn it off in **About**.
- Never undeploy a blueprint in Jamf Pro after the classic profile is gone: that removes the settings from devices. (The app itself cannot undeploy anything.)

## Other features

- **Multiple tenants** — us / eu / apac, with an optional host override.
- **Blueprint name and description** — a per-tenant name prefix and suffix, and a description template with `{name}`, `{id}` and `{platform}` tokens. All three are optional and default to the original wording, so a test environment can be labelled differently from production. Both stay editable per blueprint before creating.
- **Scope mapping** — exact-name auto-matching against platform groups of the profile's own platform (a mobile profile is never offered a computer group), with pickers for anything ambiguous or unmatched.
- **Diff** — the five rules as a checklist, plus side-by-side JSON.
- **Batch migration** — tick profiles in the list (or ⌘-click), then review them together: per-item summaries and one deploy confirmation listing every target.
- **Open in Jamf Pro** — the configuration profile or its blueprint, in the Jamf Pro console.
- **Update check** — daily and on demand, with release notes and a download.
- **Persistent sessions** — a created blueprint re-attaches after a relaunch and resumes at its current stage; after a deployment the device report refreshes until every device has reported in.
- **History** — every migration action, exportable as Markdown or JSON.
- **Activity** — everything the app does: token requests, every API call (status, duration, trace ID), retries, refused writes and settings changes.

## Build from source

Requires Xcode with the macOS 26 SDK or later (Swift 6, strict concurrency). Open the project and run the `Profile2Blueprint` scheme; there are no third-party dependencies. `⌘U` runs the test suite.

```
Profile2Blueprint/
  App/        AppModel, Workspace, MigrationSession, HistoryLog, ActivityLog,
              UpdateChecker
  Models/     Tenant, ClassicProfile, PlistValue (order-preserving),
              BlueprintRequest, EligibilityReport, MigrationRecord, ActivityEvent
  Services/
    Auth/        TokenProvider (actor), KeychainStore
    API/         RequestPolicy (allow-list), ClassicAPI, ClassicScopeWriter;
                 the Platform API client, Blueprints, device groups and JSON are JTKit's
    Migration/   PlistParser, ClassicXMLParser, PlistToJSON, ScopeMapper,
                 EligibilityChecker, BlueprintBuilder, FidelityVerifier,
                 MigrationPipeline (actor, staged state machine),
                 ClassicScopeService (with ScopeBackupStore)
    Persistence/ TenantStore, HistoryStore, ActivityStore, SessionStateStore
  Features/    Connect, ProfileList, ProfileDetail, ScopeMapping, Review,
               Deploy, Batch, History, Activity, About
  Resources/   Fixtures (Contoso demo profiles and the demo Classic server)
Profile2BlueprintTests/   Swift Testing suite (300+ cases, mock URLProtocol)
```

Demo mode uses JTKit's demo network and Jamf Platform server, with the app's Classic profiles added to it, so the same client, allow-list, pipeline and UI run in demo mode as against a tenant.

## Known limitations

- Scope limitations and exclusions have no blueprint equivalent and are not carried over (the eligibility checker warns about this).
- User-level profiles cannot be migrated.
- A payload whose `PayloadUUID` differs from its `PayloadIdentifier` is blocked: the Blueprints API overwrites the UUID with the identifier, so the transform would fail on devices. Typical of uploaded profiles; a clone made in Jamf Pro gets matching identifiers.
- 22 payload types are refused by the Blueprints API and are flagged as blocked before anything is sent — certificates and SCEP, VPN and per-app VPN, Extensible SSO, directory binding, legacy MCX FileVault, global HTTP proxy, web content filter, DNS settings, fonts and web clips among them. The payload-type tables come from Jamf's own [`jamf-cli`](https://github.com/Jamf-Concepts/jamf-cli/tree/main/internal/profileconvert), which wire-probed them; they are instance- and version-specific, so the API remains the authority.
- A payload type Jamf Pro spells differently from Apple (currently `com.apple.preferences.users`) blocks migration. Rewriting the type would break the rule that every payload type matches the installed profile.
- The classic scope update (`PUT /proclassic/{resource}/id/{id}`) uses the Classic API's partial-XML convention. Jamf's OpenAPI specs do not document the request body; the macOS form is verified against a live tenant, the mobile form only against the same convention, so test cleanup on one mobile profile first.

## Support

If Profile2Blueprint saves you time, you can [buy me a coffee](https://buymeacoffee.com/jordythery). ☕️

## License

[MIT](LICENSE)
