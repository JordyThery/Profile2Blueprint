import Foundation
import JTKit
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
        let output = Redaction.text(input)
        #expect(output.contains(Redaction.placeholder))
        #expect(!output.contains("topsecret"))
        #expect(!output.contains("eyJ"))
    }

    @Test("Ordinary text passes through unchanged")
    func passthrough() {
        let text = #"{"httpStatus":400,"errors":{"code":"INVALID_FIELD"}}"#
        #expect(Redaction.text(text) == text)
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

    @Test("Retry backoff doubles and is capped (JTKit's shared rules)")
    func backoff() {
        let rules = RetryRules.standard
        #expect((1...3).map { rules.backoff(afterAttempt: $0, random: 0) } == [1, 2, 4])
        #expect(rules.backoff(afterAttempt: 9, random: 1) == 120)
    }
}
