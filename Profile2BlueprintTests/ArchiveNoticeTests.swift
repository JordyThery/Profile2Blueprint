import Foundation
import JTKit
import Testing
@testable import Profile2Blueprint

@MainActor @Suite("No-longer-maintained notice")
struct ArchiveNoticeTests {

    @Test("Open Blueshift goes to Blueshift on GitHub")
    func link() {
        #expect(ArchiveNotice.blueshiftURL?.absoluteString == "https://github.com/Jamf-Concepts/blueshift")
    }

    @Test("The text names Blueshift, Keep as Installed and its README")
    func text() {
        #expect(ArchiveNotice.text.hasPrefix("Profile2Blueprint is no longer maintained."))
        #expect(ArchiveNotice.text.contains("Blueshift by Jamf Concepts"))
        #expect(ArchiveNotice.text.contains("Keep as Installed"))
        #expect(ArchiveNotice.text.contains("Blueshift’s README says which profiles qualify"))
    }

    @Test("About shows the notice, with Open Blueshift as its first link")
    func about() {
        let about = AboutConfiguration.profile2Blueprint
        #expect(about.summary?.hasSuffix(ArchiveNotice.text) == true)
        #expect(about.links.first?.title == "Open Blueshift")
        #expect(about.links.first?.url == ArchiveNotice.blueshiftURL)
    }

    @Test("The notice shows at every launch, in demo mode too")
    func showsAtLaunch() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "p2b-notice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for demo in [false, true] {
            let model = AppModel(store: TenantStore(fileURL: folder.appending(path: "tenants.json")),
                                 secrets: SandboxSecretStore(),
                                 history: HistoryStore(fileURL: folder.appending(path: "history.json")),
                                 demoMode: demo)
            #expect(!model.isArchiveNoticeClosed)
        }
    }
}
