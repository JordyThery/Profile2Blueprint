import Foundation
import JTKit
import JTKitLiveCheck
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

// Live checks (JTKit ROADMAP step 11), run only by Scripts/release-check.sh,
// which switches them on (JTKIT_LIVE=1) and passes the credentials it read
// from the login Keychain. ⌘U skips them. The tenant is named by role only:
// jamf-test-a over the Jamf Platform API. Every request goes through
// JTKitLiveCheck's guarded network: creates only with the run's JTKTEST
// prefix, changes and deletes only of objects this run created.
//
// The app runs in the App Sandbox, so the test host reaches only its own
// container: the release check puts the allow-list copy, ledger and results
// there (JTKit 0.12.2, `TEST_HOST_CONTAINER`), and the app's history, scope
// backups and sessions go to a temporary folder of this run's.

private let live = LiveCheckRun.isEnabled

#if JTKIT_FAULT_BREAK_BUILD
// Set only by `release-check.sh --fault break-build`, to check that a broken
// build stops the release check before anything reaches a tenant.
#error("Build broken on purpose by the release check's --fault break-build")
#endif

/// The allow-listed tenant as the checks use it.
@MainActor
struct LiveTenant {
    static let role = "jamf-test-a"
    static let service = AllowList.Service.jamfPlatform
    static let profiles = ProfilePlatform.macOS.classicResource
    static let classicGroups = JamfClassic.GroupKind.computer.resource

    let entry: AllowList.Entry
    /// An in-memory tenant, never saved: the app's own connection settings
    /// for jamf-test-a, with classic scope changes on (as a user would turn them on).
    let tenant: Tenant
    let secret: String
    /// The app's own model (an in-memory tenant list, history in `folder`).
    let model: AppModel
    /// The app's own client (its allow-list included) on the guarded network:
    /// reads, creates, deploys and changes Classic scope exactly as the app does.
    let app: JamfPlatform.Client
    /// JTKit's client without the app's allow-list, still on the guarded
    /// network: the test objects and their removal, which the app never does.
    let api: JamfPlatform.Client
    /// This run's folder for the app's history, scope backups and sessions.
    let folder: URL

    init(run: LiveCheckRun, folder: URL) throws {
        entry = try run.entry(role: Self.role, service: Self.service)
        let region = try #require(JamfRegion(rawValue: entry.region ?? ""))
        secret = try run.credential(Self.role, "client-secret")
        tenant = Tenant(name: "Live check", region: region, environmentID: try #require(entry.environmentID),
                        clientID: try run.credential(Self.role, "client-id"), allowClassicScopeChanges: true)
        self.folder = folder
        model = AppModel(store: TenantStore(fileURL: folder.appending(path: "tenants.json")),
                         secrets: InMemorySecretStore(),
                         session: run.network.session,
                         history: HistoryStore(fileURL: folder.appending(path: "history.json")),
                         demoMode: false)
        app = try model.makeClient(for: tenant, secretOverride: secret)
        let secret = secret
        api = try JamfPlatform.Client(
            connection: tenant.connection, secret: { secret },
            recorder: RequestRecorder(session: run.network.session, log: nil, category: "Live check"))
    }

    var blueprints: JamfPlatform.Blueprints { JamfPlatform.Blueprints(client: api) }
    var classic: LiveClassicAPI { LiveClassicAPI(client: app) }

    /// The migration environment as `AppModel.activeWorkspace()` builds it for
    /// a tenant, with the scope writer behind `fence`.
    func environment(fence: ScopeFence) -> MigrationEnvironment {
        MigrationEnvironment(displayName: tenant.displayName, isDemo: false, environmentID: tenant.normalizedEnvironmentID,
                             naming: tenant.naming, descriptionTemplate: tenant.descriptionTemplate,
                             jamfProLinks: tenant.jamfProLinks, classic: classic, platform: app,
                             classicScopeWriter: FencedScopeWriter(fence: fence, inner: LiveClassicScopeWriter(client: app)))
    }

    /// A workspace with this run's files, never the real ones (`activeWorkspace()`
    /// would open the real `scope-backups.json` and `sessions.json`).
    func workspace(fence: ScopeFence) -> Workspace {
        Workspace(environment: environment(fence: fence), history: model.history,
                  scopeBackups: ScopeBackupStore(fileURL: folder.appending(path: "scope-backups.json")),
                  sessionStates: SessionStateStore(fileURL: folder.appending(path: "sessions.json")))
    }

    // MARK: The Platform test group

    /// An empty static computer group: never smart, never with members.
    func createEmptyStaticGroup(name: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name, "deviceType": "COMPUTER", "groupType": "STATIC", "members": [String](),
        ])
        let response = try await api.send(HTTPRequest(method: "POST", path: JamfPlatform.Client.deviceGroupsPath,
                                                      body: body, contentType: "application/json"),
                                          privilege: .createStaticComputerGroups)
        let created = try LosslessJSON(data: response.data)
        return try #require(created["id"]?.stringValue, "The group create returned no id")
    }

    /// Whether the Platform group is static with no members, by its own count and its member list.
    func platformGroupIsEmptyStatic(id: String) async throws -> (empty: Bool, note: String) {
        let path = "\(JamfPlatform.Client.deviceGroupsPath)/\(JamfPlatform.pathSegment(id))"
        let group = JamfPlatform.DeviceGroup(json: try await api.json(path, privilege: .readStaticComputerGroups))
        let list = try await api.json(path + "/members", privilege: .readStaticComputerGroups)
        let members = list["totalCount"]?.numberValue?.intValue ?? list["results"]?.arrayValue?.count
        let empty = group?.groupType == .static && (group?.memberCount ?? 0) == 0 && members == 0
        return (empty, "type \(group.map { $0.groupType.displayName } ?? "unknown"), \(group?.memberCount.map(String.init) ?? "?") members, member list \(members.map(String.init) ?? "?")")
    }

    // MARK: The Classic test group and profile

    /// An empty static Classic computer group. Its name is the first `<name>`.
    func createEmptyClassicGroup(name: String) async throws -> String {
        let xml = "<computer_group><name>\(Self.escape(name))</name><is_smart>false</is_smart><computers/></computer_group>"
        let response = try await api.send(HTTPRequest(method: "POST", path: JamfClassic.createPath(Self.classicGroups),
                                                      body: Data(xml.utf8), accept: "application/xml", contentType: "application/xml"),
                                          privilege: .createStaticComputerGroups)
        return try #require(JamfClassic.createdID(in: response.data), "The Classic group create returned no id")
    }

    func classicGroupIsEmptyStatic(id: String) async throws -> (empty: Bool, note: String) {
        let group = try #require(try await api.classicGroups(.computer).first { $0.id == id }, "Classic group \(id) isn't listed")
        let members = try await api.classicGroupMembers(group)
        return (!group.isSmart && members.isEmpty, "\(group.isSmart ? "smart" : "static"), \(members.count) members")
    }

    /// A macOS profile with one Managed Preferences payload (a made-up domain,
    /// one key), scoped to nothing. Top-level and payload identifiers equal their
    /// UUIDs, as in profiles Jamf Pro makes (the app blocks any other).
    func createProfile(name: String) async throws -> Int {
        let top = UUID().uuidString, payload = UUID().uuidString
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\
        <plist version="1.0"><dict>\
        <key>PayloadUUID</key><string>\(top)</string><key>PayloadType</key><string>Configuration</string>\
        <key>PayloadIdentifier</key><string>\(top)</string><key>PayloadDisplayName</key><string>\(Self.escape(name))</string>\
        <key>PayloadVersion</key><integer>1</integer><key>PayloadScope</key><string>System</string>\
        <key>PayloadContent</key><array><dict>\
        <key>PayloadType</key><string>com.apple.ManagedClient.preferences</string>\
        <key>PayloadIdentifier</key><string>\(payload)</string><key>PayloadUUID</key><string>\(payload)</string>\
        <key>PayloadVersion</key><integer>1</integer><key>PayloadDisplayName</key><string>JTKTEST Preferences</string>\
        <key>PayloadContent</key><dict><key>\(LiveMigrationTests.domain)</key><dict><key>Forced</key><array><dict>\
        <key>mcx_preference_settings</key><dict><key>\(LiveMigrationTests.key)</key><true/></dict>\
        </dict></array></dict></dict>\
        </dict></array></dict></plist>
        """
        let xml = """
        <os_x_configuration_profile><general><name>\(Self.escape(name))</name>\
        <description>Release check test object; removed after the run</description>\
        <distribution_method>Install Automatically</distribution_method><user_removable>false</user_removable>\
        <level>System</level><redeploy_on_update>Newly Assigned</redeploy_on_update>\
        <payloads>\(Self.escape(plist))</payloads></general>\
        <scope><all_computers>false</all_computers><all_jss_users>false</all_jss_users></scope></os_x_configuration_profile>
        """
        let response = try await api.send(HTTPRequest(method: "POST", path: JamfClassic.createPath(Self.profiles),
                                                      body: Data(xml.utf8), accept: "application/xml", contentType: "application/xml"),
                                          privilege: .createMacOSConfigurationProfiles)
        return try #require(JamfClassic.createdID(in: response.data).flatMap(Int.init), "The profile create returned no id")
    }

    /// Scopes the test profile to the test Classic group only (a scope-only update).
    func scopeProfile(_ id: Int, toClassicGroup group: String) async throws {
        let xml = "<os_x_configuration_profile><scope><all_computers>false</all_computers><all_jss_users>false</all_jss_users>"
            + "<computers/><computer_groups><computer_group><id>\(group)</id></computer_group></computer_groups>"
            + "<buildings/><departments/><jss_users/><jss_user_groups/></scope></os_x_configuration_profile>"
        _ = try await api.send(HTTPRequest(method: "PUT", path: JamfClassic.path(Self.profiles, id: String(id)),
                                           body: Data(xml.utf8), accept: "application/xml", contentType: "application/xml"),
                               privilege: .updateMacOSConfigurationProfiles)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Test objects

    /// Every Blueprint, device group, Classic profile and Classic computer group
    /// named as a test object. A Classic group also shows as a Platform device group.
    func testObjects(_ run: LiveCheckRun) async throws -> [(resource: String, id: String, name: String)] {
        let blueprints = try await self.blueprints.list().filter { run.isSweepable($0.name) }
        let groups = try await api.deviceGroups().filter { run.isSweepable($0.name) }
        let profileList = try await api.send(HTTPRequest(path: "proclassic/\(Self.profiles)", accept: "application/json"),
                                             privilege: .readMacOSConfigurationProfiles)
        let profiles = try ClassicProfileList.parse(profileList.data, platform: .macOS).filter { run.isSweepable($0.name) }
        let classicGroups = try await api.classicGroups(.computer).filter { run.isSweepable($0.name) }
        return blueprints.map { ("blueprints", $0.id, $0.name) }
            + profiles.map { (Self.profiles, String($0.key.id), $0.name) }
            + groups.map { ("device-groups", $0.id, $0.name) }
            + classicGroups.map { (Self.classicGroups, $0.id, $0.name) }
    }

    /// Deletes a test object. Its answer, 404 included, never counts: JTKit's
    /// read-back (0.12.6) marks it removed only once the object is gone, and
    /// a leftover fails the run.
    func delete(resource: String, id: String) async throws {
        let request: HTTPRequest
        let privilege: JamfPro.Privilege?
        switch Ledger.Item(target: "", resource: resource, id: "", name: "").resource {
        case "blueprints":
            request = HTTPRequest(method: "DELETE", path: "\(JamfPlatform.Blueprints.path)/\(JamfPlatform.pathSegment(id))", safeToRepeat: true)
            privilege = nil
        case "devicegroups":
            request = HTTPRequest(method: "DELETE", path: "\(JamfPlatform.Client.deviceGroupsPath)/\(JamfPlatform.pathSegment(id))", safeToRepeat: true)
            privilege = .deleteStaticComputerGroups
        case Self.profiles:
            request = HTTPRequest(method: "DELETE", path: JamfClassic.path(Self.profiles, id: id), accept: "application/xml", safeToRepeat: true)
            privilege = .deleteMacOSConfigurationProfiles
        case Self.classicGroups:
            request = HTTPRequest(method: "DELETE", path: JamfClassic.path(Self.classicGroups, id: id), accept: "application/xml", safeToRepeat: true)
            privilege = .deleteStaticComputerGroups
        default:
            throw PipelineError(message: "No way to remove \(resource) \(id)")
        }
        do {
            _ = try await api.send(request, privilege: privilege)
        } catch let error as JamfPlatformError where error.status == 404 {
            return
        }
    }

    /// Deletes a group once nothing uses it any more. Jamf removes a deleted
    /// Blueprint in the background, and until then refuses the group's delete
    /// with 422 HAS_DEPENDENCIES (seen 2026-10-28 in AppSettings2Blueprint); a
    /// Classic group still in a profile's scope may be refused with 409. Only
    /// those answers are retried, for up to two minutes.
    func deleteGroupWhenFree(resource: String, id: String) async throws {
        let deadline = Date().addingTimeInterval(120)
        while true {
            do {
                return try await delete(resource: resource, id: id)
            } catch let error as JamfPlatformError
                        where (error.status == 422 && error.hasDependencies || error.status == 409) && Date() < deadline {
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Waits until a deleted Blueprint is gone (404), up to two minutes.
    func waitUntilBlueprintGone(id: String) async throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            do {
                _ = try await blueprints.detail(id: id)
            } catch let error as JamfPlatformError where error.status == 404 {
                return
            }
            try await Task.sleep(for: .seconds(3))
        }
    }

    /// Removes test objects in an order Jamf accepts: Blueprints, then
    /// profiles, then the groups they used.
    static func removalOrder(_ items: [Ledger.Item]) -> [Ledger.Item] {
        let rank = ["blueprints": 0, profiles: 1, "devicegroups": 2, classicGroups: 3]
        return items.enumerated().sorted { (rank[$0.element.resource] ?? 9, $0.offset) < (rank[$1.element.resource] ?? 9, $1.offset) }
            .map(\.element)
    }
}

private extension JamfPlatformError {
    var hasDependencies: Bool {
        body?.errors.contains { $0.code == "HAS_DEPENDENCIES" } == true
    }
}

/// Which profile the app's scope change may touch. Any other is refused
/// before a request is made, and the check stops.
final class ScopeFence: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: ProfileKey?
    private var touched: [ProfileKey] = []
    private var refused: [ProfileKey] = []

    func allow(_ key: ProfileKey) { lock.withLock { allowed = key } }
    var writes: [ProfileKey] { lock.withLock { touched } }
    var refusals: [ProfileKey] { lock.withLock { refused } }

    func check(_ key: ProfileKey) throws {
        try lock.withLock {
            guard key == allowed else {
                refused.append(key)
                throw ScopeChangeError(message: "The app's scope change would touch profile \(key.id), not this run's profile; stopped.")
            }
            touched.append(key)
        }
    }
}

/// The app's scope writer behind the fence.
struct FencedScopeWriter: ClassicScopeWriter {
    let fence: ScopeFence
    let inner: any ClassicScopeWriter

    func replaceScope(key: ProfileKey, body: Data) async throws {
        try fence.check(key)
        try await inner.replaceScope(key: key, body: body)
    }
}

/// Waits until `condition` holds, checking every half second.
@MainActor
func waitUntil(_ seconds: Double, _ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try await Task.sleep(for: .milliseconds(500))
    }
    return true
}

/// This run's folder for the app's files, in the test host's temporary
/// directory (inside the app's container), never Application Support.
func liveFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "pb-live-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return folder
}

/// Records a failed step and names the missing Jamf privilege when the tenant refused one.
func failure(_ error: any Error) -> String {
    if let error = error as? JamfPlatformError, error.status == 401 || error.status == 403 {
        return "MISSING PRIVILEGE on the API client's role: \(error.localizedDescription)"
    }
    return error.localizedDescription
}

// MARK: Stage 1: sign in

@MainActor
@Suite("Live: sign in", .enabled(if: live), .serialized)
struct LiveSignInTests {
    /// A sign-in and small reads (Blueprints, device groups, Classic profiles
    /// and computer groups), plus a count of left-over test objects. Reads only.
    @Test func signInAndRead() async throws {
        let run = try LiveCheckRun.current()
        let folder = try liveFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let target = try LiveTenant(run: run, folder: folder)
            let leftovers = try await target.testObjects(run).count
            run.record(step: "sign in: \(LiveTenant.role)", passed: true, note: "\(leftovers) left-over test objects")
        } catch {
            run.record(step: "sign in: \(LiveTenant.role)", passed: false, note: failure(error))
            throw error
        }
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }
}

// MARK: Stage 4: the main task, live

@MainActor
@Suite("Live: profile, groups, migrate, scope change, deploy, read back, remove", .enabled(if: live), .serialized)
struct LiveMigrationTests {
    static let domain = "com.example.jtktest"
    static let key = "JTKTESTFlag"

    @Test func tenantA() async throws {
        let run = try LiveCheckRun.current()
        guard run.roles.contains(LiveTenant.role) else { return }
        let folder = try liveFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = try LiveTenant(run: run, folder: folder)
        let ledgerTarget = try run.target(role: LiveTenant.role, service: LiveTenant.service)
        let step = { (name: String) in "\(LiveTenant.role): \(name)" }
        /// Runs a step; a refusal by the tenant is reported with the privilege it needs.
        func attempt<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
            do {
                return try await body()
            } catch {
                run.record(step: step(name), passed: false, note: failure(error))
                throw error
            }
        }

        // 1. An empty static Platform group, for the Blueprint.
        let groupName = "\(run.prefix) – Group"
        let groupID = try await attempt("create an empty static device group") { try await target.createEmptyStaticGroup(name: groupName) }
        let group = try await target.platformGroupIsEmptyStatic(id: groupID)
        run.record(step: step("create an empty static device group"), passed: group.empty, note: group.note)
        try #require(group.empty, "The test group isn't an empty static group; nothing is created or deployed")

        // 2. An empty static Classic computer group, for the profile.
        let classicGroupName = "\(run.prefix) – Classic Group"
        let classicGroupID = try await attempt("create an empty static Classic group") { try await target.createEmptyClassicGroup(name: classicGroupName) }
        let classicGroup = try await target.classicGroupIsEmptyStatic(id: classicGroupID)
        run.record(step: step("create an empty static Classic group"), passed: classicGroup.empty, note: classicGroup.note)
        try #require(classicGroup.empty, "The Classic test group isn't an empty static group; nothing is scoped to it")

        // 3. The profile, scoped to nothing; then scoped to the Classic group only.
        let profileName = "\(run.prefix) – Profile"
        let profileID = try await attempt("create a profile scoped to nothing") { try await target.createProfile(name: profileName) }
        let key = ProfileKey(platform: .macOS, id: profileID)
        let created = try await target.classic.profile(key: key)
        let unscoped = !ClassicScopeService.hasTargets(created.scope)
        run.record(step: step("create a profile scoped to nothing"), passed: unscoped)
        try #require(unscoped, "The new profile has scope targets")
        try await attempt("scope the profile to the Classic group") { try await target.scopeProfile(profileID, toClassicGroup: classicGroupID) }
        let scoped = try await target.classic.profile(key: key)
        let onlyTheGroup = Self.isScopedToOnly(scoped.scope, group: classicGroupID)
        run.record(step: step("scope the profile to the Classic group only"), passed: onlyTheGroup)
        try #require(onlyTheGroup, "The profile isn't scoped to the Classic group only")

        // 4. Migrate with the app's own path: the workspace loads the tenant's
        //    profiles and groups, the session grades, maps scope, dry-runs,
        //    creates and verifies. The app's scope step is armed.
        let fence = ScopeFence()
        fence.allow(key)
        let workspace = target.workspace(fence: fence)
        workspace.reload()
        let loaded = try await waitUntil(300) { Self.finishedLoading(workspace) }
        try #require(loaded && workspace.listPhase == .loaded, "The workspace didn't load: \(workspace.listPhase)")
        let session = try #require(workspace.session(for: key), "The test profile isn't in the workspace")
        let mapped = session.selectedGroupIDs
        #expect(session.report.status != .blocked, "\(session.report.reasons.map(\.title))")
        // The Blueprint goes to the empty Platform group only, picked as a user would.
        for id in session.selectedGroupIDs where id != groupID { session.toggleGroup(id) }
        if !session.selectedGroupIDs.contains(groupID) { session.toggleGroup(groupID) }
        session.blueprintName = "\(run.prefix) – Blueprint"
        session.blueprintDescription = "Release check test object; removed after the run"
        session.acknowledgedWarnings = true
        await session.runDryRun()
        try #require(session.lastError == nil, "Dry run: \(session.lastError.map { String(describing: $0) } ?? "")")
        session.dryRun = false
        session.unscopeAfterDeploy = true
        await session.create()
        let blueprintID = try #require(session.blueprintID, "Create: \(session.lastError.map { String(describing: $0) } ?? "no Blueprint")")
        let fidelity = session.fidelity?.passed == true
        run.record(step: step("migrate with the app (dry run, create, verify)"), passed: fidelity,
                   note: "scope mapping proposed \(mapped.count) group(s); \(session.fidelity?.mismatches.count ?? -1) mismatches")
        try #require(fidelity, "The app's verification didn't pass: \(session.fidelity?.mismatches.map(\.field) ?? [])")
        // Only with `release-check.sh --fault fail-live-step`: fails with
        // objects on the tenant, so cleanup has to remove them.
        try run.injectFault("fail-live-step", at: step("failure after creating objects"))

        // 5. Deploy with the app's own Deploy, only while the group still has no members.
        let beforeDeploy = try await target.platformGroupIsEmptyStatic(id: groupID)
        try #require(beforeDeploy.empty, "The test group has members now; not deploying (\(beforeDeploy.note))")
        await session.deploy(DeployConfirmation(blueprintID: blueprintID, blueprintName: session.blueprintName,
                                                groupNames: session.selectedGroups.map(\.name), deviceCount: session.deviceCount,
                                                confirmedAt: Date()))
        let deployed: Bool = if case .succeeded = session.outcome { true } else { false }
        run.record(step: step("deploy to the empty group"), passed: deployed,
                   note: session.lastError.map { String(describing: $0) } ?? session.deployment?.displayText)
        try #require(deployed, "The deployment didn't succeed")

        // 6. The app's scope step: with no device in the group the deployment
        //    isn't "clean" (nothing succeeded), so the app must not change the
        //    profile's scope by itself.
        let deferred: Bool = if case .waiting = session.unscopeStatus { true } else { false }
        let untouched = Self.isScopedToOnly(try await target.classic.profile(key: key).scope, group: classicGroupID)
        let guardHeld = deferred && !session.canUnscopeNow && fence.writes.isEmpty && untouched
        run.record(step: step("the app's scope step waits for a clean deployment"), passed: guardHeld,
                   note: "status \(session.unscopeStatus), \(fence.writes.count) scope writes")
        try #require(guardHeld, "The app changed or offered to change the scope after a deployment to no devices")
        session.unscopeAfterDeploy = false

        // 7. The app's scope change itself (what the session runs once a
        //    deployment is clean): backup, scope-only update, read back, payloads checked.
        let backups = workspace.scopeBackups
        let unscope = try await attempt("remove the profile's scope with the app") {
            try await ClassicScopeService.unscope(key: key, blueprintID: blueprintID, environment: workspace.environment, backups: backups)
        }
        let after = unscope.after
        let asIntended = !ClassicScopeService.hasTargets(after.scope)
            && after.scope.limitations == scoped.scope.limitations && after.scope.exclusions == scoped.scope.exclusions
            && after.payloadsPlist == scoped.payloadsPlist
        let savedBackup = await backups.all.contains { $0.id == unscope.backup.id && $0.scopeXML.contains("<id>\(classicGroupID)</id>") }
        let onlyThisProfile = fence.writes == [key] && fence.refusals.isEmpty
        run.record(step: step("remove the profile's scope with the app"), passed: asIntended && savedBackup && onlyThisProfile,
                   note: "backup in the run's temporary folder: \(savedBackup); scope writes \(fence.writes.map(\.id))")
        try #require(asIntended && savedBackup && onlyThisProfile, "The scope change didn't end as the app intends")

        // 8. Restore with the app, as after a relaunch: a new workspace on the
        //    same files finds the backup and the migration.
        let reopened = target.workspace(fence: fence)
        reopened.reload()
        let reloaded = try await waitUntil(300) { Self.finishedLoading(reopened) }
        try #require(reloaded && reopened.listPhase == .loaded, "The workspace didn't load again: \(reopened.listPhase)")
        let resumed = try #require(reopened.session(for: key), "The test profile isn't in the reopened workspace")
        let ready = try await waitUntil(120) { resumed.scopeBackup != nil && resumed.blueprintID == blueprintID && !resumed.isBusy && !resumed.isRestoring }
        try #require(ready && resumed.canRestoreScope, "The reopened migration doesn't offer Restore (\(resumed.lastError.map { String(describing: $0) } ?? "no error"))")
        await resumed.restoreClassicScope()
        let restored = Self.isScopedToOnly(try await target.classic.profile(key: key).scope, group: classicGroupID)
        // The reopened workspace's store wrote the file; read it as saved.
        let saved = await ScopeBackupStore(fileURL: folder.appending(path: "scope-backups.json")).all
        let marked = saved.first { $0.id == unscope.backup.id }?.restoredAt != nil
        let restoredOK = resumed.lastError == nil && restored && marked && fence.writes == [key, key] && fence.refusals.isEmpty
        run.record(step: step("restore the profile's scope with the app"), passed: restoredOK,
                   note: "scoped to the Classic group only: \(restored); backup marked restored: \(marked)")
        try #require(restoredOK, "The restore didn't bring the scope back: \(resumed.lastError.map { String(describing: $0) } ?? "")")

        // 9. Read back: the Blueprint holds what the profile held, scoped to the empty group, deployed.
        let readBack = try await target.blueprints.detail(id: blueprintID)
        let component = readBack.components.first { $0.identifier == BlueprintBuilder.componentIdentifier }
        let payloads = component?.json["configuration"]?["payloadContent"]?.arrayValue ?? []
        let types = payloads.compactMap { $0["payloadType"]?.stringValue ?? $0["PayloadType"]?.stringValue }
        let values = payloads.flatMap { Self.values(of: Self.key, under: Self.domain, in: $0) }
        let source = try #require(try? scoped.document.get())
        let holds = types == source.payloads.compactMap(\.type) && values == [.bool(true)]
            && readBack.scopeDeviceGroups == [groupID]
            && readBack.overview.deploymentState?.isDeployedSuccessfully == true
        run.record(step: step("read back: the Blueprint holds the profile's payload"), passed: holds,
                   note: "types \(types), \(Self.key) \(values), scope \(readBack.scopeDeviceGroups.count) group(s)")
        #expect(holds)

        // 10. The app's history went to this run's folder.
        let history = HistoryStore(fileURL: folder.appending(path: "history.json"))
        let wanted: Set<MigrationAction> = [.dryRun, .create, .verify, .deploy, .deploymentResult, .unscopeClassic, .restoreClassicScope]
        _ = try await waitUntil(10) { Set(target.model.history.records.map(\.action)).isSuperset(of: wanted) }
        let written = Set(await history.all.filter { $0.sourceProfileID == profileID }.map(\.action))
        run.record(step: step("history in the run's temporary folder"), passed: written.isSuperset(of: wanted),
                   note: written.map(\.rawValue).sorted().joined(separator: ", "))
        #expect(written.isSuperset(of: wanted))

        // 11. Remove the Blueprint, the profile, then both groups.
        try await target.delete(resource: "blueprints", id: blueprintID)
        try await target.waitUntilBlueprintGone(id: blueprintID)
        try await target.delete(resource: LiveTenant.profiles, id: String(profileID))
        try await target.deleteGroupWhenFree(resource: "device-groups", id: groupID)
        try await target.deleteGroupWhenFree(resource: LiveTenant.classicGroups, id: classicGroupID)
        let mine: Set<String> = [blueprintID, String(profileID), groupID, classicGroupID]
        let left = try await target.testObjects(run).filter { mine.contains($0.id) || $0.name.hasPrefix(run.prefix) }
        #expect(left.isEmpty, "still there: \(left.map(\.name))")
        run.record(step: step("remove the Blueprint, the profile and both groups"), passed: left.isEmpty)
        #expect(run.ledger.outstanding.filter { $0.target == ledgerTarget }.isEmpty)
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }

    /// The list and every profile's details have loaded, or loading failed.
    /// (`reload()` starts in the background, so `.idle` means not started yet.)
    static func finishedLoading(_ workspace: Workspace) -> Bool {
        switch workspace.listPhase {
        case .loaded: !workspace.isLoadingDetails
        case .failed: true
        case .idle, .loading: false
        }
    }

    static func isScopedToOnly(_ scope: ClassicScope, group: String) -> Bool {
        scope.deviceGroups.map(\.identity) == [group] && !scope.allDevices && !scope.allJSSUsers
            && scope.devices.isEmpty && scope.buildings.isEmpty && scope.departments.isEmpty && scope.otherTargets.isEmpty
    }

    /// The values of `key` in any dictionary below a `domain` key.
    static func values(of key: String, under domain: String, in json: LosslessJSON) -> [LosslessJSON] {
        func all(_ json: LosslessJSON, inside: Bool) -> [LosslessJSON] {
            switch json {
            case let .object(object):
                return object.members.flatMap { member -> [LosslessJSON] in
                    (inside && member.key == key ? [member.value] : []) + all(member.value, inside: inside || member.key == domain)
                }
            case let .array(items):
                return items.flatMap { all($0, inside: inside) }
            default:
                return []
            }
        }
        return all(json, inside: false)
    }
}

// MARK: Cleanup (every exit of stage 4)

@MainActor
@Suite("Live: cleanup", .enabled(if: live), .serialized)
struct LiveCleanupTests {
    /// Deletes what the run's ledger still lists (with what an earlier run's
    /// live folder left), then sweeps the tenant for anything still named as a
    /// test object: Blueprints, then profiles, then groups. Fails if anything is left.
    @Test func removeTestObjects() async throws {
        let run = try LiveCheckRun.current()
        let temporary = FileManager.default.temporaryDirectory
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [] where folder.hasPrefix("pb-live-") {
            try? FileManager.default.removeItem(at: temporary.appending(path: folder))
        }
        let folder = try liveFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = try LiveTenant(run: run, folder: folder)
        let ledgerTarget = try run.target(role: LiveTenant.role, service: LiveTenant.service)
        for object in try await target.testObjects(run) {
            try run.adoptForSweep(role: LiveTenant.role, service: LiveTenant.service,
                                  resource: object.resource, id: object.id, name: object.name)
        }
        for item in LiveTenant.removalOrder(run.ledger.outstanding.filter { $0.target == ledgerTarget }) {
            do {
                if item.resource == "blueprints" {
                    try await target.delete(resource: item.resource, id: item.id)
                    try await target.waitUntilBlueprintGone(id: item.id)
                } else if item.resource == LiveTenant.profiles {
                    try await target.delete(resource: item.resource, id: item.id)
                } else {
                    try await target.deleteGroupWhenFree(resource: item.resource, id: item.id)
                }
            } catch {
                run.record(step: "cleanup: \(item.resource) \(item.id)", passed: false, note: failure(error))
            }
        }
        // The ledger must be empty, and nothing named as a test object may be left.
        // (Deleting a Classic group also removes its device-group twin; the
        // twin's delete then answers 404, which counts as removed.)
        let left = run.ledger.outstanding
        let still = try await target.testObjects(run)
        let clean = left.isEmpty && still.isEmpty
        run.record(step: "cleanup", passed: clean,
                   note: clean ? nil : "\(left.count) in the ledger and \(still.count) on the tenant not removed")
        #expect(left.isEmpty, "\(left.map { "\($0.resource) \($0.id) \($0.name)" })")
        #expect(still.isEmpty, "\(still.map { "\($0.resource) \($0.id) \($0.name)" })")
    }
}
