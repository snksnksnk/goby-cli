import Foundation

public struct MobileApprovalDisclosureContent: Equatable, Sendable {
    public let summary: String
    public let details: String?

    public init(summary: String, details: String?) {
        self.summary = summary
        self.details = details
    }
}

/// Bounds the canonical operation retained by the host for an approval. Paired
/// clients keep their smaller disclosure limits, while the authoritative Mac
/// can review a practical source patch without silently turning it decline-only.
public enum ApprovalDisclosureLimits {
    public static let canonicalSummaryUTF8Limit = 64 * 1_024
    public static let canonicalDetailsUTF8Limit = 256 * 1_024
}

/// Produces exact, perceptible approval text for the authoritative Mac. Unlike
/// a paired-client disclosure, local review intentionally keeps filesystem
/// paths intact so the user can verify the actual patch target.
public enum AuthoritativeApprovalDisclosurePolicy {
    public static func render(
        summary: String,
        details: String?,
        exactForbiddenValues: [String]
    ) -> MobileApprovalDisclosureContent? {
        guard let renderedSummary = renderField(
            summary,
            utf8Limit: ApprovalDisclosureLimits.canonicalSummaryUTF8Limit,
            exactForbiddenValues: exactForbiddenValues
        ) else { return nil }

        let renderedDetails: String?
        if let details {
            guard let value = renderField(
                details,
                utf8Limit: ApprovalDisclosureLimits.canonicalDetailsUTF8Limit,
                exactForbiddenValues: exactForbiddenValues
            ) else { return nil }
            renderedDetails = value
        } else {
            renderedDetails = nil
        }

        return MobileApprovalDisclosureContent(
            summary: renderedSummary,
            details: renderedDetails
        )
    }

    private static func renderField(
        _ source: String,
        utf8Limit: Int,
        exactForbiddenValues: [String]
    ) -> String? {
        guard source.utf8.count <= utf8Limit,
              !SensitiveTextRedactor.containsCredentialMaterial(
                source,
                exactForbiddenValues: exactForbiddenValues
              ) else { return nil }
        let visible = ApprovalDisplayPolicy.exactVisibleText(source)
        guard visible.utf8.count <= utf8Limit else { return nil }
        return visible
    }
}

/// Produces the complete operation text that a paired client may use for an
/// approval decision. The policy is deliberately lossless after reviewed-root
/// aliasing: any additional normalization or redaction makes the request
/// Mac-only instead of presenting a subtly different operation.
public enum MobileApprovalDisclosurePolicy {
    public enum AliasKind: Sendable {
        case project
        case sharedResource

        fileprivate var label: String {
            switch self {
            case .project: "Project"
            case .sharedResource: "Shared resource"
            }
        }
    }

    public static let summaryUTF8Limit = 4_000
    public static let detailsUTF8Limit = 8_000

    public static func render(
        kind: CodexApprovalKind = .fileChange,
        summary: String,
        details: String?,
        aliases: [(path: String, alias: String)],
        exactForbiddenValues: [String]
    ) -> MobileApprovalDisclosureContent? {
        // Free-form shell commands have executable path semantics that cannot
        // be proven by a lexical disclosure filter. Keep those decisions on
        // the authoritative Mac until providers expose a structured command
        // representation with independently verifiable resource operands.
        guard kind != .command else { return nil }
        // A display label is part of the approval's scope identity. If two
        // distinct roots collapse to the same visible label, the paired user
        // cannot tell which root the operation targets. Keep that decision on
        // the authoritative Mac instead of choosing one mapping by order.
        guard aliasesAreUnambiguous(aliases) else { return nil }
        guard let renderedSummary = renderField(
            summary,
            utf8Limit: summaryUTF8Limit,
            aliases: aliases,
            exactForbiddenValues: exactForbiddenValues
        ) else { return nil }

        let renderedDetails: String?
        if let details {
            guard let value = renderField(
                details,
                utf8Limit: detailsUTF8Limit,
                aliases: aliases,
                exactForbiddenValues: exactForbiddenValues
            ) else { return nil }
            renderedDetails = value
        } else {
            renderedDetails = nil
        }

        return MobileApprovalDisclosureContent(
            summary: renderedSummary,
            details: renderedDetails
        )
    }

    /// Produces an injection-safe, visually disambiguated alias for one
    /// authorized root. Non-ASCII and operation-grammar characters are shown
    /// as explicit scalar values instead of being dropped or rendered as
    /// confusable/invisible glyphs. A projection-local ordinal distinguishes
    /// roots that intentionally share the same display name without deriving
    /// or disclosing any information from the Mac path.
    public static func alias(
        kind: AliasKind,
        displayName: String,
        ordinal: Int
    ) -> String {
        let encodedName = displayName.unicodeScalars.map { scalar -> String in
            if scalar.isASCII,
               CharacterSet.alphanumerics.contains(scalar)
                    || " -_.()".unicodeScalars.contains(scalar) {
                return String(scalar)
            }
            return "~u\(String(scalar.value, radix: 16, uppercase: true))~"
        }.joined()
        let visibleName = encodedName.isEmpty ? "Unnamed" : encodedName
        let discriminator: String
        switch kind {
        case .project: discriminator = "P"
        case .sharedResource: discriminator = "R"
        }
        return "\(kind.label) «\(visibleName)» #\(discriminator)\(max(1, ordinal))"
    }

    /// One stable ordering contract is shared by canonical alias generation
    /// and the iOS Library projection. It is intentionally based only on the
    /// opaque entity identity, never a Mac path or mutable array position.
    public static func ordinals(
        stableIdentifiers: [String]
    ) -> [String: Int] {
        let unique = Set(stableIdentifiers)
        guard unique.count == stableIdentifiers.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: unique.sorted().enumerated().map {
            ($0.element, $0.offset + 1)
        })
    }

    private static func renderField(
        _ source: String,
        utf8Limit: Int,
        aliases: [(path: String, alias: String)],
        exactForbiddenValues: [String]
    ) -> String? {
        guard source.utf8.count <= utf8Limit else { return nil }

        let aliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
            source,
            aliases: aliases
        )
        guard !SensitiveTextRedactor.containsUnaliasedAbsoluteFileSystemPath(aliased) else {
            return nil
        }

        // Approval text may never rely on a truncated or lossy redaction. If
        // the generic redactor would alter even one character, the complete
        // canonical operation must be reviewed on the authoritative Mac.
        let redacted = SensitiveTextRedactor.redact(
            aliased,
            exactForbiddenValues: exactForbiddenValues,
            limit: .max
        )
        guard redacted == aliased, aliased.utf8.count <= utf8Limit else {
            return nil
        }
        // Validate the canonical source before converting invisible scalars to
        // visible escape text. Otherwise a bidi/control scalar can become safe
        // ASCII first and incorrectly pass the display-scalar gate. CGJ and a
        // variation selector are the only reviewed operation scalars that may
        // be represented by their exact visible escape; every control, format,
        // separator and other default-ignorable scalar remains Mac-only.
        guard hasOnlyApprovalSafeSourceScalars(aliased) else { return nil }
        let visible = ApprovalDisplayPolicy.exactVisibleText(aliased)
        guard visible.utf8.count <= utf8Limit,
              hasOnlyApprovalSafeDisplayScalars(visible),
              !visible.unicodeScalars.contains(where: \.properties.isDefaultIgnorableCodePoint) else {
            return nil
        }
        return visible
    }

    private static func hasOnlyApprovalSafeSourceScalars(_ source: String) -> Bool {
        source.unicodeScalars.allSatisfy { scalar in
            if scalar.value == 0x034F || scalar.value == 0xFE0F {
                return true
            }
            guard !scalar.properties.isDefaultIgnorableCodePoint else { return false }
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                return true
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    return false
                default:
                    return true
                }
            }
        }
    }

    private static func aliasesAreUnambiguous(
        _ aliases: [(path: String, alias: String)]
    ) -> Bool {
        var pathByVisibleLabel: [String: String] = [:]
        for entry in aliases {
            guard !entry.alias.isEmpty,
                  isSafeAliasLabel(entry.alias) else { return false }
            let visibleLabel = entry.alias.precomposedStringWithCanonicalMapping
            if let existingPath = pathByVisibleLabel[visibleLabel],
               existingPath != entry.path {
                return false
            }
            pathByVisibleLabel[visibleLabel] = entry.path
        }
        return true
    }

    private static func isSafeAliasLabel(_ alias: String) -> Bool {
        guard hasOnlyApprovalSafeDisplayScalars(alias),
              !alias.unicodeScalars.contains(where: { scalar in
                  scalar.properties.isDefaultIgnorableCodePoint
                      || "\t\r\n\"\\/{}[]:,".unicodeScalars.contains(scalar)
              }) else { return false }

        let prefixes = ["Project «", "Shared resource «"]
        guard let prefix = prefixes.first(where: alias.hasPrefix) else { return false }
        let remainder = alias.dropFirst(prefix.count)
        guard let closing = remainder.firstIndex(of: "»") else { return false }
        let name = remainder[..<closing]
        guard !name.isEmpty,
              !name.contains("«"),
              !name.contains("»") else { return false }

        let suffix = remainder[remainder.index(after: closing)...]
        guard suffix.isEmpty || suffix.hasPrefix(" #") else { return false }
        if !suffix.isEmpty {
            let digest = suffix.dropFirst(2)
            guard let kind = digest.first,
                  kind == "P" || kind == "R",
                  digest.dropFirst().count <= 6,
                  !digest.dropFirst().isEmpty,
                  digest.dropFirst().allSatisfy(\.isNumber) else {
                return false
            }
        }
        return true
    }

    /// Approval text is rendered by the system text engine, so invisible
    /// format controls and bidirectional overrides can make exact bytes appear
    /// to say something else. Preserve ordinary structured multiline text and
    /// tabs, but keep every other control/format-bearing disclosure Mac-only.
    private static func hasOnlyApprovalSafeDisplayScalars(_ source: String) -> Bool {
        source.unicodeScalars.allSatisfy { scalar in
            guard !scalar.properties.isDefaultIgnorableCodePoint else { return false }
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                return true
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    return false
                default:
                    return true
                }
            }
        }
    }
}
