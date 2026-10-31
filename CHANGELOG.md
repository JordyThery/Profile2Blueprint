# Changelog

## 1.3.0 (2026-10-31)

### Classic profile cleanup is safer

- **Restore Scope stays restored.** After a restore, the automatic cleanup is
  turned off for that migration for good. Before, Refresh Status or a relaunch
  could unscope the profile again without asking. The automatic cleanup now
  runs at most once per profile.
- **Automatic cleanup only where the Blueprint reaches every device.** It runs
  only when every target of the classic scope is a group that the Blueprint
  also targets. A profile scoped to all computers, to individual devices,
  buildings or departments, or to a group the Blueprint doesn’t target is
  held back with the reason shown, and you can still unscope it by hand. In
  that case the deploy confirmation no longer promises the cleanup, and the
  Unscope confirmation names the devices that would lose the profile.
- **A scope change that failed never reads as done.** Each scope backup now
  records whether its change reached Jamf Pro. A refused change (a missing
  permission, say) no longer shows as "unscoped" later. When the outcome isn’t
  known, the app reads the profile to find out. If it still can’t tell, it
  says so and offers Restore. Backups from earlier versions are checked this
  way once.
- **Restore is offered right away** when the scope change went through but
  reading the profile back failed.
- **Turning off "Allow classic scope changes" stops pending cleanups.** The
  switch is read at the moment of every scope change, so a migration still
  watching its device report can’t change the scope once the switch is off.
  Switching tenants, editing a tenant or switching Demo Mode stops the old
  workspace’s watches.
- **A cleanup that comes due while you’re doing something else runs right
  after it** instead of being dropped. When the device report stops refreshing
  (after 30 minutes, or on an error), the status says so.
- The opt-in can be turned off at any time, also after deploying. It can be
  turned on only before deploying.

### Saved data

- History, scope backups and sessions follow the same rule as the tenants file:
  a file that can’t be read is copied next to itself
  (`<file>.unreadable-<date and time>`) and is never written over. The app says
  so, and no scope change runs without a working backup file.
- One copy of each file is open at a time, so two workspaces can no longer
  overwrite each other’s scope backups or sessions.
- When the history or a migration can’t be saved, the app now tells you.
- A Blueprint’s description is saved with the migration and comes back after a
  relaunch.

### Migration steps

- Run Dry Run is turned off once the Blueprint exists. Before, it started the
  migration over and left Deploy and Verify Again stuck.
- Verify Again no longer makes a Blueprint deployable again while its deployment
  may still be running (after the polling timed out).
- Reload passes the fetched profile to open migrations, so Create always
  migrates what the Source tab shows.
- When the mobile device profile list can’t be read (or the macOS one), the
  other platform’s profiles still show, with the error above the list.
- A device group without a member count shows "unknown", never "0 devices".
  The deploy confirmation then says "at least" for the total.
- Refresh Status no longer adds the same deployment result to History again.
- Create, Dry Run, Verify and Deploy wait until a migration from an earlier
  launch is re-attached.
- A dropped connection during the scope change is retried, as sending the same
  scope twice changes nothing.
- Copy JSON on a profile with credentials copies them concealed and for this
  Mac only, and clears the clipboard after a minute (JTKit’s secret clipboard).

### Text

- History shows Success, Warning and Failed everywhere.
- The status filter uses the same symbols as the badges.
- Unnamed tenants are called "Unnamed Connection", and the picker’s last item is
  "Edit Connections…", as in Settings › Connections.
- American spelling, curly apostrophes and "Blueprint" throughout.

### Fixes the release check found

- **Sandbox runs keep scope backups and sessions out of the real files.** A
  `-JTKitSandbox` run (UI tests) opened the real `scope-backups.json` and
  `sessions.json` for a real tenant’s workspace. Nothing wrote them, because
  the sandbox network reaches nothing, but now all four files stay in its
  temporary folder.
- **A refused deploy no longer leaves a "confirmed" line in History.** The
  line is written only once the deploy is accepted.
- **The migration steps run in order.** Once a Blueprint is created, checking
  eligibility or building the request again is refused instead of moving the
  migration back a step (which could create a second Blueprint).
- **Restore Scope is offered only for a backup it will accept.** Looking up a
  backup and Restore now use the same check.

## 1.2.0 (2026-10-12)

### Added

- **Mobile device profiles.** iOS and iPadOS configuration profiles migrate the
  same way macOS profiles do, verified end to end on hardware. The profile list
  covers both platforms with a filter, each profile is matched only against
  device groups of its own platform, and the description template gains a
  `{platform}` token.
- Classic cleanup works on mobile profiles too, behind the same three guards.

### Changed

- A payload whose `PayloadUUID` differs from its `PayloadIdentifier` is blocked
  before anything is created: the Blueprints API rewrites the UUID, so the
  transform would fail on devices.
- A payload with no settings warns: the Jamf Pro UI refuses to deploy a
  Blueprint containing one.
- The cleanup step explains the failed "Remove Configuration Profile" command
  Jamf Pro logs after a transform; it’s expected.

### Fixed

- A Blueprint with no name on the server no longer breaks the duplicate-name check.

## 1.1.0 (2026-10-02)

### Added

- **Open in Jamf Pro** for the configuration profile or its Blueprint, with the
  tenant’s optional Jamf Pro URL.
- Checkboxes in the profile list, as an alternative to ⌘-click for batch migration.
- A daily and on-demand update check, with release notes and an in-app download.

### Changed

- The tenant badge was removed from the toolbar; a host override shows in the sidebar.

## 1.0.1 (2026-10-01)

- 22 payload types the Blueprints API refuses are blocked before anything is
  sent (up from 2). A payload type outside the known registry warns; a type
  Jamf Pro spells differently from Apple is blocked; empty values are caught.
- Verification tolerates the four documented Jamf Pro string rewrites (CR/LF,
  trimmed edges, `&` and `<` escaped twice per PI-827, characters outside the
  Basic Multilingual Plane) instead of refusing faithful Blueprints.
- Per-tenant Blueprint name prefix and suffix, and a description template.
- Fixes: the duplicate-name check, the batch deploy confirmation’s cleanup
  notice, grammar markup shown literally, unredacted History until relaunch,
  and the step indicator.

## 1.0 (2026-10-01)

First release: staged migration of Jamf Pro classic macOS configuration profiles
into Jamf Platform Blueprints with Apple’s in-place Classic → DDM transform,
with eligibility checks, fidelity verification, the write allow-list, opt-in
classic cleanup with restore, batch migration, persistent sessions, History,
Activity and a demo mode.
