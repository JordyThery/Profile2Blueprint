import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

/// tenants.json as the app wrote it before JTKit's connections (same shape and
/// formatting as a real one, with made-up values).
private let savedBeforeJTKit = #"""
{
  "currentTenantID" : "A2A2A2A2-0000-4000-8000-000000000002",
  "tenants" : [
    {
      "allowClassicScopeChanges" : true,
      "clientID" : "11111111-aaaa-bbbb-cccc-222222222222",
      "descriptionTemplate" : "Migrated from Jamf Pro classic {platform} configuration profile ID {id} (“{name}”) by Profile2Blueprint.",
      "environmentID" : "0f0e0d0c-0b0a-4000-8000-00000000abcd",
      "id" : "A1A1A1A1-0000-4000-8000-000000000001",
      "jamfProURL" : "https:\/\/example.jamfcloud.com",
      "name" : "Jamf Pro",
      "naming" : {
        "prefix" : "",
        "suffix" : " (migrated)"
      },
      "region" : "eu"
    },
    {
      "allowClassicScopeChanges" : false,
      "clientID" : "33333333-aaaa-bbbb-cccc-444444444444",
      "descriptionTemplate" : "Migrated from Jamf Pro classic {platform} configuration profile ID {id} (“{name}”) by Profile2Blueprint.",
      "environmentID" : "0f0e0d0c-0b0a-4000-8000-00000000abce",
      "hostOverride" : "staging.example.com",
      "id" : "A2A2A2A2-0000-4000-8000-000000000002",
      "jamfProURL" : "",
      "name" : "Sandbox",
      "naming" : {
        "prefix" : "TEST - ",
        "suffix" : ""
      },
      "region" : "us"
    }
  ]
}
"""#

private let jamfProID = UUID(uuidString: "A1A1A1A1-0000-4000-8000-000000000001")!
private let sandboxID = UUID(uuidString: "A2A2A2A2-0000-4000-8000-000000000002")!

@MainActor
@Suite("Tenants in JTKit's connections")
struct TenantConnectionsTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "p2b-connections-\(UUID().uuidString)")
    var fileURL: URL { folder.appending(path: "tenants.json") }

    private func writeSavedFile(_ text: String = savedBeforeJTKit) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL)
    }

    private func makeModel(secrets: InMemorySecretStore = InMemorySecretStore()) -> AppModel {
        AppModel(
            store: TenantStore(fileURL: fileURL),
            secrets: secrets,
            history: HistoryStore(fileURL: folder.appending(path: "history.json")),
            demoMode: false
        )
    }

    private func fileText() throws -> String {
        try String(contentsOf: fileURL, encoding: .utf8)
    }

    @Test func tenantsAndTheCurrentTenantSavedBeforeJTKitAreRead() throws {
        try writeSavedFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel()

        #expect(model.connections.problem == nil)
        #expect(model.tenants.map(\.name) == ["Jamf Pro", "Sandbox"])
        #expect(model.currentTenantID == sandboxID)
        let sandbox = try #require(model.tenant(id: sandboxID))
        #expect(sandbox.hostOverride == "staging.example.com")
        #expect(sandbox.naming == BlueprintNaming(prefix: "TEST - ", suffix: ""))
        #expect(model.tenant(id: jamfProID)?.allowClassicScopeChanges == true)
        #expect(model.tenant(id: jamfProID)?.jamfProURL == "https://example.jamfcloud.com")
    }

    @Test func savingAnUnchangedTenantWritesTheSameBytes() throws {
        try writeSavedFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel()

        try model.connections.save(try #require(model.tenant(id: jamfProID)))
        #expect(try fileText() == savedBeforeJTKit)
    }

    @Test func editingTheNameChangesOnlyThatLineAndKeepsTheCurrentTenant() throws {
        try writeSavedFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel()

        var tenant = try #require(model.tenant(id: jamfProID))
        tenant.connection.name = "Jamf Pro Production"
        try model.connections.save(tenant)

        let expected = savedBeforeJTKit.replacingOccurrences(of: #""name" : "Jamf Pro","#,
                                                             with: #""name" : "Jamf Pro Production","#)
        #expect(try fileText() == expected)
        #expect(model.currentTenantID == sandboxID)
    }

    @Test func readingAndSettingTheConnectionLeavesEveryTenantUnchanged() throws {
        try writeSavedFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        for var tenant in makeModel().tenants {
            let before = tenant
            tenant.connection = tenant.connection
            #expect(tenant == before)
        }
    }

    @Test func connectionFieldsMapToTheTenantsOwnFields() {
        var tenant = Tenant(name: "Prod", region: .eu, environmentID: "env", clientID: "client", jamfProURL: "jamf.example.com")
        let connection = tenant.connection
        #expect(connection.service == .jamfPlatform)
        #expect(connection.region == .eu)
        #expect(connection.hostOverride.isEmpty)
        #expect(connection.jamfProWebURL == "jamf.example.com")

        var edited = connection
        edited.hostOverride = "staging.example.com"
        tenant.connection = edited
        #expect(tenant.hostOverride == "staging.example.com")
        #expect(tenant.listBadge != nil)
        edited.hostOverride = ""
        tenant.connection = edited
        // no override is saved as a missing key, as before
        #expect(tenant.hostOverride == nil)
    }

    @Test func changingTheCurrentTenantKeepsTheTenants() throws {
        try writeSavedFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel()

        model.makeCurrent(jamfProID)
        let expected = savedBeforeJTKit.replacingOccurrences(of: #""currentTenantID" : "A2A2A2A2-0000-4000-8000-000000000002""#,
                                                             with: #""currentTenantID" : "A1A1A1A1-0000-4000-8000-000000000001""#)
        #expect(try fileText() == expected)
        #expect(makeModel().currentTenantID == jamfProID)
    }

    @Test func theFirstSaveBacksUpTheOriginalOnce() throws {
        try writeSavedFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel()
        let backup = fileURL.appendingPathExtension("backup")

        model.makeCurrent(jamfProID)
        #expect(try String(contentsOf: backup, encoding: .utf8) == savedBeforeJTKit)
        var tenant = try #require(model.tenant(id: jamfProID))
        tenant.name = "Renamed"
        try model.connections.save(tenant)
        // still the data as it was before JTKit first saved it
        #expect(try String(contentsOf: backup, encoding: .utf8) == savedBeforeJTKit)
    }

    @Test func anUnreadableFileIsKeptCopiedAndNeverSavedOver() throws {
        let broken = String(savedBeforeJTKit.dropLast(20))
        try writeSavedFile(broken)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel()

        #expect(model.connections.problem != nil)
        #expect(model.persistenceError != nil)
        #expect(model.tenants.isEmpty)
        #expect(throws: ConnectionStoreError.self) {
            try model.connections.save(Tenant(name: "New tenant"))
        }
        model.makeCurrent(nil)
        #expect(try fileText() == broken)
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("tenants.json.unreadable-") }
        #expect(copies.count == 1)
    }

    @Test func secretsGoToTheKeychainItemsTheyAlwaysUsedNeverTheFile() throws {
        try writeSavedFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        // as stored by the build before JTKit: account = tenant id
        let secrets = InMemorySecretStore([sandboxID.uuidString: "stored-before"])
        let model = makeModel(secrets: secrets)
        let sandbox = try #require(model.tenant(id: sandboxID))
        #expect(model.connections.secret(for: sandbox.connection) == "stored-before")

        try model.connections.save(sandbox, secrets: [.main: "hunter2"])
        #expect(secrets.secret(for: sandboxID.uuidString) == "hunter2")
        #expect(try !fileText().contains("hunter2"))
        #expect(model.activity.entries.contains { $0.detail.contains("Stored a new client secret") && $0.detail.contains("Sandbox") })
    }

    @Test func theFirstTenantAddedBecomesCurrentAndDeletingMovesToTheNext() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let secrets = InMemorySecretStore()
        let model = makeModel(secrets: secrets)
        #expect(model.currentTenantID == nil)

        let first = Tenant(name: "First")
        try model.connections.save(first, secrets: [.main: "one"])
        let second = Tenant(name: "Second")
        try model.connections.save(second)
        #expect(model.currentTenantID == first.id)

        try model.connections.delete(id: first.id)
        #expect(secrets.secret(for: first.id.uuidString) == nil)
        #expect(model.currentTenantID == second.id)
        try model.connections.delete(id: second.id)
        #expect(model.currentTenantID == nil)
        #expect(makeModel().currentTenantID == nil)
    }

    @Test func turningClassicCleanupOffIsLoggedAndRebuildsTheWorkspace() throws {
        try writeSavedFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = makeModel()
        model.makeCurrent(jamfProID)
        let generation = model.workspaceGeneration

        var tenant = try #require(model.tenant(id: jamfProID))
        tenant.allowClassicScopeChanges = false
        try model.connections.save(tenant)
        #expect(model.workspaceGeneration > generation)
        #expect(model.activity.entries.contains { $0.category == ActivityCategory.classicWrite.rawValue && $0.detail.contains("turned off") })
    }

    @Test func demoModeIsNeverPartOfTheTenantList() throws {
        try writeSavedFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        // demo mode on from the start, so the test leaves the app's own demo setting alone
        let model = AppModel(
            store: TenantStore(fileURL: fileURL),
            secrets: InMemorySecretStore(),
            history: HistoryStore(fileURL: folder.appending(path: "history.json")),
            demoMode: true
        )

        #expect(try model.activeWorkspace().environment.isDemo)
        #expect(model.currentTenantID == sandboxID)
        #expect(model.tenants.count == 2)
        #expect(try fileText() == savedBeforeJTKit)
    }

    @Test func aFailedTestShowsTheSameDetailsAsTheErrorPanel() throws {
        let body = try #require(JamfPlatform.ErrorBody(data: Data(#"{"httpStatus":403,"traceId":"trace-1","errors":[{"code":"FORBIDDEN","field":"scope","description":"Missing permission"}]}"#.utf8)))
        let report = ErrorReport(JamfPlatform.APIError(.status(403, body: body, text: nil, method: "GET", path: "/groups")))
        let error = ConnectionTestError(report: report)
        #expect(error.errorDescription == report.title)
        #expect(error.failureReason == report.detailText)
        #expect(error.failureReason?.hasPrefix("FORBIDDEN (scope): Missing permission\nTrace ID: trace-1\n") == true)
    }
}

/// A secret store that gives its own answers to JTKit's throwing calls, so the
/// tests can tell a forwarded answer from JTKit's default one.
private final class AnsweringSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var log: [String] = []
    var writeStatus: OSStatus?
    var readStatus: OSStatus?

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    var calls: [String] { lock.withLock { log } }

    func secret(for account: String) -> String? {
        lock.withLock { log.append("secret"); return values[account] }
    }

    func setSecret(_ secret: String?, for account: String) -> Bool {
        lock.withLock {
            log.append("setSecret")
            values[account] = secret
            return true
        }
    }

    func writeSecret(_ secret: String?, for account: String) throws {
        try lock.withLock {
            log.append("writeSecret")
            if let writeStatus { throw SecretWriteError(status: writeStatus) }
            values[account] = secret
        }
    }

    func hasSecret(for account: String) throws -> Bool {
        try lock.withLock {
            log.append("hasSecret")
            if let readStatus { throw SecretStoreError(status: readStatus) }
            return values[account] != nil
        }
    }

    func readSecret(for account: String) throws -> String? {
        try lock.withLock {
            log.append("readSecret")
            if let readStatus { throw SecretStoreError(status: readStatus) }
            return values[account]
        }
    }
}

@Suite("Recording secret store")
struct RecordingSecretStoreTests {

    @Test func writesAreForwardedAndANewSecretIsRecordedAsBefore() throws {
        let base = AnsweringSecretStore()
        let recording = RecordingSecretStore(base)

        try recording.writeSecret("hunter2", for: "a")
        #expect(base.calls == ["writeSecret"])
        #expect(base.secret(for: "a") == "hunter2")
        #expect(recording.takeWrittenAccounts() == ["a"])
        #expect(recording.takeWrittenAccounts().isEmpty)

        // deleting isn't a new secret, with either call
        try recording.writeSecret(nil, for: "a")
        #expect(recording.setSecret(nil, for: "b"))
        #expect(recording.takeWrittenAccounts().isEmpty)

        #expect(recording.setSecret("one", for: "b"))
        #expect(recording.takeWrittenAccounts() == ["b"])
    }

    @Test func aRefusedWriteKeepsTheKeychainsErrorCodeAndIsNotRecorded() {
        let base = AnsweringSecretStore()
        base.writeStatus = -25308
        let recording = RecordingSecretStore(base)

        #expect(throws: SecretWriteError(status: -25308)) { try recording.writeSecret("hunter2", for: "a") }
        #expect(base.calls == ["writeSecret"])
        #expect(recording.takeWrittenAccounts().isEmpty)
    }

    @Test func checksAndReadsAreForwardedWithTheirErrors() throws {
        let base = AnsweringSecretStore(["a": "stored"])
        let recording = RecordingSecretStore(base)
        #expect(try recording.hasSecret(for: "a"))
        #expect(try recording.readSecret(for: "a") == "stored")
        #expect(base.calls == ["hasSecret", "readSecret"])

        base.readStatus = -25308
        #expect(throws: SecretStoreError(status: -25308)) { _ = try recording.hasSecret(for: "a") }
        #expect(throws: SecretStoreError(status: -25308)) { _ = try recording.readSecret(for: "a") }
        #expect(recording.takeWrittenAccounts().isEmpty)
    }

    @MainActor @Test func savingATenantReportsTheKeychainsErrorCodeAndLogsNoNewSecret() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "p2b-recording-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = AnsweringSecretStore()
        let model = AppModel(store: TenantStore(fileURL: folder.appending(path: "tenants.json")),
                             secrets: base,
                             history: HistoryStore(fileURL: folder.appending(path: "history.json")),
                             demoMode: false)
        let tenant = Tenant(name: "Refused")
        try model.connections.save(tenant)
        base.writeStatus = -25308

        #expect(throws: ConnectionStoreError.keychainRefused(status: -25308)) {
            try model.connections.save(tenant, secrets: [.main: "hunter2"])
        }
        #expect(!model.activity.entries.contains { $0.detail.contains("Stored a new client secret") })

        base.writeStatus = nil
        try model.connections.save(tenant, secrets: [.main: "hunter2"])
        #expect(base.calls.contains("writeSecret") && !base.calls.contains("setSecret"))
        #expect(model.activity.entries.contains { $0.detail.contains("Stored a new client secret") && $0.detail.contains("Refused") })
    }
}
