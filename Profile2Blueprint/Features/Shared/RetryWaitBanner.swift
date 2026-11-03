import JTKit
import SwiftUI

/// The wait before a retry (JTKit's `RequestWaits`), e.g. "Jamf asked to wait
/// 40 s", with Stop. Shown above the migration steps while a wait lasts;
/// nothing otherwise. JTKit waits at most 60 s each time.
struct RetryWaitBanner: View {
    let waits: RequestWaits?

    var body: some View {
        if let waits, let text = waits.statusText {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Stop") { waits.cancelAll() }
                    .help("Stop waiting: the request isn’t sent again")
            }
            .padding(8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("retryWait")
            .onAppear {
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }
}
