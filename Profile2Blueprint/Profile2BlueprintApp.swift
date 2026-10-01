import AppKit
import SwiftUI

@main struct Profile2BlueprintApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Profile2Blueprint") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "Created by Jordy Thery\nNot affiliated with Jamf or Apple.",
                            attributes: [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: centered]
                        ),
                    ])
                }
            }
        }
    }

    private var centered: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }
}
