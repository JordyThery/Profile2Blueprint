import SwiftUI

/// The app is no longer maintained: Blueshift by Jamf Concepts does what it
/// did. Shown at the top of the main window (`ArchiveNoticeBar`) and in About.
/// The app sends nothing for it; Open Blueshift opens the link in the browser.
enum ArchiveNotice {
    static let text = "Profile2Blueprint is no longer maintained. Use Blueshift by Jamf Concepts instead: its Keep as Installed takes a configuration profile over in place using Apple’s transition from MDM, as Profile2Blueprint’s in-place transform does. Blueshift’s README says which profiles qualify for Keep as Installed."
    static let buttonTitle = "Open Blueshift"
    static let blueshiftURL = URL(string: "https://github.com/Jamf-Concepts/blueshift")
}

/// A slim bar above the split view. Closing it hides it until the next launch
/// (`AppModel.isArchiveNoticeClosed` isn't saved).
struct ArchiveNoticeBar: View {
    @Binding var isClosed: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !isClosed {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "archivebox")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(ArchiveNotice.text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let url = ArchiveNotice.blueshiftURL {
                        Button(ArchiveNotice.buttonTitle) { openURL(url) }
                            .controlSize(.small)
                            .help("Open Blueshift on GitHub in your browser")
                    }
                    Button {
                        isClosed = true
                    } label: {
                        // At least 20 × 20 pt to click, not just the symbol.
                        Image(systemName: "xmark")
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Hide this notice until you open the app again")
                    .accessibilityLabel("Close Notice")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("archiveNotice")
        }
    }
}

#if DEBUG
#Preview {
    ArchiveNoticeBar(isClosed: .constant(false))
        .frame(width: 1040)
}
#endif
