import Foundation
import Observation

/// Checks GitHub for a newer Profile2Blueprint release.
///
/// This is a notifier and a downloader, not an installer. The app is sandboxed, so
/// it cannot replace itself in /Applications; the update is saved where the user
/// chooses and swapped in by hand. GitHub is the only address this talks to, it
/// sends nothing but the request itself, and the automatic check can be turned off.
/// It bypasses `HTTPClient`, which only ever talks to the Jamf gateway.
@Observable
final class UpdateChecker {
    /// A published release, reduced to what the update sheet shows.
    nonisolated struct Release: Sendable, Equatable {
        let version: String
        let name: String
        /// GitHub's release notes, as written (Markdown).
        let notes: String
        /// The release's .zip asset, when it has one.
        let downloadURL: URL?
        let pageURL: URL?
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    /// `UserDefaults` key for the automatic check. Absent means on.
    static let automaticCheckKey = "checksForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let lastOfferedKey = "lastOfferedUpdate"
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/JordyThery/Profile2Blueprint/releases/latest")
    /// At most one automatic check per day.
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private(set) var status: Status = .idle
    /// Whether the update sheet is on screen. Set by a manual check at once, and by
    /// the automatic one only when it found something new.
    var isPresented = false

    @ObservationIgnored private let activity: ActivityLog?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession

    init(activity: ActivityLog? = nil, defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.activity = activity
        self.defaults = defaults
        self.session = session
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks in the background at most once a day, and only interrupts when there is
    /// a release it has not offered before. Failures stay silent apart from Activity:
    /// a missed check is not worth an alert.
    func checkAutomatically() async {
        guard defaults.object(forKey: Self.automaticCheckKey) == nil || defaults.bool(forKey: Self.automaticCheckKey) else { return }
        let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) >= Self.automaticCheckInterval else { return }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        guard let release = try? await fetchLatestRelease() else { return }
        guard Self.isNewer(release.version, than: currentVersion),
              release.version != defaults.string(forKey: Self.lastOfferedKey) else { return }
        defaults.set(release.version, forKey: Self.lastOfferedKey)
        status = .available(release)
        isPresented = true
    }

    /// Checks now and shows the result either way.
    func checkManually() {
        isPresented = true
        status = .checking
        Task {
            do {
                let release = try await fetchLatestRelease()
                status = Self.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        struct Response: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: String?
            let assets: [Asset]?
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
        }
        guard let url = Self.latestReleaseURL else { throw UpdateError(message: "The release address is invalid.") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw UpdateError(message: "GitHub did not answer (HTTP \(status)).")
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let version = decoded.tag_name.hasPrefix("v") ? String(decoded.tag_name.dropFirst()) : decoded.tag_name
            activity?.app("Checked GitHub for updates: latest release is \(version), this is \(currentVersion).")
            return Release(
                version: version,
                name: decoded.name ?? "Profile2Blueprint \(version)",
                notes: decoded.body ?? "",
                downloadURL: decoded.assets?.first { $0.name.hasSuffix(".zip") }
                    .flatMap { URL(string: $0.browser_download_url) },
                pageURL: decoded.html_url.flatMap(URL.init(string:))
            )
        } catch {
            activity?.app("Update check failed: \(error.localizedDescription)", level: .warning)
            throw error
        }
    }

    /// Numeric component comparison, so 1.10 is newer than 1.9 and a missing
    /// component counts as zero.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    nonisolated struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
