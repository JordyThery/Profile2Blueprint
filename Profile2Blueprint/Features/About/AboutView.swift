import AppKit
import SwiftUI

/// App information and credits.
struct AboutView: View {
    @Environment(UpdateChecker.self) private var updates
    @AppStorage(UpdateChecker.automaticCheckKey) private var checksForUpdates = true

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .accessibilityHidden(true)

                Text("Profile2Blueprint")
                    .font(.largeTitle.weight(.semibold))
                Text(version)
                    .foregroundStyle(.secondary)

                Text("Created by Jordy Thery")
                    .font(.title3.weight(.medium))
                    .padding(.top, 6)

                Text("Migrates Jamf Pro classic macOS configuration profiles into Jamf Platform Blueprints using the Apple-supported in-place Classic → DDM transform — reviewable, verifiable and non-destructive.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
                    .padding(.top, 2)

                if let repository = URL(string: "https://github.com/JordyThery/Profile2Blueprint") {
                    Link("github.com/JordyThery/Profile2Blueprint", destination: repository)
                        .padding(.top, 6)
                }

                VStack(spacing: 6) {
                    Button("Check for Updates…") { updates.checkManually() }
                    Toggle("Check for updates daily", isOn: $checksForUpdates)
                        .toggleStyle(.checkbox)
                        .help("Once a day, ask GitHub whether a newer release exists. Nothing else is sent.")
                }
                .padding(.top, 8)

                Divider()
                    .frame(maxWidth: 480)
                    .padding(.vertical, 8)

                VStack(spacing: 4) {
                    Text("Built with SwiftUI and Swift 6, assisted by Claude.")
                    Text("Verify every migration on a test device before fleet-wide use.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("About")
    }
}

#if DEBUG
#Preview {
    AboutView()
        .environment(UpdateChecker())
        .frame(width: 700, height: 560)
}
#endif
