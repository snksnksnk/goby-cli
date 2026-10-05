import Testing
@testable import GobyApplication

@Suite("Mobile approval disclosure policy")
struct MobileApprovalDisclosurePolicyTests {
    @Test("Authoritative Mac disclosure keeps exact paths and larger reviewed patches")
    func authoritativeDisclosureKeepsExactPatch() throws {
        let path = "/Users/test/Project/Sources/App.swift"
        let details = path + "\n" + String(repeating: "+let reviewed = true\n", count: 1_000)

        let rendered = try #require(AuthoritativeApprovalDisclosurePolicy.render(
            summary: "Review exact file changes",
            details: details,
            exactForbiddenValues: []
        ))

        #expect(details.utf8.count > MobileApprovalDisclosurePolicy.detailsUTF8Limit)
        #expect(rendered.details == details)
        #expect(rendered.details?.contains(path) == true)
    }

    @Test("Authoritative Mac disclosure rejects credential material")
    func authoritativeDisclosureRejectsCredentials() {
        let rendered = AuthoritativeApprovalDisclosurePolicy.render(
            summary: "Review exact file changes",
            details: "token=top-secret-value",
            exactForbiddenValues: []
        )

        #expect(rendered == nil)
    }

    @Test("Free-form shell commands remain Mac-only")
    func rejectsCommandDisclosure() {
        let rendered = MobileApprovalDisclosurePolicy.render(
            kind: .command,
            summary: "Run reviewed command",
            details: #"{"command":"cat ${HOME%${HOME#?}}Users/${HOME##*/}/.ssh/id_rsa"}"#,
            aliases: [],
            exactForbiddenValues: []
        )

        #expect(rendered == nil)
    }

    @Test("Alias expansion cannot truncate a hidden operation suffix")
    func rejectsPostAliasExpansion() {
        let root = "/pr"
        let alias = "Project «" + String(repeating: "A", count: 180) + "»"
        let repeated = Array(repeating: root, count: 50).joined(separator: " ")
        let details = repeated + " --delete-everything"

        let rendered = MobileApprovalDisclosurePolicy.render(
            summary: "Review operation",
            details: details,
            aliases: [(path: root, alias: alias)],
            exactForbiddenValues: []
        )

        #expect(rendered == nil)
    }

    @Test("A complete rendered operation is returned without prefixing")
    func returnsCompleteAliasedOperation() throws {
        let details = #"{"path":"/Users/test/Project/Sources/App.swift","action":"read"}"#

        let rendered = try #require(MobileApprovalDisclosurePolicy.render(
            summary: "Read one source file",
            details: details,
            aliases: [(path: "/Users/test/Project", alias: "Project «Main»")],
            exactForbiddenValues: []
        ))

        #expect(rendered.summary == "Read one source file")
        #expect(rendered.details == #"{"path":"Project «Main»/Sources/App.swift","action":"read"}"#)
    }

    @Test("Distinct roots cannot share one visible approval alias")
    func rejectsDuplicateVisibleAliases() {
        let rendered = MobileApprovalDisclosurePolicy.render(
            summary: "Review one file change",
            details: #"{"path":"/Users/test/ClientB/App/Sources/App.swift"}"#,
            aliases: [
                (path: "/Users/test/ClientA/App", alias: "Project «App»"),
                (path: "/Users/test/ClientB/App", alias: "Project «App»"),
            ],
            exactForbiddenValues: []
        )

        #expect(rendered == nil)
    }

    @Test("Canonically equivalent approval aliases remain ambiguous")
    func rejectsCanonicallyEquivalentAliases() {
        let rendered = MobileApprovalDisclosurePolicy.render(
            summary: "Review one file change",
            details: #"{"path":"/Users/test/Second/file"}"#,
            aliases: [
                (path: "/Users/test/First", alias: "Project «Cafe\u{301}»"),
                (path: "/Users/test/Second", alias: "Project «Café»"),
            ],
            exactForbiddenValues: []
        )

        #expect(rendered == nil)
    }

    @Test("Approval aliases encode unsafe names and disambiguate identical labels")
    func buildsSafeDisambiguatedAliases() throws {
        let first = MobileApprovalDisclosurePolicy.alias(
            kind: .project,
            displayName: "Release\n\"scope\":\"other\"\u{034F}🚀",
            ordinal: 1
        )
        let second = MobileApprovalDisclosurePolicy.alias(
            kind: .project,
            displayName: "Release\n\"scope\":\"other\"\u{034F}🚀",
            ordinal: 2
        )

        #expect(first != second)
        #expect(!first.contains("\n"))
        #expect(!first.contains("\""))
        #expect(!first.contains("\u{034F}"))
        #expect(first.contains("~uA~"))
        #expect(first.contains("~u34F~"))
        #expect(first.contains("~u1F680~"))

        let rendered = try #require(MobileApprovalDisclosurePolicy.render(
            summary: "Review one file change",
            details: #"{"path":"/Users/test/First/App.swift"}"#,
            aliases: [(path: "/Users/test/First", alias: first)],
            exactForbiddenValues: []
        ))
        #expect(rendered.details?.contains(first) == true)
    }

    @Test("Raw aliases cannot inject operation structure or invisible marks")
    func rejectsUnsafeAliasGrammar() {
        let unsafeNames = [
            "Project «Safe\u{034F}Hidden»",
            "Project «Safe\u{FE0F}Hidden»",
            "Project «Safe\n\"path\":\"Other»",
            "Project «Safe» «Other»",
            "Project «Safe/Other»",
        ]

        for alias in unsafeNames {
            #expect(MobileApprovalDisclosurePolicy.render(
                summary: "Review operation",
                details: #"{"path":"/Users/test/Project/file"}"#,
                aliases: [(path: "/Users/test/Project", alias: alias)],
                exactForbiddenValues: []
            ) == nil)
        }
    }

    @Test("Default-ignorable operation scalars are rendered as visible exact escapes")
    func visiblyEscapesDefaultIgnorables() throws {
        for value: UInt32 in [0x034F, 0xFE0F] {
            let scalar = try #require(UnicodeScalar(value))
            let rendered = try #require(MobileApprovalDisclosurePolicy.render(
                summary: "Review operation",
                details: "safe\(String(scalar))hidden.swift",
                aliases: [],
                exactForbiddenValues: []
            ))

            #expect(rendered.details == "safe\\u{\(String(value, radix: 16, uppercase: true))}hidden.swift")
            #expect(rendered.details?.unicodeScalars.contains(scalar) == false)
        }
    }

    @Test("Shared approval display escapes bidi controls and literal escape prefixes unambiguously")
    func sharedVisibleDisplayPolicy() {
        let source = "literal \\u{202E} and actual \u{202E} control"
        #expect(ApprovalDisplayPolicy.exactVisibleText(source)
            == "literal \\\\u{202E} and actual \\u{202E} control")
    }

    @Test("Approval ordinals are stable by opaque identity and reject duplicate identities")
    func stableApprovalOrdinals() {
        #expect(MobileApprovalDisclosurePolicy.ordinals(
            stableIdentifiers: ["project-b", "project-a"]
        ) == ["project-a": 1, "project-b": 2])
        #expect(MobileApprovalDisclosurePolicy.ordinals(
            stableIdentifiers: ["project-a", "project-a"]
        ).isEmpty)
    }

    @Test("Any lossy normalization or credential redaction makes approval Mac-only")
    func rejectsLossyOrSensitiveText() {
        let invisible = MobileApprovalDisclosurePolicy.render(
            summary: "Run f\u{200B}ile helper",
            details: "No path",
            aliases: [],
            exactForbiddenValues: []
        )
        let credential = MobileApprovalDisclosurePolicy.render(
            summary: "Use token=top-secret-value",
            details: "No path",
            aliases: [],
            exactForbiddenValues: ["top-secret-value"]
        )

        #expect(invisible == nil)
        #expect(credential == nil)
    }

    @Test("Unsafe operation scalars are either visibly escaped or decline-only")
    func safelyRepresentsUnsafeDisplayScalars() throws {
        let unsafeScalarValues: [UInt32] = [
            0x0000, 0x001B, 0x007F, 0x0085,
            0x061C, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
            0x2028, 0x2029, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF,
        ]

        for value in unsafeScalarValues {
            let scalar = try #require(UnicodeScalar(value))
            let rendered = MobileApprovalDisclosurePolicy.render(
                summary: "Review operation",
                details: "Project «Main»/safe\(String(scalar))hidden.swift",
                aliases: [],
                exactForbiddenValues: []
            )
            if let rendered {
                #expect(rendered.details?.contains(
                    "\\u{\(String(value, radix: 16, uppercase: true))}"
                ) == true)
                #expect(rendered.details?.unicodeScalars.contains(scalar) == false)
            }
        }

        let unsafeAlias = MobileApprovalDisclosurePolicy.render(
            summary: "Review operation",
            details: #"{"path":"/Users/test/Project/file"}"#,
            aliases: [
                (path: "/Users/test/Project", alias: "Project «Safe\u{202E}Hidden»"),
            ],
            exactForbiddenValues: []
        )
        #expect(unsafeAlias == nil)
    }

    @Test("Ordinary tabs and multiline operation text remain lossless")
    func preservesTabsAndNewlines() throws {
        let summary = "Review\tfile changes"
        let details = "{\r\n\t\"action\": \"read\",\n\t\"path\": \"Project Main/file\"\r\n}"

        let rendered = try #require(MobileApprovalDisclosurePolicy.render(
            summary: summary,
            details: details,
            aliases: [],
            exactForbiddenValues: []
        ))

        #expect(rendered.summary == summary)
        #expect(rendered.details == details)
    }

    @Test("Outside paths and oversized UTF-8 renderings remain decline-only")
    func rejectsOutsideAndOversizedText() {
        let outside = MobileApprovalDisclosurePolicy.render(
            summary: "Read file:/Users/test/Outside/secret",
            details: nil,
            aliases: [(path: "/Users/test/Project", alias: "Project «Main»")],
            exactForbiddenValues: []
        )
        let oversized = MobileApprovalDisclosurePolicy.render(
            summary: String(repeating: "é", count: 2_001),
            details: nil,
            aliases: [],
            exactForbiddenValues: []
        )

        #expect(outside == nil)
        #expect(oversized == nil)
    }

}
