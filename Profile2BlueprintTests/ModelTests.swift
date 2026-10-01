import Foundation
import Testing
@testable import Profile2Blueprint

@Suite("Tenant & persistence")
struct TenantTests {

    @Test("Production host is derived from the region", arguments: Region.allCases)
    func productionHost(region: Region) {
        let tenant = Tenant(region: region)
        #expect(tenant.host == "\(region.rawValue).api.jamfcloud.com")
        #expect(tenant.baseURL?.absoluteString == "https://\(region.rawValue).api.jamfcloud.com")
        #expect(!tenant.usesHostOverride)
    }

    @Test("Host override strips scheme and trailing slash and stays HTTPS")
    func hostOverride() {
        let tenant = Tenant(hostOverride: "http://us1.api.stage.platform.jamflabs.com/")
        #expect(tenant.host == "us1.api.stage.platform.jamflabs.com")
        #expect(tenant.baseURL?.scheme == "https")
        #expect(tenant.usesHostOverride)
    }

    @Test("Validation flags a malformed environment ID and missing client ID")
    func validation() {
        #expect(Tenant(environmentID: "nope", clientID: "").validationIssues.count == 2)
        let valid = Tenant(environmentID: "E77C1408-10C8-4007-B177-ABC9157FBCAA", clientID: "abc")
        #expect(valid.validationIssues.isEmpty)
        #expect(valid.normalizedEnvironmentID == "e77c1408-10c8-4007-b177-abc9157fbcaa")
    }

    @Test("Tenant store round-trips without writing secrets")
    func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "p2b-\(UUID().uuidString)/tenants.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TenantStore(fileURL: url)
        let tenant = Tenant(name: "Prod", region: .eu, environmentID: UUID().uuidString, clientID: "client")
        try store.save(TenantConfiguration(tenants: [tenant], currentTenantID: tenant.id))

        #expect(store.load() == TenantConfiguration(tenants: [tenant], currentTenantID: tenant.id))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.localizedCaseInsensitiveContains("secret"))
    }

    @MainActor
    @Test("AppModel stores the secret in the secret store, not the tenant file")
    func appModelSecrets() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "p2b-\(UUID().uuidString)/tenants.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let secrets = InMemorySecretStore()
        let model = AppModel(
            store: TenantStore(fileURL: url),
            secrets: secrets,
            history: HistoryStore(fileURL: url.deletingLastPathComponent().appending(path: "history.json")),
            demoMode: false
        )

        var tenant = model.addTenant()
        #expect(model.currentTenantID == tenant.id)
        tenant.clientID = "client"
        model.save(tenant, secret: "hunter2")

        #expect(try secrets.secret(for: tenant.id.uuidString) == "hunter2")
        #expect(model.hasStoredSecret(for: tenant.id))
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("hunter2"))

        model.delete(tenant.id)
        #expect(try secrets.secret(for: tenant.id.uuidString) == nil)
        #expect(model.currentTenantID == nil)
    }
}

@Suite("Redaction")
struct RedactionTests {

    @Test("Tokens and secrets are removed from text", arguments: [
        #"{"access_token":"eyJabc.def","expires_in":900}"#,
        "grant_type=client_credentials&client_id=x&client_secret=topsecret",
        "Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.payload.sig",
        #"{"client_secret": "topsecret"}"#,
    ])
    func redacts(input: String) {
        let output = Redactor.redact(input)
        #expect(output.contains(Redactor.placeholder))
        #expect(!output.contains("topsecret"))
        #expect(!output.contains("eyJ"))
    }

    @Test("Ordinary text passes through unchanged")
    func passthrough() {
        let text = #"{"httpStatus":400,"errors":{"code":"INVALID_FIELD"}}"#
        #expect(Redactor.redact(text) == text)
    }
}

@Suite("API error decoding")
struct APIErrorBodyTests {

    @Test("errors may be an object or an array")
    func objectOrArray() throws {
        let single = try #require(APIErrorBody.parse(Data(#"{"traceId":"a","errors":{"code":"X","description":"d"}}"#.utf8)))
        let many = try #require(APIErrorBody.parse(Data(#"{"traceId":"a","errors":[{"code":"X","description":"d"},{"code":"Y","field":"f","description":"e"}]}"#.utf8)))
        #expect(single.errors.map(\.code) == ["X"])
        #expect(many.errors.map(\.code) == ["X", "Y"])
        #expect(many.errors[1].field == "f")
    }

    @Test("Non-error bodies are not mistaken for errors")
    func nonError() {
        #expect(APIErrorBody.parse(Data("<html>bad gateway</html>".utf8)) == nil)
        #expect(APIErrorBody.parse(Data("{}".utf8)) == nil)
    }

    @Test("Retry backoff is exponential and capped")
    func backoff() {
        let policy = RetryPolicy(maxRetries: 5, baseDelay: .seconds(1), maxDelay: .seconds(5))
        #expect((0..<5).map(policy.delay(forAttempt:)) == [.seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5)])
    }
}
