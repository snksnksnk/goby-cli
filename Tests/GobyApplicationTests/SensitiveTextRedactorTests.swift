import Foundation
import Testing
@testable import GobyApplication

@Suite("Sensitive mobile text redaction")
struct SensitiveTextRedactorTests {
    @Test("Request drafts keep the standalone plan command while paths stay redacted")
    func keepsPlanCommandOnlyInRequestDrafts() {
        let source = "build a /plan on growth using /Users/test/private and /plan/notes"
        let prepared = SensitiveTextRedactor.PreparedExactValues([])
        let draft = SensitiveTextRedactor.redact(
            source, preparedExactValues: prepared, limit: 64_000,
            preservePlanSlashCommand: true
        )

        #expect(draft == "build a /plan on growth using [redacted-path] and [redacted-path]")
        #expect(SensitiveTextRedactor.redact("/plan", limit: 64_000) == "[redacted-path]")
    }

    @Test("Cached redaction never reuses a result across forbidden-value sets")
    func cachedRedactionIsScopedToExactValues() {
        let source = "deploy with project-secret-alpha to /Users/test/app"
        let empty = SensitiveTextRedactor.PreparedExactValues([])
        let secret = SensitiveTextRedactor.PreparedExactValues(["project-secret-alpha"])
        let reordered = SensitiveTextRedactor.PreparedExactValues(["abc", "project-secret-alpha"])
        let sameSet = SensitiveTextRedactor.PreparedExactValues(["abc", "project-secret-alpha", "abc"])

        #expect(secret.generation != empty.generation)
        #expect(reordered.generation == sameSet.generation)
        for _ in 0..<2 {
            #expect(SensitiveTextRedactor.redact(source, preparedExactValues: empty, limit: 1_000)
                == "deploy with project-secret-alpha to [redacted-path]")
            #expect(SensitiveTextRedactor.redact(source, preparedExactValues: secret, limit: 1_000)
                == "deploy with [redacted] to [redacted-path]")
            #expect(SensitiveTextRedactor.redact(source, preparedExactValues: secret, limit: 10)
                == "deploy wit")
        }
    }

    @Test("Exact provider credentials are removed from instruction-style artifacts")
    func removesExactProviderCredentialFromArtifacts() throws {
        let credential = "provider-material+with/nonstandard=shape"
        let encoded = try #require(
            credential.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let samples = [
            "Instruction body embeds \(credential) without a key label.",
            "Provider override: \(credential)",
            "Catalog evidence contains \(encoded)",
        ]

        for source in samples {
            let redacted = SensitiveTextRedactor.redact(
                source,
                exactForbiddenValues: [credential],
                limit: 64_000
            )
            #expect(!redacted.contains(credential))
            #expect(!redacted.contains(encoded))
            #expect(redacted.contains("[redacted]"))
        }
    }

    @Test("Prepared redaction handles repeated and encoded values across many task fields")
    func preparedExactValuesRedactRepeatedFields() throws {
        let forbidden = "/Users/test/Private Project"
        let encoded = try #require(forbidden.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let unrelated = (0..<200).map { "/Users/test/Other Project \($0)" }
        let prepared = SensitiveTextRedactor.PreparedExactValues(
            Array(repeating: forbidden, count: 200) + unrelated
        )
        #expect(prepared.replacements.count == 201)

        for index in 0..<700 {
            let source = "Task \(index): \(index.isMultiple(of: 2) ? forbidden : encoded)"
            let result = SensitiveTextRedactor.redact(
                source, preparedExactValues: prepared, limit: 240
            )
            #expect(result.contains("[redacted]"))
            #expect(!result.contains(forbidden))
            #expect(!result.contains(encoded))
        }
    }

    @Test("PEM, JWT, and uncommon provider tokens are redacted before mobile display")
    func removesStructuredCredentials() {
        let source = """
        -----BEGIN PRIVATE KEY-----
        secret-key-material
        -----END PRIVATE KEY-----
        eyJabcdefghijk.eyJlmnopqrstuvwxyz.abcdefghijklmnopqrstuvwxyz
        sk-ant-unusualCredential123
        """
        let redacted = SensitiveTextRedactor.redact(source, limit: 64_000)

        #expect(!redacted.contains("secret-key-material"))
        #expect(!redacted.contains("eyJabcdefghijk"))
        #expect(!redacted.contains("sk-ant-unusualCredential123"))
    }

    @Test("Authorized path aliases apply only to exact roots and descendants")
    func aliasesOnlyComponentBoundaries() {
        let source = #"{"inside":"/Users/test/Project/Sources/App.swift","root":"/Users/test/Project","sibling":"/Users/test/Project-backup/secret.txt","prefixed":"/tmp/Users/test/Project/secret.txt"}"#
        let aliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
            source,
            aliases: [(path: "/Users/test/Project", alias: "Project «Main»")]
        )

        #expect(aliased.contains(#""inside":"Project «Main»/Sources/App.swift""#))
        #expect(aliased.contains(#""root":"Project «Main»""#))
        #expect(aliased.contains("/Users/test/Project-backup/secret.txt"))
        #expect(aliased.contains("/tmp/Users/test/Project/secret.txt"))
    }

    @Test("Authorized path aliases support fully encoded Unicode roots and prefer the narrowest matching scope")
    func aliasesEncodedUnicodeAndOverlappingRoots() throws {
        let root = "/Users/test/Σχέδιο App"
        let encoded = try #require(root.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let aliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
            #"{"path":"\#(encoded)%2FSources%2FView.swift","secret":"/Users/test/Σχέδιο App/Secrets/key.txt"}"#,
            aliases: [
                (path: root, alias: "Project «App»"),
                (path: root + "/Secrets", alias: "Shared resource «Secrets»"),
            ]
        )

        #expect(aliased.contains("Project «App»%2FSources%2FView.swift"))
        #expect(aliased.contains("Shared resource «Secrets»/key.txt"))
        #expect(!aliased.contains(encoded))
    }

    @Test("Naked partially encoded paths remain ambiguous and decline-only")
    func rejectsNakedPartiallyEncodedAuthorizedRoot() {
        let root = "/Users/test/Project A"
        let ambiguousRawPath = "/Users/test/Project%20A/secret.txt"
        let aliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
            ambiguousRawPath,
            aliases: [(path: root, alias: "Project «Main»")]
        )

        #expect(aliased == ambiguousRawPath)
        #expect(SensitiveTextRedactor.containsUnaliasedAbsoluteFileSystemPath(aliased))

        let literalAliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
            "\(root)/secret.txt",
            aliases: [(path: root, alias: "Project «Main»")]
        )
        #expect(literalAliased == "Project «Main»/secret.txt")
    }

    @Test("Authorized path comparison preserves invisible filesystem characters")
    func preservesInvisibleCharactersInRawPaths() {
        let root = "/Users/test/Project"
        for invisible in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"] {
            let distinctPath = "/Users/test/Pro\(invisible)ject/secret.txt"
            let aliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
                distinctPath,
                aliases: [(path: root, alias: "Project «Main»")]
            )

            #expect(!aliased.contains("Project «Main»"))
            #expect(aliased == distinctPath)
            #expect(SensitiveTextRedactor.containsUnaliasedAbsoluteFileSystemPath(aliased))

            let exactAliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
                distinctPath,
                aliases: [
                    (path: "/Users/test/Pro\(invisible)ject", alias: "Project «Invisible»"),
                ]
            )
            #expect(exactAliased == "Project «Invisible»/secret.txt")
        }
    }

    @Test("Raw percent spelling stays distinct while encoded roots accept lowercase escapes")
    func preservesLiteralPercentCaseInRawPaths() throws {
        let root = "/Users/test/Project/%2Fbucket"
        let distinctRawPath = "/Users/test/Project/%2fbucket/secret.txt"
        let distinctAliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
            distinctRawPath,
            aliases: [(path: root, alias: "Project «Bucket»")]
        )

        #expect(distinctAliased == distinctRawPath)
        #expect(SensitiveTextRedactor.containsUnaliasedAbsoluteFileSystemPath(distinctAliased))

        let exactAliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
            "\(root)/secret.txt",
            aliases: [(path: root, alias: "Project «Bucket»")]
        )
        #expect(exactAliased == "Project «Bucket»/secret.txt")

        let fullyEncoded = try #require(
            root.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let lowercaseEncodedSeparators = fullyEncoded.replacingOccurrences(of: "%2F", with: "%2f")
        let encodedAliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
            "\(lowercaseEncodedSeparators)%2fsecret.txt",
            aliases: [(path: root, alias: "Project «Bucket»")]
        )
        #expect(encodedAliased == "Project «Bucket»%2fsecret.txt")
        #expect(!SensitiveTextRedactor.containsUnaliasedAbsoluteFileSystemPath(encodedAliased))
    }

    @Test("Raw roots do not consume percent-looking sibling names")
    func rejectsPercentEncodedSeparatorAfterRawRoot() {
        let root = "/Users/test/Project"
        for sibling in [
            "/Users/test/Project%2f-secret/file.txt",
            "/Users/test/Project%2F-secret/file.txt",
            "/Users/test/Project%252f-secret/file.txt",
            "/Users/test/Project%252F-secret/file.txt",
        ] {
            let aliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
                sibling,
                aliases: [(path: root, alias: "Project «Main»")]
            )

            #expect(aliased == sibling)
            #expect(SensitiveTextRedactor.containsUnaliasedAbsoluteFileSystemPath(aliased))
        }
    }

    @Test("Authorized aliases cover shell, file URL, and fully encoded path forms")
    func aliasesAlternateAuthorizedPathForms() throws {
        let root = "/Users/test/Project"
        let fullyEncoded = try #require(
            root.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let doubleEncoded = try #require(
            fullyEncoded.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let encodedFileURL = try #require(
            "file://\(root)".addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let encodedSingleSlashFileURL = try #require(
            "file:\(root)".addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let localhostFileURL = "file://localhost\(root)/localhost"
        let lowercaseEncodedPath = "%2fUsers%2ftest%2fProject%2fchild"
        let source = "--output=\(root)/out >//Users/test/Project/log \(fullyEncoded)%2Fchild \(doubleEncoded)%252Fdeep \(encodedFileURL)%2Ffile file:\(root)/single \(encodedSingleSlashFileURL)%2Fencoded \(localhostFileURL) \(lowercaseEncodedPath)"

        let aliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
            source,
            aliases: [(path: root, alias: "Project «Main»")]
        )

        #expect(!SensitiveTextRedactor.containsUnaliasedAbsoluteFileSystemPath(aliased))
        #expect(aliased.components(separatedBy: "Project «Main»").count == 10)
    }

    @Test("Outside and ambiguous path representations remain decline-only")
    func detectsAlternateOutsidePathForms() {
        let samples = [
            "--output=/Users/test/Outside/file",
            ">/Users/test/Outside/file",
            #"\/Users/test/Outside/file"#,
            "//Users/test/Outside/file",
            "%2FUsers%2Ftest%2FOutside%2Ffile",
            "%252FUsers%252Ftest%252FOutside%252Ffile",
            "file%3A%2F%2F%2FUsers%2Ftest%2FOutside%2Ffile",
            "file:/Users/test/Outside/file",
            "FILE:/Users/test/Outside/file",
            "file%3A/Users/test/Outside/file",
            "f%69le:/Users/test/Outside/file",
            "file%253A%252FUsers%252Ftest%252FOutside%252Ffile",
            "f\u{200B}ile:/Users/test/Outside/file",
            "fi\u{200C}le:/Users/test/Outside/file",
            "fil\u{200D}e:/Users/test/Outside/file",
            "\u{FEFF}file:/Users/test/Outside/file",
            "https://example.test/?path=/Users/test/Outside/file",
            "$HOME/Outside/file",
        ]

        for sample in samples {
            #expect(
                SensitiveTextRedactor.containsUnaliasedAbsoluteFileSystemPath(sample),
                "Expected outside path detection for \(sample)"
            )
        }
    }

    @Test("Obfuscated file schemes cannot shed their detectable slash through root aliasing")
    func rejectsObfuscatedFileSchemeFallbackAliasing() {
        let root = "/Users/test/Project"
        for source in [
            "f\u{200B}ile:\(root)/secret.txt",
            "fi\u{200C}le:\(root)/secret.txt",
            "fil\u{200D}e:\(root)/secret.txt",
            "\u{FEFF}file:\(root)/secret.txt",
            "f%69le:\(root)/secret.txt",
        ] {
            let aliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
                source,
                aliases: [(path: root, alias: "Project «Main»")]
            )

            #expect(!aliased.contains("Project «Main»"))
            #expect(SensitiveTextRedactor.containsUnaliasedAbsoluteFileSystemPath(aliased))
        }
    }

    @Test("Traversal and nonlocal file authorities cannot inherit an authorized-root alias")
    func rejectsAmbiguousAuthorizedPathForms() {
        let root = "/Users/test/Project"
        let samples = [
            "\(root)/../Outside/file",
            "\(root)/%2E%2E/Outside/file",
            "\(root)/%252E%252E/Outside/file",
            "\(root)/%25252E%25252E/Outside/file",
            "file://Users/test/Project/file",
        ]

        for sample in samples {
            let aliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
                sample,
                aliases: [(path: root, alias: "Project «Main»")]
            )
            #expect(
                SensitiveTextRedactor.containsUnaliasedAbsoluteFileSystemPath(aliased),
                "Expected ambiguous path detection for \(sample)"
            )
        }
    }

    @Test("Encoded obfuscated file schemes cannot alias a fully encoded root fallback")
    func rejectsEncodedObfuscatedFileSchemeFallbackAliasing() {
        let root = "/Users/test/Project"
        let source = "f%69le:%2FUsers%2Ftest%2FProject%2Fsecret.txt"
        let aliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
            source,
            aliases: [(path: root, alias: "Project «Main»")]
        )

        #expect(aliased == source)
        #expect(SensitiveTextRedactor.containsUnaliasedAbsoluteFileSystemPath(aliased))
    }

    @Test("Deeply nested percent roots remain decline-only behind obfuscated file schemes")
    func rejectsDeeplyNestedPercentFileSchemeFallbackAliasing() throws {
        let nestedComponent = "%" + String(repeating: "25", count: 9) + "2Fbucket"
        let root = "/Users/test/Project/\(nestedComponent)"
        let encodedRoot = try #require(
            root.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let source = "f%69le:\(encodedRoot)%2Fsecret.txt"
        let aliased = SensitiveTextRedactor.aliasAuthorizedFileSystemPaths(
            source,
            aliases: [(path: root, alias: "Project «Nested»")]
        )

        #expect(aliased == source)
        #expect(SensitiveTextRedactor.containsUnaliasedAbsoluteFileSystemPath(aliased))
    }

    @Test("Single-slash file URIs are redacted outside approval policy")
    func redactsSingleSlashFileURI() {
        let redacted = SensitiveTextRedactor.redact(
            "Open file:/Users/test/Outside/file",
            limit: 1_000
        )

        #expect(redacted == "Open [redacted-path]")
    }

    @Test("Network URLs are not mistaken for host file paths")
    func allowsNetworkURLs() {
        for source in [
            "Download https://example.test/api/v1 before continuing.",
            "Download https://example.test/api%2Fv1 before continuing.",
            "Download https://example.test/api%252Fv1 before continuing.",
            "Connect wss://relay.example.test/v1.",
            "Open goby://project/project-a.",
        ] {
            #expect(!SensitiveTextRedactor.containsUnaliasedAbsoluteFileSystemPath(source))
        }
    }
}
