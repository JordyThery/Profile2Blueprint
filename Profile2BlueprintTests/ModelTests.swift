import Foundation
import JTKit
import Testing
@testable import Profile2Blueprint

@Suite("Tenant & persistence")
struct TenantTests {

    @Test("Production host is derived from the region", arguments: JamfRegion.allCases)
    func productionHost(region: JamfRegion) {
        let tenant = Tenant(region: region)
        #expect(tenant.host == "\(region.rawValue).api.jamfcloud.com")
        #expect(tenant.baseURL?.absoluteString == "https://\(region.rawValue).api.jamfcloud.com")
        #expect(!tenant.usesHostOverride)
    }

    @Test("Host override strips scheme and trailing slash and stays HTTPS")
    func hostOverride() {
        let tenant = Tenant(hostOverride: "http://staging.example.com/")
        #expect(tenant.host == "staging.example.com")
        #expect(tenant.baseURL?.scheme == "https")
        #expect(tenant.usesHostOverride)
    }

    @Test("Validation flags a malformed environment ID and missing client ID")
    func validation() {
        #expect(Tenant(environmentID: "nope", clientID: "").validationIssues.count == 2)
        let valid = Tenant(environmentID: "0F0E0D0C-0B0A-4000-8000-00000000ABCD", clientID: "abc")
        #expect(valid.validationIssues.isEmpty)
        #expect(valid.normalizedEnvironmentID == "0f0e0d0c-0b0a-4000-8000-00000000abcd")
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

@Suite("Error panel")
struct ErrorReportTests {

    @Test("A failed request shows JTKit's format: status line, then codes, Trace ID and hints")
    func platformError() {
        let body = JamfPlatform.ErrorBody(httpStatus: 403, traceID: "t-1", errors: [
            .init(code: "BAD_PERMISSIONS", field: "scope", description: "Not allowed"),
        ])
        let report = ErrorReport(JamfPlatform.APIError(.status(403, body: body, text: nil, method: "GET", path: "/device-groups/v1/device-groups")))
        #expect(report.title == "HTTP 403 Forbidden")
        #expect(report.httpStatus == 403)
        #expect(report.traceID == "t-1")
        #expect(report.details.first == "BAD_PERMISSIONS (scope): Not allowed")
        #expect(report.details.contains("Trace ID: t-1"))
        #expect(report.details.contains { $0.contains("Jamf Account") })
    }

    @Test("A refused request says what the app does send")
    func refused() {
        let error = JamfPlatform.APIError(.refused(method: "PUT", path: "proclassic/osxconfigurationprofiles/id/1"))
        let report = ErrorReport(JamfPlatform.APIError(error.kind, appHints: RequestPolicy.hints(for: error)))
        #expect(report.title.hasPrefix("Refused before sending: PUT"))
        #expect(report.details == ["This app only reads, creates and deploys Blueprints, and changes classic scope only when that is explicitly enabled."])
    }

    @Test("The app's own errors show their description and nothing else")
    func appError() {
        let report = ErrorReport(APIError.missingSecret)
        #expect(report.title == APIError.missingSecret.errorDescription)
        #expect(report.detailText == nil)
        #expect(report.httpStatus == nil)
    }
}

@Suite("Retry rules")
struct RetryRuleTests {

    @Test("Retry backoff doubles and is capped (JTKit's shared rules)")
    func backoff() {
        let rules = RetryRules.standard
        #expect((1...3).map { rules.backoff(afterAttempt: $0, random: 0) } == [1, 2, 4])
        #expect(rules.backoff(afterAttempt: 9, random: 1) == 120)
    }
}
