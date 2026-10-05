import Foundation
import Synchronization

/// Shared, fail-closed credential and host-path redaction used at every
/// cross-device or cross-provider serialization boundary.
public enum SensitiveTextRedactor {
    private static let maximumPercentDecodingDepth = 8
    private static let credentialReplacements: [(String, String)] = [
        (#"(?is)-----BEGIN [A-Z0-9 ]*(?:PRIVATE KEY|CERTIFICATE)-----.*?-----END [A-Z0-9 ]*(?:PRIVATE KEY|CERTIFICATE)-----"#, "[redacted-pem]"),
        (#"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#, "[redacted-authorization]"),
        (#"\b(?:sk-(?:ant-)?[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|(?:AKIA|ASIA)[A-Z0-9]{16})\b"#, "[redacted-token]"),
        (#"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, "[redacted-token]"),
        (#"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^@\s/]+@"#, "$1[redacted]@"),
        (#"(?i)(?<![A-Za-z0-9])(?:[A-Za-z0-9]+[_-])*(?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|token|password|passwd|passphrase|secret|private[_-]?key|session(?:[_-]?(?:id|key|token|cookie))?|database[_-]?url|cookie)(?:[_-][A-Za-z0-9]+)*\s*(?::|=|\bis\b|\bwas\b)\s*(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s,;]+)"#, "[redacted-credential]"),
    ]

    /// A projection redacts many short fields against the same catalog and run
    /// snapshot. Prepare exact values once instead of sorting and percent-
    /// encoding them again for every task title and summary.
    struct PreparedExactValues: Sendable {
        let replacements: [(literal: String, encoded: String?)]
        /// Never reused: identical value sets share one generation, and any
        /// other set receives a new one, so cached results cannot cross sets.
        let generation: UInt64

        init(_ values: [String]) {
            let literals = Array(Set(values.filter { $0.count >= 3 }))
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            replacements = literals.map { value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
                return (value, encoded == value ? nil : encoded)
            }
            generation = SensitiveTextRedactor.redactionCache.withLock { $0.generation(for: literals) }
        }
    }

    private struct CompiledReplacement: @unchecked Sendable {
        // NSRegularExpression is immutable and documented as thread-safe.
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String) {
            // The patterns are compile-time constants covered by tests.
            regex = try! NSRegularExpression(pattern: pattern)
            self.template = template
        }

        func apply(to text: String) -> String {
            regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: template
            )
        }
    }

    /// Compiling these patterns on every call dominated host projection time.
    private static let compiledCredentialReplacements = credentialReplacements.map {
        CompiledReplacement($0.0, $0.1)
    }
    private static let compiledPathReplacements = pathReplacements(preservePlanSlashCommand: false)
    private static let compiledPlanPreservingPathReplacements = pathReplacements(preservePlanSlashCommand: true)

    private static func pathReplacements(preservePlanSlashCommand: Bool) -> [CompiledReplacement] {
        // Requests can contain a standalone /plan token. In that one field,
        // treating it as an absolute path changes the host's
        // projected draft and creates a false cross-device edit conflict.
        let unixPathPattern = preservePlanSlashCommand
            ? #"(?m)(^|[\s(\[\"'])/(?!/|plan(?=$|[\s,;)\]}]))[^\s,;)\]}]+"#
            : #"(?m)(^|[\s(\[\"'])/(?!/)[^\s,;)\]}]+"#
        return [
            CompiledReplacement(#"(?i)\bfile:(?:/+|\\+)[^\s,;)\]}]+"#, "[redacted-path]"),
            CompiledReplacement(unixPathPattern, "$1[redacted-path]"),
            CompiledReplacement(#"(?m)(^|[\s(\[\"'])(?:[A-Za-z]:\\|\\\\)[^\s,;)\]}]+"#, "$1[redacted-path]"),
        ]
    }

    /// Host projections are rebuilt after every command, but run history text
    /// rarely changes. Results are keyed by the exact source, limit, mode and
    /// forbidden-value generation, so an unchanged field costs one lookup.
    fileprivate struct RedactionCache: Sendable {
        struct Key: Hashable, Sendable {
            let source: String
            let limit: Int
            let preservesPlanSlashCommand: Bool
            let generation: UInt64
        }

        private static let entryLimit = 50_000
        private static let generationLimit = 32
        private var entries: [Key: String] = [:]
        private var generations: [[String]: UInt64] = [:]
        private var nextGeneration: UInt64 = 1

        mutating func generation(for literals: [String]) -> UInt64 {
            if let existing = generations[literals] { return existing }
            if generations.count >= Self.generationLimit {
                generations.removeAll()
                entries.removeAll()
            }
            let generation = nextGeneration
            nextGeneration &+= 1
            generations[literals] = generation
            return generation
        }

        func value(for key: Key) -> String? { entries[key] }

        mutating func store(_ value: String, for key: Key) {
            if entries.count >= Self.entryLimit { entries.removeAll(keepingCapacity: true) }
            entries[key] = value
        }
    }

    fileprivate static let redactionCache = Mutex(RedactionCache())

    private enum PathSeparatorEncoding {
        case literal
        case percentEncoded
        case doublePercentEncoded
    }

    private struct AuthorizedPathCandidate {
        let value: String
        let alias: String
        let separatorEncoding: PathSeparatorEncoding
    }

    /// Replaces only complete absolute-path tokens or descendants of an
    /// authorized root. A raw string prefix is insufficient here because
    /// `/Project-backup` is a sibling of `/Project`, not a reviewed child.
    public static func aliasAuthorizedFileSystemPaths(
        _ source: String,
        aliases: [(path: String, alias: String)]
    ) -> String {
        // Filesystem scope comparison must remain lossless. Default-ignorable
        // Unicode and percent-escape spelling can identify distinct raw paths,
        // so URI compatibility is represented by explicit candidates instead
        // of rewriting the source before comparison.
        var result = source
        let candidates = aliases.flatMap { entry -> [AuthorizedPathCandidate] in
            let path = trimmedRoot(entry.path)
            guard path.count >= 3 else { return [] }
            let fullyEncoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            let doubleEncoded = fullyEncoded?.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            let fileURL = "file://\(path)"
            let encodedFileURL = fileURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            let localhostFileURL = "file://localhost\(path)"
            let encodedLocalhostFileURL = localhostFileURL
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            let singleSlashFileURL = "file:\(path)"
            let encodedSingleSlashFileURL = singleSlashFileURL
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            let doubleEncodedSingleSlashFileURL = encodedSingleSlashFileURL?
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            let repeatedSeparators = (2...4).map { count in
                String(repeating: "/", count: count - 1) + path
            }
            let literalVariants = [
                path,
                fileURL,
                localhostFileURL,
                singleSlashFileURL,
            ] + repeatedSeparators
            let encodedVariants = [
                fullyEncoded,
                encodedFileURL,
                encodedLocalhostFileURL,
                encodedSingleSlashFileURL,
            ].compactMap { $0 }
            let doubleEncodedVariants = [
                doubleEncoded,
                doubleEncodedSingleSlashFileURL,
            ].compactMap { $0 }

            return literalVariants.map {
                AuthorizedPathCandidate(
                    value: $0,
                    alias: entry.alias,
                    separatorEncoding: .literal
                )
            } + percentEscapeCaseVariants(encodedVariants).map {
                AuthorizedPathCandidate(
                    value: $0,
                    alias: entry.alias,
                    separatorEncoding: .percentEncoded
                )
            } + percentEscapeCaseVariants(doubleEncodedVariants).map {
                AuthorizedPathCandidate(
                    value: $0,
                    alias: entry.alias,
                    separatorEncoding: .doublePercentEncoded
                )
            }
        }.sorted {
            if $0.value.count == $1.value.count { return $0.value < $1.value }
            return $0.value.count > $1.value.count
        }

        for candidate in candidates {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result.range(
                    of: candidate.value,
                    options: .literal,
                    range: searchStart..<result.endIndex
                  ) {
                guard hasPathTokenBoundary(before: range.lowerBound, in: result),
                      hasPathComponentBoundary(
                        after: range.upperBound,
                        in: result,
                        separatorEncoding: candidate.separatorEncoding
                      ),
                      !isAmbiguousFileAuthority(candidate.value, at: range.lowerBound, in: result),
                      !isFileURIPathFallback(candidate.value, at: range.lowerBound, in: result),
                      !pathSuffixContainsTraversal(after: range.upperBound, in: result) else {
                    searchStart = result.index(after: range.lowerBound)
                    continue
                }
                let replacementOffset = result.distance(from: result.startIndex, to: range.lowerBound)
                result.replaceSubrange(range, with: candidate.alias)
                searchStart = result.index(
                    result.startIndex,
                    offsetBy: replacementOffset + candidate.alias.count,
                    limitedBy: result.endIndex
                ) ?? result.endIndex
            }
        }
        return result
    }

    /// Detects path-like values that survived authorized-root aliasing. This is
    /// intentionally conservative: a remote approval is decline-only whenever
    /// an encoded, escaped, shell-delimited, or otherwise ambiguous absolute
    /// path cannot be proven to belong to a reviewed root.
    public static func containsUnaliasedAbsoluteFileSystemPath(_ source: String) -> Bool {
        let decoding = percentDecodedForms(source)

        for form in decoding.forms {
            if containsLocalFileURI(in: form)
                || containsShellExpandedPath(in: form)
                || containsUnixAbsolutePath(in: form)
                || containsWindowsAbsolutePath(in: form) {
                return true
            }
        }
        guard !decoding.nestingRemains else { return true }
        let residual = decoding.forms.last?.lowercased() ?? ""
        return residual.contains("%2f")
            || residual.contains("%5c")
            || residual.contains("%2e")
            || residual.contains("%25")
    }

    public static func redact(
        _ source: String,
        exactForbiddenValues: [String] = [],
        limit: Int
    ) -> String {
        redact(source, preparedExactValues: PreparedExactValues(exactForbiddenValues), limit: limit)
    }

    static func redact(
        _ source: String,
        preparedExactValues: PreparedExactValues,
        limit: Int,
        preservePlanSlashCommand: Bool = false
    ) -> String {
        let key = RedactionCache.Key(
            source: source,
            limit: limit,
            preservesPlanSlashCommand: preservePlanSlashCommand,
            generation: preparedExactValues.generation
        )
        if let cached = redactionCache.withLock({ $0.value(for: key) }) { return cached }
        let redacted = uncachedRedact(
            source,
            preparedExactValues: preparedExactValues,
            limit: limit,
            preservePlanSlashCommand: preservePlanSlashCommand
        )
        redactionCache.withLock { $0.store(redacted, for: key) }
        return redacted
    }

    private static func uncachedRedact(
        _ source: String,
        preparedExactValues: PreparedExactValues,
        limit: Int,
        preservePlanSlashCommand: Bool
    ) -> String {
        var result = normalizedText(source)

        for (value, encoded) in preparedExactValues.replacements {
            if result.contains(value) {
                result = result.replacingOccurrences(of: value, with: "[redacted]")
            }
            if let encoded, result.contains(encoded) {
                result = result.replacingOccurrences(of: encoded, with: "[redacted]")
            }
        }

        let pathReplacements = preservePlanSlashCommand
            ? compiledPlanPreservingPathReplacements
            : compiledPathReplacements
        for replacement in compiledCredentialReplacements + pathReplacements {
            result = replacement.apply(to: result)
        }
        return String(result.prefix(max(0, limit)))
    }

    /// Removes credential-shaped text while keeping local paths. Used for
    /// host-local notes that stay on this Mac and help a later agent find files.
    public static func redactCredentials(_ source: String, limit: Int) -> String {
        var result = normalizedText(source)
        for replacement in compiledCredentialReplacements {
            result = replacement.apply(to: result)
        }
        return String(result.prefix(max(0, limit)))
    }

    /// Returns true when exact local approval text contains a known secret or
    /// credential shape. Filesystem paths are intentionally excluded because
    /// the authoritative Mac must display the real target being approved.
    static func containsCredentialMaterial(
        _ source: String,
        exactForbiddenValues: [String]
    ) -> Bool {
        var inspected = source
        for value in exactForbiddenValues.sorted(by: { $0.count > $1.count }) where value.count >= 3 {
            inspected = inspected.replacingOccurrences(of: value, with: "[redacted]")
            if let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               encoded != value {
                inspected = inspected.replacingOccurrences(of: encoded, with: "[redacted]")
            }
        }
        for (pattern, replacement) in credentialReplacements {
            inspected = inspected.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return inspected != source
    }

    private static func trimmedRoot(_ rawPath: String) -> String {
        var path = rawPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func normalizedText(_ source: String) -> String {
        source.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    private static func lowercasePercentEscapeHex(in source: String) -> String {
        let characters = Array(source)
        var result = ""
        result.reserveCapacity(source.count)
        var index = 0
        while index < characters.count {
            guard characters[index] == "%",
                  index + 2 < characters.count,
                  isHexDigit(characters[index + 1]),
                  isHexDigit(characters[index + 2]) else {
                result.append(characters[index])
                index += 1
                continue
            }
            result.append("%")
            result.append(contentsOf: String(characters[index + 1]).lowercased())
            result.append(contentsOf: String(characters[index + 2]).lowercased())
            index += 3
        }
        return result
    }

    private static func percentEscapeCaseVariants(_ values: [String]) -> [String] {
        values.flatMap { value in
            let lowercaseEscapes = lowercasePercentEscapeHex(in: value)
            return lowercaseEscapes == value ? [value] : [value, lowercaseEscapes]
        }
    }

    private static func percentDecodedForms(
        _ source: String
    ) -> (forms: [String], nestingRemains: Bool) {
        var forms = [source]
        var decoded = source
        for _ in 0..<maximumPercentDecodingDepth {
            guard let next = decoded.removingPercentEncoding, next != decoded else {
                return (forms, false)
            }
            forms.append(next)
            decoded = next
        }
        let next = decoded.removingPercentEncoding
        return (forms, next != nil && next != decoded)
    }

    private static func isHexDigit(_ character: Character) -> Bool {
        character.isNumber || "abcdefABCDEF".contains(character)
    }

    private static func hasPathTokenBoundary(before index: String.Index, in source: String) -> Bool {
        guard index != source.startIndex else { return true }
        let previous = source[source.index(before: index)]
        return previous.isWhitespace || "=([{,:\"'<>|;&!`\\$".contains(previous)
    }

    private static func hasPathComponentBoundary(
        after index: String.Index,
        in source: String,
        separatorEncoding: PathSeparatorEncoding
    ) -> Bool {
        guard index != source.endIndex else { return true }
        let suffix = source[index...].lowercased()
        switch separatorEncoding {
        case .literal:
            if source[index] == "/" { return true }
        case .percentEncoded:
            if suffix.hasPrefix("%2f") { return true }
        case .doublePercentEncoded:
            if suffix.hasPrefix("%252f") { return true }
        }
        let next = source[index]
        return next.isWhitespace || "=)]},;:\"'".contains(next)
    }

    private static func isAmbiguousFileAuthority(
        _ matchedPath: String,
        at index: String.Index,
        in source: String
    ) -> Bool {
        guard matchedPath.hasPrefix("//"), index != source.startIndex else { return false }
        let colon = source.index(before: index)
        guard source[colon] == ":" else { return false }
        return urlScheme(endingAt: colon, in: source)?.lowercased() == "file"
    }

    /// A raw root must not be used as a fallback match inside an obfuscated
    /// `file:` URI. Doing so would remove the slash that makes the URI
    /// detectable before the conservative decline check runs.
    private static func isFileURIPathFallback(
        _ matchedPath: String,
        at index: String.Index,
        in source: String
    ) -> Bool {
        guard index != source.startIndex else { return false }
        let colon = source.index(before: index)
        guard source[colon] == ":" else { return false }

        let decodedPath = percentDecodedForms(matchedPath)
        guard decodedPath.nestingRemains
                || decodedPath.forms.last?.hasPrefix("/") == true else { return false }

        var start = colon
        while start != source.startIndex {
            let candidate = source.index(before: start)
            let character = source[candidate]
            guard !character.isWhitespace,
                  !"=([{,/\\:\"'<>|;&!`$".contains(character) else { break }
            start = candidate
        }
        guard start != colon else { return false }

        let schemeDecoding = percentDecodedForms(String(source[start..<colon]))
        guard !schemeDecoding.nestingRemains,
              var scheme = schemeDecoding.forms.last else { return true }
        scheme = removingDefaultIgnorableSchemeCharacters(from: scheme)
        return scheme.caseInsensitiveCompare("file") == .orderedSame
    }

    private static func pathSuffixContainsTraversal(
        after index: String.Index,
        in source: String
    ) -> Bool {
        guard index != source.endIndex else { return false }
        let rawSuffix = String(source[index...].prefix { character in
            !character.isWhitespace && !",;)]}\"'<>|&".contains(character)
        })
        let decoding = percentDecodedForms(rawSuffix)
        guard !decoding.nestingRemains else { return true }
        let containsTraversal = decoding.forms.contains { form in
            form.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/", omittingEmptySubsequences: false)
                .contains("..")
        }
        guard !containsTraversal else { return true }
        let residual = decoding.forms.last?.lowercased() ?? ""
        return residual.contains("%2e") || residual.contains("%25")
    }

    private static func containsLocalFileURI(in source: String) -> Bool {
        if source.range(
            of: #"(?i)(^|[^A-Z0-9+.-])file:(?:/+|\\+)"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        let schemeDetectionText = removingDefaultIgnorableSchemeCharacters(from: source)
        guard schemeDetectionText != source else { return false }
        return schemeDetectionText.range(
            of: #"(?i)(^|[^A-Z0-9+.-])file:(?:/+|\\+)"#,
            options: .regularExpression
        ) != nil
    }

    private static func removingDefaultIgnorableSchemeCharacters(from source: String) -> String {
        String(source.unicodeScalars.filter { scalar in
            scalar.value != 0x200B
                && scalar.value != 0x200C
                && scalar.value != 0x200D
                && scalar.value != 0xFEFF
        })
    }

    private static func containsUnixAbsolutePath(in source: String) -> Bool {
        for index in source.indices where source[index] == "/" {
            if index == source.startIndex { return true }
            let previousIndex = source.index(before: index)
            let previous = source[previousIndex]
            guard previous.isWhitespace || "=([{,:\"'<>|;&!`\\$".contains(previous) else {
                continue
            }
            if previous == ":", urlScheme(endingAt: previousIndex, in: source) != nil {
                continue
            }
            return true
        }
        return false
    }

    private static func urlScheme(endingAt colon: String.Index, in source: String) -> String? {
        var start = colon
        while start != source.startIndex {
            let candidate = source.index(before: start)
            let character = source[candidate]
            guard character.isLetter || character.isNumber || "+-.".contains(character) else { break }
            start = candidate
        }
        guard start != colon,
              source[start].isLetter,
              source.distance(from: start, to: colon) <= 24 else { return nil }
        return String(source[start..<colon])
    }

    private static func containsShellExpandedPath(in source: String) -> Bool {
        source.range(
            of: #"(?i)(^|[^A-Z0-9_])(?:~|\$[A-Z_][A-Z0-9_]*|\$\{[A-Z_][A-Z0-9_]*\})[/\\]"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsWindowsAbsolutePath(in source: String) -> Bool {
        source.range(
            of: #"(?i)(^|[^A-Z0-9_.-])(?:[A-Z]:\\|\\\\)"#,
            options: .regularExpression
        ) != nil
    }
}
