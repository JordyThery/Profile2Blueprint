import JTKit
import SwiftUI

@main struct Profile2BlueprintApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(model.updates)
                .frame(minWidth: 820, minHeight: 520)
                .task { await model.updates.checkAutomatically() }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            AppInfoCommands(appName: "Profile2Blueprint") { model.updates.checkManually() }
            TenantCommands(model: model)
        }
        // General (Appearance), Connections (the tenants) and Updates. Every tab
        // has a name, so "Edit Tenants…" can open Connections.
        SettingsWindow(updates: model.updates, opensTabsByName: true) {
            TenantSettingsTab(model: model)
        }
        AboutWindow(configuration: .profile2Blueprint)
    }
}

/// What the About window shows (JTKit's `AboutWindow`).
extension AboutConfiguration {
    static let profile2Blueprint = AboutConfiguration(
        appName: "Profile2Blueprint",
        copyright: AboutCopyright(year: "2026", holder: "Jordy Thery"),
        author: "Created by Jordy Thery",
        summary: "Migrates Jamf Pro classic configuration profiles — macOS and mobile device — into Jamf Platform Blueprints using the Apple-supported in-place Classic → DDM transform — reviewable, verifiable and non-destructive.",
        links: [
            AboutLink("github.com/JordyThery/Profile2Blueprint", address: "https://github.com/JordyThery/Profile2Blueprint"),
        ].compactMap { $0 },
        disclaimer: "Verify every migration on a test device before fleet-wide use."
    )
}
