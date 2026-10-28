# Changelog

## Unreleased

Fixes for what JTKit ROADMAP step 11 (the release check) found, 2026-10-28.

- **Sandbox runs keep scope backups and sessions out of the real files.** A
  `-JTKitSandbox` run (UI tests) opened the real `scope-backups.json` and
  `sessions.json` for a real tenant's workspace; only tenants and history were
  kept in its temporary folder. Nothing wrote them, because the sandbox network
  reaches nothing, but now all four files stay in the temporary folder.
- **A refused deploy no longer leaves a "confirmed" line in History.** Deploy
  wrote "Deploy — Confirmed by user…" (success) before the migration checked
  the deploy could go ahead, so a refused deploy (verification not passed, or a
  confirmation for another Blueprint) still showed a confirmed deploy. The line
  is now written only once the deploy is accepted; a refused one sends nothing
  and shows its reason.
- **The migration steps run in order.** Once a Blueprint is created, checking
  eligibility or building the request again is refused instead of moving the
  migration back a step (which kept the Blueprint's ID, and building again
  dropped it, so a second Blueprint could be created). Loading the profile
  again still starts over, as Reload Profile and reopening a migration do.
- **Restore Scope is offered only for a backup it will accept.** The migration
  looked up a profile's scope backup with a looser match than Restore checks,
  so it could offer Restore for a backup that Restore then refused (a tenant
  without an Environment ID named like the earlier demo, "Offline demo"). Both
  now use the same check.
