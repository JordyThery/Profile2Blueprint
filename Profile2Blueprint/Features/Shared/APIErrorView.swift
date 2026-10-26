import SwiftUI

/// Shows an API failure in JTKit's format: the status line, then each error's
/// `CODE (field): description`, the Trace ID and the hints, all selectable for
/// support tickets.
struct APIErrorView: View {
    let report: ErrorReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(report.title, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)

            if let details = report.detailText {
                Text(details)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }
}
