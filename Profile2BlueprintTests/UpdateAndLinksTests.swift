import Foundation
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
        #expect(links.classicProfile(id: 477).absoluteString == "https://jamf.lab9.be/OSXConfigurationProfiles.html?id=477&o=r",
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

@Suite("Update versions")
struct UpdateVersionTests {

    @Test("Versions compare numerically, component by component",
          arguments: [
              ("1.0.2", "1.0.1", true), ("1.1", "1.0.9", true), ("1.10", "1.9", true), ("2.0", "1.99.99", true),
              ("1.0.1", "1.0.1", false), ("1.0", "1.0.0", false), ("1.0.0", "1.0", false), ("1.0.1", "1.0.2", false),
          ])
    func isNewer(candidate: String, current: String, expected: Bool) {
        #expect(UpdateChecker.isNewer(candidate, than: current) == expected)
    }
}

private func releaseJSON(tag: String) -> String {
    """
    {"tag_name":"\(tag)","name":"Profile2Blueprint \(tag.dropFirst())","body":"**Fixed** things.",
     "html_url":"https://github.com/JordyThery/Profile2Blueprint/releases/tag/\(tag)",
     "assets":[{"name":"Profile2Blueprint-\(tag.dropFirst()).zip","browser_download_url":"https://github.com/download/p2b.zip"}]}
    """
}

private func freshDefaults() -> UserDefaults {
    let name = "p2b-update-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Network-backed: joins the serialized suite because `MockURLProtocol`'s handler is global.
extension NetworkingTests {

    @Test("A newer release is offered once, with notes and the zip asset")
    @MainActor
    func offersNewerRelease() async throws {
        MockURLProtocol.install { _ in .json(200, releaseJSON(tag: "v99.0.0")) }
        let defaults = freshDefaults()
        let checker = UpdateChecker(defaults: defaults, session: MockURLProtocol.makeSession())

        await checker.checkAutomatically()

        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.url.absoluteString == "https://api.github.com/repos/JordyThery/Profile2Blueprint/releases/latest")
        #expect(request.header("Accept") == "application/vnd.github+json")
        guard case let .available(release) = checker.status else {
            Issue.record("expected an available release, got \(checker.status)"); return
        }
        #expect(release.version == "99.0.0", "the leading v is dropped")
        #expect(release.downloadURL?.lastPathComponent == "p2b.zip")
        #expect(checker.isPresented)

        // The next day the same release is not offered again.
        defaults.set(Date.distantPast, forKey: "lastUpdateCheck")
        checker.isPresented = false
        await checker.checkAutomatically()
        #expect(!checker.isPresented)
    }

    @Test("The current or an older release is not offered")
    @MainActor
    func ignoresOlderRelease() async {
        MockURLProtocol.install { _ in .json(200, releaseJSON(tag: "v0.0.1")) }
        let checker = UpdateChecker(defaults: freshDefaults(), session: MockURLProtocol.makeSession())
        await checker.checkAutomatically()
        #expect(MockURLProtocol.requests.count == 1)
        #expect(!checker.isPresented)
    }

    @Test("Nothing is sent when the daily check is off, or already ran today")
    @MainActor
    func respectsSettings() async {
        MockURLProtocol.install { _ in Issue.record("nothing should be sent"); return .json(500, "{}") }

        let off = freshDefaults()
        off.set(false, forKey: UpdateChecker.automaticCheckKey)
        await UpdateChecker(defaults: off, session: MockURLProtocol.makeSession()).checkAutomatically()

        let recent = freshDefaults()
        recent.set(Date(), forKey: "lastUpdateCheck")
        await UpdateChecker(defaults: recent, session: MockURLProtocol.makeSession()).checkAutomatically()

        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test("A failed automatic check stays silent")
    @MainActor
    func silentFailure() async {
        MockURLProtocol.install { _ in .json(503, "{}") }
        let checker = UpdateChecker(defaults: freshDefaults(), session: MockURLProtocol.makeSession())
        await checker.checkAutomatically()
        #expect(!checker.isPresented)
        #expect(checker.status == .idle)
    }
}
