# Profile2Blueprint: watchlist

What this app is waiting for from Apple, Jamf or Microsoft, or must recheck. Check each item when the vendor ships an update.

- **Site field in the Blueprints API (Jamf, last checked 2026-10-13):** the public Blueprints API has no site field. When it gains one, propose: read and set the Blueprint’s site, filter profiles by site.
- **Jamf School capabilities (Jamf):** a Jamf School platform environment has no configuration-profiles or device-groups capability. Revisit only if Jamf adds those capabilities.
- **Site assigned in the Jamf Pro UI (Jamf):** assigning a site to an existing, undeployed migrated Blueprint removed its payload component and target group and renamed the step. Unknown whether this always happens: recheck.
- **jamf-cli payload-type tables (Jamf, last reviewed 2026-10-12 at commit `3999e358`; tables last probed 2026-07-17):** `EligibilityChecker`’s tables and the string-rewrite classes come from jamf-cli’s `internal/profileconvert` and drift silently. Compare when working on the app.
