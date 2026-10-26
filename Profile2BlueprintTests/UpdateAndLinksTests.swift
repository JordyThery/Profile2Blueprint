import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Profile2Blueprint

// MARK: - Open in Jamf Pro

@Suite("Jamf Pro links")
struct JamfProLinksTests {

    @Test("The address is accepted however it is pasted",
          arguments: ["jamf.lab9.be", "https://jamf.lab9.be", "https://jamf.lab9.be/", "  jamf.lab9.be  ",
                      "https://jamf.lab9.be/OSXConfigurationProfiles.html?id=477&o=r"])
    func normalises(address: String) throws {
        let links = try #require(JamfProLinks(address))
        #expect(links.base.absoluteString == "https://jamf.lab9.be")
    }

    @Test("A port is kept")
    func keepsPort() throws {
        #expect(try #require(JamfProLinks("jamf.example.com:8443")).base.absoluteString == "https://jamf.example.com:8443")
    }

    @Test("Empty or unusable addresses produce no links", arguments: ["", "   ", "not a url", "localhost"])
    func rejects(address: String) {
        #expect(JamfProLinks(address) == nil)
    }

    @Test("Links match the routes Jamf Pro's own console uses")
    func routes() throws {
        let links = try #require(JamfProLinks("jamf.lab9.be"))
        #expect(links.classicProfile(platform: .macOS, id: 477).absoluteString == "https://jamf.lab9.be/OSXConfigurationProfiles.html?id=477&o=r",
                "o=r opens read-only")
        #expect(links.blueprint(id: "4b23b59a-ba36-4f7c-9aea-00cf63ce9d13").absoluteString
                == "https://jamf.lab9.be/view/mfe/blueprints/4b23b59a-ba36-4f7c-9aea-00cf63ce9d13")
    }

    @Test("A tenant saved before the address existed decodes with none")
    func decodesLegacyTenant() throws {
        let json = Data(#"{"id":"\#(UUID().uuidString)","name":"Old","region":"eu","environmentID":"e","clientID":"c"}"#.utf8)
        let tenant = try JSONDecoder().decode(Tenant.self, from: json)
        #expect(tenant.jamfProURL.isEmpty)
        #expect(tenant.jamfProLinks == nil)
    }
}

// MARK: - Update check
//
// The checker itself is JTKit's and tested there. What stays here is Profile2Blueprint's
// own configuration, and the one behaviour JTKit's tests don't cover yet.

@Suite("Update configuration")
struct UpdateConfigurationTests {

    @Test("Checks Profile2Blueprint's releases and keeps the app's saved-settings keys")
    @MainActor
    func configuration() {
        let configuration = UpdateConfiguration.profile2Blueprint
        #expect(configuration.latestReleaseURL?.absoluteString
                == "https://api.github.com/repos/JordyThery/Profile2Blueprint/releases/latest")
        #expect(configuration.appName == "Profile2Blueprint")
        #expect(configuration.automaticCheckKey == "checksForUpdates")
        #expect(configuration.lastCheckKey == "lastUpdateCheck")
        #expect(configuration.lastOfferedKey == "lastOfferedUpdate")
    }
}

/// Network-backed: joins the serialized suite because `MockURLProtocol`'s handler is global.
extension NetworkingTests {

    @Test("A failed automatic check stays silent")
    @MainActor
    func silentFailure() async {
        MockURLProtocol.install { _ in .json(503, "{}") }
        let name = "p2b-update-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        let checker = UpdateChecker(
            configuration: .profile2Blueprint, defaults: defaults, session: MockURLProtocol.makeSession()
        )
        await checker.checkAutomatically()
        #expect(MockURLProtocol.requests.count == 1)
        #expect(!checker.isPresented)
        #expect(checker.status == .idle)
    }
}
