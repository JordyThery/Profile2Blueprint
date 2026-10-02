import AppKit
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
            CommandGroup(replacing: .appInfo) {
                Button("About Profile2Blueprint") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "Created by Jordy Thery",
                            attributes: [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: centered]
                        ),
                    ])
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.updates.checkManually() }
            }
        }
    }

    private var centered: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }
}
