import XCTest
import JTKitUITestSupport

/// The two screenshots on jordythery.be, taken in demo mode with the sample
/// tenant "Contoso (Demo)". Not part of the release check (it runs only
/// `DemoSmokeUITests`), and the app's own scheme runs no UI tests, so ⌘U never
/// starts this. Run it by name; the screenshots are kept in the test result
/// as "profile2blueprint-migrate" and "profile2blueprint-diff".
final class WebsiteScreenshotUITests: JTKitUITestCase {
    private let securityBaseline = "Contoso – Security Baseline"

    override var appName: String { "Profile2Blueprint" }

    override var demoLaunchArguments: [String] {
        ["-checksForUpdates", "NO"]
    }

    override func launchApp() {
        launchInDemo()
    }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.isReleaseCheck, "Website screenshots aren't part of the release check")
        try super.setUpWithError()
    }

    func testWebsiteScreenshots() {
        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")
        zoom(main)

        openSidebar("Profiles")
        let row = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", "macOS, \(securityBaseline), ")).firstMatch
        tap(row, timeout: 20)

        // The scope screen asks which "Design Macs" is meant: pick the first.
        tap(app.radioButtons["Scope"].firstMatch, timeout: 10)
        let picker = app.popUpButtons.matching(NSPredicate(format: "label == 'Platform group for Design Macs'")).firstMatch
        tap(picker, timeout: 10)
        tap(app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Design Macs'")).firstMatch, timeout: 5)

        // Create (not deployed) and verify.
        tap(app.radioButtons["Migrate"].firstMatch, timeout: 10)
        let acknowledge = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH 'I understand' OR title BEGINSWITH 'I understand'")).firstMatch
        if acknowledge.waitForExistence(timeout: 3), (acknowledge.value as? Int) != 1 { acknowledge.click() }
        tap(app.buttons["Create Blueprint (Not Deployed)"].firstMatch, timeout: 10)
        let verified = anyContaining("Identifiers, order, count, settings and scope all match")
        XCTAssertTrue(verified.waitForExistence(timeout: 30), "The Blueprint wasn't created and verified")

        // The verification table in view.
        scrollIntoView(app.buttons["Verify Again"].firstMatch)
        sleep(1)
        keep(main.screenshot(), named: "profile2blueprint-migrate")

        // The Diff tab: the five rules and both JSON bodies.
        tap(app.radioButtons["Diff"].firstMatch, timeout: 10)
        XCTAssertTrue(anyContaining("Five-rule check").waitForExistence(timeout: 10), "The Diff tab didn't open")
        sleep(1)
        keep(main.screenshot(), named: "profile2blueprint-diff")
    }

    // MARK: Helpers

    /// Zooms the window to fill the screen (drags don't move or resize it).
    private func zoom(_ window: XCUIElement) {
        let before = window.frame
        tap(app.menuBars.menuBarItems["Window"].firstMatch)
        tap(app.menuItems["Zoom"].firstMatch)
        sleep(1)
        if window.frame.height <= before.height {
            // The window was already zoomed: zooming toggled it back.
            tap(app.menuBars.menuBarItems["Window"].firstMatch)
            tap(app.menuItems["Zoom"].firstMatch)
            sleep(1)
        }
    }

    private func keep(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
