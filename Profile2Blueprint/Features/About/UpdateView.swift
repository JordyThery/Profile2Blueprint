import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The update sheet: release notes and a download to a location the user picks.
/// Installing stays a manual drag into Applications.
struct UpdateView: View {
    @Environment(UpdateChecker.self) private var checker
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var isDownloading = false
    @State private var exportDocument: ZipDocument?
    @State private var isExporting = false
    @State private var suggestedName = "Profile2Blueprint.zip"
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 440)
        .frame(minHeight: 160)
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .zip,
            defaultFilename: suggestedName
        ) { result in
            switch result {
            case let .success(url):
                statusMessage = "Saved. Quit Profile2Blueprint and replace it in Applications."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case let .failure(error):
                statusMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch checker.status {
        case .idle, .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        case .upToDate:
            VStack(alignment: .leading, spacing: 4) {
                Text("Profile2Blueprint is up to date")
                    .font(.headline)
                Text("Version \(checker.currentVersion) is the latest release.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't check for updates")
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        case let .available(release):
            VStack(alignment: .leading, spacing: 8) {
                Text("\(release.name) is available")
                    .font(.headline)
                Text("You have \(checker.currentVersion).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !release.notes.isEmpty {
                    ScrollView {
                        Text(notesText(release.notes))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if isDownloading { ProgressView().controlSize(.small) }
            if case let .available(release) = checker.status {
                if let page = release.pageURL {
                    Button("View on GitHub") { openURL(page) }
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") { download(release) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(release.downloadURL == nil || isDownloading)
            } else {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Inline Markdown: keeps bold and links, leaves list markers as typed.
    private func notesText(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    /// Hands the zip to a save panel; the user's choice of destination is what grants
    /// the sandbox write access.
    private func download(_ release: UpdateChecker.Release) {
        guard let url = release.downloadURL else { return }
        isDownloading = true
        statusMessage = nil
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    throw UpdateChecker.UpdateError(message: "The download failed (HTTP \(status)).")
                }
                exportDocument = ZipDocument(data: data)
                suggestedName = url.lastPathComponent
                isExporting = true
            } catch {
                statusMessage = error.localizedDescription
            }
            isDownloading = false
        }
    }
}

/// Minimal zip document, used only to hand a downloaded update to `fileExporter`.
nonisolated struct ZipDocument: FileDocument {
    static let readableContentTypes = [UTType.zip]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
