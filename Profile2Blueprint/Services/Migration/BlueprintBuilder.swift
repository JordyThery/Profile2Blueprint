import Foundation

nonisolated struct BlueprintBuildError: Error, LocalizedError, Hashable, Sendable {
    var problems: [String]
    var errorDescription: String? { problems.joined(separator: "\n") }
}

/// Assembles the create-blueprint body with identifiers copied verbatim.
nonisolated enum BlueprintBuilder {
    static let componentIdentifier = "com.jamf.ddm-configuration-profile"
    static let stepName = "Migrated classic configuration profile"
    static let maxNameLength = 200
    static let maxDescriptionLength = 2_000

    static func defaultName(for profile: ClassicProfile, naming: BlueprintNaming = .default) -> String {
        naming.name(for: profile.name)
    }

    /// Tokens a description template may use, with what each one is replaced by.
    static let descriptionTokens: [(token: String, meaning: String)] = [
        ("{name}", "the classic profile's name"),
        ("{id}", "its Jamf Pro ID"),
    ]

    /// The description used before the template was configurable, kept as the default.
    static let defaultDescriptionTemplate =
        "Migrated from Jamf Pro classic macOS configuration profile ID {id} (“{name}”) by Profile2Blueprint."

    /// Fills in `descriptionTokens` and trims to the API's limit. An empty template
    /// yields an empty description, which `build` sends as null.
    static func description(_ template: String, profileName: String, profileID: Int) -> String {
        let filled = template
            .replacingOccurrences(of: "{name}", with: profileName)
            .replacingOccurrences(of: "{id}", with: String(profileID))
        return String(filled.prefix(maxDescriptionLength))
    }

    static func defaultDescription(for profile: ClassicProfile, template: String = defaultDescriptionTemplate) -> String {
        description(template, profileName: profile.name, profileID: profile.id)
    }

    /// The `configuration` object of the `com.jamf.ddm-configuration-profile` component.
    static func configuration(for document: ProfileDocument, fallbackName: String) -> JSONObject {
        var configuration = JSONObject()
        if let uuid = document.payloadUUID { configuration["payloadUUID"] = .string(uuid) }
        if let identifier = document.payloadIdentifier { configuration["payloadIdentifier"] = .string(identifier) }
        configuration["payloadDisplayName"] = .string(document.payloadDisplayName ?? fallbackName)
        configuration["payloadContent"] = .array(document.payloads.map { .object(PlistToJSON.payloadObject($0.content)) })
        return configuration
    }

    static func build(
        profile: ClassicProfile,
        name: String,
        description: String?,
        deviceGroupIDs: [String]
    ) throws(BlueprintBuildError) -> BlueprintRequest {
        var problems: [String] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { problems.append("Blueprint name is required.") }
        if trimmedName.count > maxNameLength { problems.append("Blueprint name must be at most \(maxNameLength) characters.") }
        if let description, description.count > maxDescriptionLength {
            problems.append("Description must be at most \(maxDescriptionLength) characters.")
        }

        var groups: [String] = []
        for id in deviceGroupIDs where !groups.contains(id) { groups.append(id) }
        if groups.isEmpty { problems.append("Pick at least one platform device group.") }

        var document: ProfileDocument?
        switch profile.document {
        case let .success(parsed):
            document = parsed
            if parsed.payloads.isEmpty { problems.append("The profile has no payloads.") }
            let blocked = parsed.payloads.compactMap(\.type).filter(EligibilityChecker.blockedPayloadTypes.contains)
            if !blocked.isEmpty { problems.append("Unsupported payload types: \(Set(blocked).sorted().joined(separator: ", ")).") }
            if parsed.payloadUUID == nil || parsed.payloadIdentifier == nil {
                problems.append("The profile is missing its top-level PayloadUUID or PayloadIdentifier.")
            }
        case let .failure(error):
            problems.append(error.message)
        }
        if profile.level != .system { problems.append("Only computer-level profiles can be migrated in v1.") }

        guard problems.isEmpty, let document else { throw BlueprintBuildError(problems: problems) }

        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BlueprintRequest(
            name: trimmedName,
            description: (trimmedDescription?.isEmpty ?? true) ? nil : trimmedDescription,
            deviceGroupIDs: groups,
            stepName: stepName,
            componentIdentifier: componentIdentifier,
            configuration: configuration(for: document, fallbackName: profile.name)
        )
    }
}
