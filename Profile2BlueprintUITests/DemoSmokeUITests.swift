import XCTest
import JTKitUITestSupport

/// The release check's UI smoke tests (JTKit ROADMAP step 11), in demo mode:
/// the same answers every run, no tenant, nothing saved. Run one at a time by
/// `Scripts/release-check.sh`; minutes, not hours.
final class DemoSmokeUITests: JTKitUITestCase {
    private let securityBaseline = "Contoso – Security Baseline"

    override var appName: String { "Profile2Blueprint" }

    override var demoLaunchArguments: [String] {
        ["-checksForUpdates", "NO"]
    }

    override func launchApp() {
        launchInDemo()
    }

    override func didLaunch() {
        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")
        if main.frame.width < 1300 {
            let zoom = app.menuBars.menuItems["Zoom"].firstMatch
            if zoom.exists { zoom.click() }
        }
    }

    func test1Launch() {
        // The main window is named after its page: "Profiles — Demo – Contoso (Demo)".
        XCTAssertTrue(window(titled: "Profiles").waitForExistence(timeout: 20), "The main window did not open")
        openProfiles()
    }

    func test2About() {
        checkAbout()
    }

    func test3SettingsTabs() {
        checkSettingsTabs(["General", "Connections", "Updates"])
    }

    func test4ConnectionsEditor() {
        // Made-up values: the connection lives only in this run's in-memory list.
        // The Client ID field follows Environment ID (the app's own fields come after it).
        checkConnectionsEditor { settings in
            let fields = settings.textFields.allElementsBoundByIndex
            guard let index = fields.firstIndex(where: { ($0.placeholderValue ?? "") == "From Jamf Account" }) else {
                return XCTFail("No Environment ID field")
            }
            self.type(UUID().uuidString, into: fields[index])
            if index + 1 < fields.count { self.type("jtktest-client", into: fields[index + 1]) }
            self.type("jtktest-secret", into: settings.secureTextFields.firstMatch)
        }
    }

    /// Migrate a Contoso profile: the scope screen asks which "Design Macs" is
    /// meant (two share the name); pick one, create the Blueprint (not
    /// deployed) and see the app's verification pass.
    func test5MainTask() {
        openProfiles()
        // With nothing selected, the row's checkbox selects just this profile.
        tap(profileRow(securityBaseline), timeout: 20)

        tap(app.radioButtons["Scope"].firstMatch, timeout: 10)
        XCTAssertTrue(anyContaining("groups share this name").waitForExistence(timeout: 10),
                      "The scope screen doesn't ask which Design Macs is meant")
        let picker = app.popUpButtons.matching(NSPredicate(format: "label == 'Platform group for Design Macs'")).firstMatch
        tap(picker, timeout: 10)
        let choice = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Design Macs'")).firstMatch
        tap(choice, timeout: 5)
        XCTAssertTrue((picker.value as? String)?.hasPrefix("Design Macs") == true,
                      "No Design Macs group was chosen: \(String(describing: picker.value))")

        tap(app.radioButtons["Migrate"].firstMatch, timeout: 10)
        let acknowledge = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH 'I understand' OR title BEGINSWITH 'I understand'")).firstMatch
        if acknowledge.waitForExistence(timeout: 3), (acknowledge.value as? Int) != 1 { acknowledge.click() }
        let dryRun = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH 'Dry run' OR title BEGINSWITH 'Dry run'")).firstMatch
        XCTAssertTrue(dryRun.waitForExistence(timeout: 10), "No dry-run switch")
        if (dryRun.value as? Int) == 1 { dryRun.click() }
        tap(app.buttons["Create Blueprint (Not Deployed)"].firstMatch, timeout: 10)
        XCTAssertTrue(anyContaining("Identifiers, order, count, settings and scope all match").waitForExistence(timeout: 30),
                      "The Blueprint wasn't created and verified")
        XCTAssertTrue(app.buttons["Deploy…"].firstMatch.waitForExistence(timeout: 10), "Deploy… isn't offered after verification")
    }

    func test6ActivityLog() {
        openProfiles()
        checkActivityLog()
    }

    func test7DemoTitles() {
        tap(app.menuBars.menuBarItems[appName])
        tap(app.menuItems["About \(appName)"])
        XCTAssertTrue(window(titled: "About \(appName)").waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(window(titled: "Activity Log").waitForExistence(timeout: 10))
        openSettings()
        checkDemoTitles()
    }

    // MARK: Helpers

    /// Profiles lists Contoso's sample profiles.
    private func openProfiles(file: StaticString = #filePath, line: UInt = #line) {
        openSidebar("Profiles")
        XCTAssertTrue(profileRow(securityBaseline).waitForExistence(timeout: 20),
                      "Contoso's profiles aren't listed", file: file, line: line)
    }

    /// A profile's row, exposed as one checkbox labelled "macOS, <name>, #<id> · …".
    private func profileRow(_ name: String) -> XCUIElement {
        app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", "macOS, \(name), ")).firstMatch
    }

    /// A SwiftUI text, which exposes its string as the value (label empty).
    private func text(_ string: String, in root: XCUIElement) -> XCUIElement {
        root.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", string, string)).firstMatch
    }
}
