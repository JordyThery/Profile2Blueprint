#!/bin/zsh
# Profile2Blueprint's release check (JTKit ROADMAP step 11). Claude runs it
# unattended with nohup; the report lands in
# ~/Library/Application Support/JTKit Release Check/runs/.
#
#   Scripts/release-check.sh [--local-jtkit] [--tenants] [--stop-before-live]
#   Scripts/release-check.sh --local-jtkit --fault break-build|fail-live-step|interrupt-live
#     (tests the check itself; never part of a release check)
#
# Tenants are roles on the local allow-list (never named here): jamf-test-a
# over the Jamf Platform API.
cd "$(dirname "$0")/.." || exit 1

APP_NAME="Profile2Blueprint"
APP_CODE="PB"
PROJECT="Profile2Blueprint.xcodeproj"
SCHEME="Profile2Blueprint Release Check"
UNIT_TESTS="Profile2BlueprintTests"
UI_TESTS="Profile2BlueprintUITests"
SMOKE_CLASS="DemoSmokeUITests"
SMOKE_FILE="$PWD/Profile2BlueprintUITests/DemoSmokeUITests.swift"
SIGNIN_TEST="Profile2BlueprintTests/LiveSignInTests"
LIVE_TESTS=("Profile2BlueprintTests/LiveMigrationTests/tenantA()")
CLEANUP_TEST="Profile2BlueprintTests/LiveCleanupTests"
ROLES=(jamf-test-a)
# role:service:item, read from the Keychain service the allow-list names
CREDENTIALS=(
    "jamf-test-a:jamfPlatform:client-id"
    "jamf-test-a:jamfPlatform:client-secret"
)
DOMAIN="be.jordythery.profile2blueprint"
# The app is sandboxed: its test host reaches only its own container, so the
# live folder (allow-list copy, ledger, results) lives there (JTKit 0.12.2).
TEST_HOST_CONTAINER="$DOMAIN"
# Everything the app saves: tenants.json (the tenants and the one in use) and
# its backup, history.json, scope-backups.json, sessions.json, activity.json.
FINGERPRINT_PATHS=("$HOME/Library/Containers/$DOMAIN/Data/Library/Application Support/Profile2Blueprint")
FINGERPRINT_DEFAULTS=("$DOMAIN demoMode")
KEYCHAIN_PREFIXES=("be.jordythery.profile2blueprint.")

# The template comes from the JTKit under test: the local checkout with
# --local-jtkit, otherwise the published version this project resolves.
if [[ " $* " == *" --local-jtkit "* ]]; then
    LIB="${JTKIT_LOCAL:-$HOME/Developer/JTKit}/Scripts/release-check-lib.sh"
else
    PACKAGES="$HOME/Library/Developer/Xcode/DerivedData/JTKitReleaseCheck-$APP_CODE/SourcePackages"
    xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
        -clonedSourcePackagesDirPath "$PACKAGES" > /dev/null || exit 1
    LIB="$PACKAGES/checkouts/JTKit/Scripts/release-check-lib.sh"
fi
[[ -f "$LIB" ]] || { print -u2 "No release-check template at $LIB (JTKit 0.12.2 or later)"; exit 1 }
source "$LIB"
release_check_main "$@"
