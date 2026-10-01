import SwiftUI

/// Shows an API failure faithfully: HTTP status, each error's code / field /
/// description, and the trace ID, all selectable for support tickets.
struct APIErrorView: View {
    let report: ErrorReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(report.title, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let status = report.httpStatus {
                    row("httpStatus", "\(status)")
                }
                ForEach(Array(report.details.enumerated()), id: \.offset) { _, detail in
                    row("errors.code", detail.code)
                    if let field = detail.field {
                        row("errors.field", field)
                    }
                    if !detail.description.isEmpty {
                        row("errors.description", detail.description)
                    }
                }
                if let traceId = report.traceId {
                    row("traceId", traceId)
                }
            }
            .font(.callout)

            if let raw = report.rawBody {
                DisclosureGroup("Response body (redacted)") {
                    ScrollView {
                        Text(raw)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}
