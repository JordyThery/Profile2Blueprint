import Foundation

/// Maps classic scope groups to platform device groups of the same platform, by name.
nonisolated enum ScopeMapper {
    static func propose(for scope: ClassicScope, platform: ProfilePlatform, platformGroups: [PlatformGroup]) -> [ScopeMappingEntry] {
        let candidates = platformGroups.filter { $0.deviceType == platform.deviceGroupType }
        return scope.deviceGroups.map { classic in
            let exact = candidates.filter { $0.name == classic.name }
            let loose = exact.isEmpty
                ? candidates.filter { normalize($0.name) == normalize(classic.name) }
                : []
            return ScopeMappingEntry(classicGroup: classic, exactMatches: exact, suggestions: loose)
        }
    }

    /// Platform group IDs chosen automatically: unique exact matches only, in scope order.
    static func automaticSelection(_ entries: [ScopeMappingEntry]) -> [String] {
        var seen = Set<String>()
        return entries.compactMap(\.autoMatch?.id).filter { seen.insert($0).inserted }
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
            .lowercased()
    }
}
