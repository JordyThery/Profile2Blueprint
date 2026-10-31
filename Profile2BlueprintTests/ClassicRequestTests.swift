import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

// JTKit step 7: the Classic profile reads and the scope change use JTKit's
// Classic addresses, list unwrapping and error pages, and name their privilege.

private let base = URL(string: "https://eu.api.jamfcloud.com")!
private let tokenBody = #"{"access_token":"tok","expires_in":900,"token_type":"Bearer"}"#

private func client(policy: ClassicWritePolicy = .scopeOnly) throws -> JamfPlatform.Client {
    let recorder = RequestRecorder(session: MockURLProtocol.makeSession(), log: nil)
    let tokens = JamfPlatform.TokenProvider(tokenURL: base.appending(path: "auth/token"), method: .apiClient(clientID: "c"),
                                   secret: { "s" }, recorder: recorder)
    return try JamfPlatform.Client(baseURL: base, scope: .environment("e77c1408-10c8-4007-b177-abc9157fbcaa"), tokens: tokens,
                                   recorder: recorder, permits: { RequestPolicy.isPermitted($0, classicWrites: policy) },
                                   hints: RequestPolicy.hints(for:), sleep: { _ in })
}

/// The lists exactly as Jamf Pro answered them through the gateway when asked
/// for JSON, read on a test instance on 2026-10-26 (the mobile profile was a
/// fake one made for the check and deleted right after). A list of one is still
/// an array. Jamf labels these answers `text/plain`, not `application/json`.
/// `macOSTwo` and `macOSEmpty` are made up in the same shape.
enum ClassicListAnswers {
    static let macOSOne = #"{"os_x_configuration_profiles":[{"id":49,"name":"Default Plan - Jamf Protect Configuration"}]}"#
    static let mobileOne = #"{"configuration_profiles":[{"id":126,"name":"P2B TEST - JSON shape check - delete me"}]}"#
    static let mobileEmpty = #"{"configuration_profiles":[]}"#
    static let macOSTwo = #"{"os_x_configuration_profiles":[{"id":49,"name":"Default Plan - Jamf Protect Configuration"},{"id":3,"name":"Another"}]}"#
    static let macOSEmpty = #"{"os_x_configuration_profiles":[]}"#
}

/// Jamf's answer as it arrives: JSON labelled `text/plain`.
private func plainText(_ body: String) -> MockResponse {
    MockResponse(status: 200, headers: ["Content-Type": "text/plain;charset=utf-8"], body: Data(body.utf8))
}

private func xml(_ status: Int, _ body: String) -> MockResponse {
    MockResponse(status: status, headers: ["Content-Type": "application/xml"], body: Data(body.utf8))
}

extension NetworkingTests {

    @Test("The profile list is asked for as JSON at the platform's address", arguments: ProfilePlatform.allCases)
    func classicListRequest(platform: ProfilePlatform) async throws {
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return .json(200, tokenBody) }
            return plainText(platform == .macOS ? ClassicListAnswers.macOSOne : ClassicListAnswers.mobileOne)
        }
        let list = try await LiveClassicAPI(client: client()).listProfiles(platform: platform)

        let request = try #require(MockURLProtocol.requests.last)
        #expect(request.method == "GET")
        #expect(request.path.hasSuffix("/proclassic/\(platform.classicResource)"))
        #expect(request.header("Accept") == "application/json")
        #expect(list.count == 1, "a list with exactly one profile is still a list")
        #expect(list.first?.platform == platform)
        #expect(list.first?.profileID == (platform == .macOS ? 49 : 126))
        #expect(list.first?.name == (platform == .macOS ? "Default Plan - Jamf Protect Configuration" : "P2B TEST - JSON shape check - delete me"))
    }

    @Test("Lists keep every profile; empty lists read as empty")
    func classicListShapes() throws {
        let two = try ClassicProfileList.parse(Data(ClassicListAnswers.macOSTwo.utf8), platform: .macOS)
        #expect(two.map(\.profileID) == [49, 3])
        #expect(try ClassicProfileList.parse(Data(ClassicListAnswers.macOSEmpty.utf8), platform: .macOS).isEmpty)
        #expect(try ClassicProfileList.parse(Data(ClassicListAnswers.mobileEmpty.utf8), platform: .mobile).isEmpty)
    }

    @Test("An answer that isn't the platform's list is an error, not an empty list", arguments: [
        #"{"configuration_profiles":[]}"#,          // the other platform's list
        #"{"os_x_configuration_profiles":{"id":1}}"#,
        #"{}"#,
        "<os_x_configuration_profiles><size>0</size></os_x_configuration_profiles>",
        "",
    ])
    func classicListNotAList(body: String) {
        #expect(throws: APIError.self) { try ClassicProfileList.parse(Data(body.utf8), platform: .macOS) }
    }

    @Test("A profile is read as XML at JTKit's Classic address")
    func classicProfileRequest() async throws {
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return .json(200, tokenBody) }
            return xml(200, DemoFixtures.profilesByKey[ProfileKey(platform: .mobile, id: 201)] ?? "")
        }
        _ = try await LiveClassicAPI(client: client()).profile(key: ProfileKey(platform: .mobile, id: 201))

        let request = try #require(MockURLProtocol.requests.last)
        #expect(request.path.hasSuffix("/proclassic/mobiledeviceconfigurationprofiles/id/201"))
        #expect(request.header("Accept") == "application/xml")
    }

    @Test("A scope change is a PUT to JTKit's Classic address")
    func classicScopeRequest() async throws {
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return .json(200, tokenBody) }
            return xml(201, "<os_x_configuration_profile><id>42</id></os_x_configuration_profile>")
        }
        try await LiveClassicScopeWriter(client: client())
            .replaceScope(key: ProfileKey(platform: .macOS, id: 42), body: ClassicScopeService.unscopedBody(platform: .macOS))

        let request = try #require(MockURLProtocol.requests.last)
        #expect(request.method == "PUT")
        #expect(request.path.hasSuffix("/proclassic/osxconfigurationprofiles/id/42"))
    }

    @Test("Each Classic request names its Jamf Pro privilege", arguments: ProfilePlatform.allCases)
    func classicPrivileges(platform: ProfilePlatform) async throws {
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return .json(200, tokenBody) }
            return xml(403, "<html><body><p>Forbidden</p></body></html>")
        }
        let key = ProfileKey(platform: platform, id: 5)
        let classic = LiveClassicAPI(client: try client())
        let writer = LiveClassicScopeWriter(client: try client())

        let list = await #expect(throws: JamfPlatform.APIError.self) { _ = try await classic.listProfiles(platform: platform) }
        let read = await #expect(throws: JamfPlatform.APIError.self) { _ = try await classic.profile(key: key) }
        let write = await #expect(throws: JamfPlatform.APIError.self) {
            try await writer.replaceScope(key: key, body: ClassicScopeService.unscopedBody(platform: platform))
        }
        #expect(list?.privileges == [platform.readPrivilege])
        #expect(read?.privileges == [platform.readPrivilege])
        #expect(write?.privileges == [platform.updatePrivilege])
        #expect(ProfilePlatform.macOS.readPrivilege.rawValue == "Read macOS Configuration Profiles")
        #expect(ProfilePlatform.mobile.updatePrivilege.rawValue == "Update iOS Configuration Profiles")
    }

    @Test("Test Connection's profile check carries its privilege")
    @MainActor
    func classicPermissionCheck() throws {
        let check = try #require(AppModel.readChecks.first { $0.path == "proclassic/osxconfigurationprofiles" })
        #expect(check.jamfProPrivilege == "Read macOS Configuration Profiles")
    }

    @Test("Classic error pages read as their message, without a password", arguments: [
        (409, "<html><head><title>Status page</title></head><body><p>Error: Duplicate name</p><p>You can get technical details <a href=\"x\">here</a></p></body></html>", "Error: Duplicate name"),
        (400, "<?xml version=\"1.0\"?><error><code>400</code><message>Problem with scope</message><password>hunter2-secret</password></error>", "Problem with scope"),
    ])
    func classicErrorPages(status: Int, page: String, message: String) async throws {
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return .json(200, tokenBody) }
            return MockResponse(status: status, headers: ["Content-Type": page.hasPrefix("<html") ? "text/html" : "application/xml"],
                                body: Data(page.utf8))
        }
        let writer = LiveClassicScopeWriter(client: try client())
        let error = await #expect(throws: JamfPlatform.APIError.self) {
            try await writer.replaceScope(key: ProfileKey(platform: .macOS, id: 42), body: ClassicScopeService.unscopedBody(platform: .macOS))
        }
        let report = ErrorReport(try #require(error))
        let shown = ([report.title] + report.details).joined(separator: "\n")
        #expect(shown.contains(message))
        #expect(!shown.contains("<"), "no markup")
        #expect(!shown.contains("hunter2-secret"))
        #expect(!shown.localizedCaseInsensitiveContains("technical details"))
    }
}

@Suite("Demo mode Classic server")
struct DemoClassicListTests {
    @Test("The demo lists answer in Jamf Pro's JSON shape and read back sorted by name, as from a tenant", arguments: ProfilePlatform.allCases)
    func demoList(platform: ProfilePlatform) async throws {
        let json = DemoFixtures.profileListJSON(platform: platform)
        #expect(json.hasPrefix(#"{"\#(platform.listRootElement)":[{"id":"#))
        let list = try await demoClassicAPI().listProfiles(platform: platform)
        #expect(list.map(\.profileID) == (platform == .macOS ? [103, 104, 101, 105, 102, 107, 106] : [202, 201]))
        #expect(list.allSatisfy { !$0.name.isEmpty && !$0.name.contains("&amp;") })
    }
}
