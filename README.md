# Profile2Blueprint

A native macOS app that migrates **Jamf Pro classic configuration profiles** (macOS and mobile device) into **Jamf Platform Blueprints**, using the Apple-supported in-place Classic → DDM transform. It turns a manual, API-driven workflow into a safe, reviewable one.

> **Status:** verified end to end against live Jamf tenants — create, server-side verify, deploy, the in-place transform on a Mac and on an iPhone, and classic scope cleanup with restore. Try every migration on a test device before using it fleet-wide.

## Install

Download the latest `Profile2Blueprint-X.Y.Z.zip` from [Releases](https://github.com/JordyThery/Profile2Blueprint/releases), unzip it, and move **Profile2Blueprint.app** to `/Applications`. The app is signed with a Developer ID certificate and notarized, so Gatekeeper verifies it instead of blocking it. Requires **macOS 14 or later**.

## Try it without a tenant

Choose **Demo Mode** in the connection picker in the toolbar (or the Connection menu), or click **Try Demo Mode** on the page shown when no tenant is set up. The full flow — eligibility, scope mapping, create, verify, deploy, unscope and restore — runs against a sample tenant, “Contoso (Demo)”, answered inside the app: no tenant is contacted, nothing is saved to your tenants or the Keychain, and there is nothing to configure. Every window title ends in “— Demo” while it is on. This is the quickest way to see whether the app fits your environment.

## Connect to Jamf

In [Jamf Account](https://account.jamf.com), create an API integration scoped to the **platform environment** (tenant scope cannot reach the Blueprints API, and the scope level is fixed once the integration is created). Jamf’s [Integrations Management guide](https://learn.jamf.com/r/en-US/jamf-account-documentation/Integrations_Management_in_Jamf_Account) covers the steps. Grant it:

| Capability | Actions | Needed for |
|---|---|---|
| `device-groups` | Read | Listing platform device groups to map classic scope onto |
| `configuration-profiles` | Read | Reading the classic profiles to migrate |
| `blueprints` | Create, Read, Deploy | Creating, verifying and deploying Blueprints |
| `configuration-profiles` | Update | **Optional**: only to unscope the classic profile after a deployment |

Jamf Account presents these as per-capability checkboxes; the APIs refer to them as `device-groups:read`, `blueprints:create` and so on.

Then in the app, open **Settings › Connections** → **Add Connection…** → pick the region → paste the **Client ID** and **Client secret** → **Load Environments** to pick the platform environment (or paste its **Environment ID**) → **Test Connection** (requests a token, checks the read permissions and counts platform device groups) → **Save**. Secrets are stored only in your Keychain. Optionally add the **Jamf Pro Web Address** you use in a browser to get **Open in Jamf Pro** links for the classic profile and its Blueprint.

## First migration

1. Open **Profiles**. Every classic profile (macOS and mobile device) is graded **Ready**, **Needs attention** or **Blocked**, with the reasons listed. Filters show one status or one platform at a time; search finds a profile by name, ID or payload type.
2. Select a Ready profile and review the **Scope** and **Blueprint Preview** tabs. Preview shows the exact JSON that will be sent.
3. On the **Migrate** tab, **Run Dry Run** first if you like: it validates and checks for a Blueprint with the same name, and writes nothing. Then turn off **Dry run** and click **Create Blueprint (Not Deployed)**. The app reads the Blueprint back and verifies it. Deploying is a separate, explicitly confirmed step.

## How it works

Apple allows a classic (imperative) MDM profile to be transformed in place into a DDM-managed profile — no enforcement gap, no conflict — when all of these hold:

1. The classic profile was installed by MDM.
2. DDM is enabled on the device.
3. The top-level `PayloadIdentifier` and `PayloadUUID` of the DDM legacy profile match the classic profile’s.
4. The number of payloads in `PayloadContent` matches.
5. Each payload’s `PayloadType`, `PayloadIdentifier` and `PayloadUUID` match, in the same order.

The app walks that workflow stage by stage — **fetch → validate → distill (plist → JSON) → map scope → build → create → verify → deploy** — with an explicit confirmation gate before anything irreversible. Rules 1–2 cannot be checked through the API; the app says so and leaves them to you.

## Safety model

- Creating a Blueprint never deploys it.
- Verification compares identifiers, payload order and count, setting values and scope against the server’s read-back, tolerating documented server canonicalization.
- Deploy requires a per-Blueprint confirmation listing the target groups and device count, and is refused when verification failed. A group whose device count the server doesn’t give is shown as unknown.
- The HTTP layer refuses any request that isn’t a GET, a Blueprint create, a Blueprint deploy or (only while classic scope changes are on for the tenant) a scope-only classic profile update, before it reaches the network.
- **Classic profile cleanup is opt-in.** After a fully clean deployment (0 failed, 0 pending), the app can unscope the classic profile. This is guarded three times: a per-tenant setting that is off by default, a per-profile opt-in, and a confirmation. Turning the tenant setting off stops every scope change at once, also for migrations still waiting for their device report. The automatic cleanup runs only when the Blueprint’s groups cover every target of the classic scope (not for "all computers", individual devices, buildings, departments or a group the Blueprint doesn’t target), and at most once per profile. The original scope is backed up locally, per tenant, and **Restore Scope** puts it back; a restored profile is never unscoped again automatically. After the transform, Jamf Pro logs a *failed* “Remove Configuration Profile” command per device: the device refuses to let MDM remove a profile the Blueprint now owns, which is expected.
- Client secrets and tokens are never written to any log. Copying a request body that holds credentials (Wi-Fi passwords, SCEP challenges) keeps it off other devices and clipboard history, and clears it after a minute.
- Apart from the Jamf gateway, the only address the app contacts is GitHub, once a day, to ask whether a newer release exists. Turn it off in **Settings › Updates**.
- Never undeploy a Blueprint in Jamf Pro after the classic profile is gone: that removes the settings from devices. (The app itself can’t undeploy anything.)

## Other features

- **Multiple tenants**: us / eu / apac, with an optional host override, in Settings › Connections.
- **Blueprint name and description**: a per-tenant name prefix and suffix, and a description template with `{name}` (the profile’s name), `{id}` (its Jamf Pro ID) and `{platform}` (“macOS” or “mobile device”) tokens. All three are optional and default to the original wording, so a test environment can be labeled differently from production; an empty template means no description. Both stay editable per Blueprint before creating.
- **Dry run**: on by default. It validates, builds the request and checks for a Blueprint with the same name, and writes nothing.
- **Duplicate names**: when a Blueprint with the same name exists, choose **Skip**, **Rename** or **Open Existing**.
- **Scope mapping**: exact-name auto-matching against platform groups of the profile’s own platform (a mobile profile is never offered a computer group), with pickers for anything ambiguous or unmatched.
- **Diff**: the five rules as a checklist, plus side-by-side JSON.
- **Credentials warning**: a profile that holds credentials is marked “Contains credentials”, and its preview says to treat copies as secrets.
- **Batch migration**: tick profiles in the list (or ⌘-click), then review them together: per-item summaries and one deploy confirmation listing every target.
- **Reload and Reload Profile**: read the list or one profile again; open migrations that haven’t created their Blueprint yet pick up the change.
- **Open in Jamf Pro**: the configuration profile or its Blueprint, in the Jamf Pro console.
- **Update check**: daily and on demand, with release notes and a download.
- **Persistent sessions**: a created Blueprint re-attaches after a relaunch and resumes at its current stage; after a deployment the device report refreshes until every device has reported in. When the Blueprint was deleted on the server, the saved reference is removed.
- **History**: every migration action, exportable as Markdown or JSON.
- **Activity Log** (Window › Activity Log, ⇧⌘L): everything the app does: token requests, every API call (status, duration, trace ID), retries, refused writes and settings changes.
- **Appearance**: light, dark or the system’s, in Settings › General.

## Build from source

Requires Xcode with the macOS 26 SDK or later (Swift 6, strict concurrency). Open the project and run the `Profile2Blueprint` scheme; the only dependency is [JTKit](https://github.com/JordyThery/JTKit), resolved from GitHub. `⌘U` runs the unit tests.

```
Profile2Blueprint/
  App/        AppModel, Workspace, MigrationSession, HistoryLog,
              ActivityEntries, DemoFiles, Log
  Models/     Tenant, ClassicProfile, PlistValue (order-preserving),
              ProfilePlatform, EligibilityReport, MigrationRecord,
              Blueprint (the create request), APIError, LosslessJSON+App
  Services/
    Auth/        KeychainStore (where the client secrets are kept)
    API/         RequestPolicy (allow-list), ClassicAPI, ClassicScopeWriter
    Migration/   PlistParser, ClassicXMLParser, PlistToJSON, ScopeMapper,
                 EligibilityChecker, BlueprintBuilder, FidelityVerifier,
                 MigrationPipeline (actor, staged state machine),
                 ClassicScopeService (with ScopeBackupStore)
    Persistence/ TenantStore, HistoryStore, SessionStateStore, StoredList
  Features/    Connect, ProfileList, ProfileDetail, ScopeMapping, Review,
               Deploy, Batch, History, Shared
  Resources/   Fixtures (Contoso demo profiles and the demo Classic server)
Profile2BlueprintTests/     Swift Testing suite, on JTKit's fake network
Profile2BlueprintUITests/   Demo Mode smoke tests (run by the release check)
```

The Platform API client, sign-in, Blueprints, device groups, the activity log, About, Settings, the update check and Demo Mode come from JTKit.

Demo mode uses JTKit’s demo network and Jamf Platform server, with the app’s Classic profiles added to it, so the same client, allow-list, pipeline and UI run in demo mode as against a tenant.

## Known limitations

- Scope limitations and exclusions have no Blueprint equivalent and aren’t carried over (the eligibility checker warns about this).
- User-level profiles can’t be migrated.
- Sites aren’t carried over: the public Blueprints API has no site field yet.
- Jamf School isn’t supported: its platform environment offers no configuration profiles or device groups, so profiles can’t be read and a Blueprint can’t be scoped.
- A local Jamf Pro account can’t be used: Blueprints exist only behind the Jamf Platform API gateway, which needs a Jamf Account integration.
- A payload whose `PayloadUUID` differs from its `PayloadIdentifier` is blocked: the Blueprints API overwrites the UUID with the identifier, so the transform would fail on devices. Typical of uploaded profiles; a clone made in Jamf Pro gets matching identifiers.
- 22 payload types are refused by the Blueprints API and are flagged as blocked before anything is sent — certificates and SCEP, VPN and per-app VPN, Extensible SSO, directory binding, legacy MCX FileVault, global HTTP proxy, web content filter, DNS settings, fonts and web clips among them. The payload-type tables come from Jamf’s own [`jamf-cli`](https://github.com/Jamf-Concepts/jamf-cli/tree/main/internal/profileconvert), which wire-probed them; they are instance- and version-specific, so the API remains the authority.
- A payload type Jamf Pro spells differently from Apple (currently `com.apple.preferences.users`) blocks migration. Rewriting the type would break the rule that every payload type matches the installed profile.
- The classic scope update (`PUT /proclassic/{resource}/id/{id}`) uses the Classic API’s partial-XML convention. Jamf’s OpenAPI specs don’t document the request body; both the macOS and the mobile form are verified against a live tenant.

## Support

If Profile2Blueprint saves you time, you can [buy me a coffee](https://buymeacoffee.com/jordythery). ☕️

## License

[MIT](LICENSE)
