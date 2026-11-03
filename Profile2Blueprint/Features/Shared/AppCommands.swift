import SwiftUI

/// What the profile list offers the menu bar while it is on screen.
struct ProfileListActions {
    var reload: () -> Void
    /// Nil while fewer than two profiles are selected.
    var migrateSelected: (() -> Void)?
}

/// What the selected profile offers the menu bar.
struct ProfileActions {
    var reload: () -> Void
    /// Nil without a Jamf Pro web address for the tenant.
    var openProfile: (() -> Void)?
    /// Nil until the Blueprint exists (or without a Jamf Pro web address).
    var openBlueprint: (() -> Void)?
}

/// What the History page offers the menu bar.
struct HistoryActions {
    /// Nil while there is nothing to export.
    var export: ((HistoryExport.Format) -> Void)?
}

extension FocusedValues {
    @Entry var profileList: ProfileListActions?
    @Entry var profile: ProfileActions?
    @Entry var history: HistoryActions?
}

/// The Profile menu and History export in the File menu, so every toolbar
/// action is also a menu command with a shortcut.
struct AppCommands: Commands {
    @FocusedValue(\.profileList) private var profileList
    @FocusedValue(\.profile) private var profile
    @FocusedValue(\.history) private var history

    var body: some Commands {
        CommandMenu("Profile") {
            Button("Reload Profiles") { profileList?.reload() }
                .keyboardShortcut("r")
                .disabled(profileList == nil)
            Button("Reload Profile") { profile?.reload() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(profile == nil)
            Divider()
            Button("Migrate Selected…") { profileList?.migrateSelected?() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(profileList?.migrateSelected == nil)
            Divider()
            Button("Open Profile in Jamf Pro") { profile?.openProfile?() }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(profile?.openProfile == nil)
            Button("Open Blueprint in Jamf Pro") { profile?.openBlueprint?() }
                .keyboardShortcut("j", modifiers: [.command, .option, .shift])
                .disabled(profile?.openBlueprint == nil)
        }
        CommandGroup(after: .importExport) {
            Button("Export History as Markdown…") { history?.export?(.markdown) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(history?.export == nil)
            Button("Export History as JSON…") { history?.export?(.json) }
                .disabled(history?.export == nil)
        }
    }
}
