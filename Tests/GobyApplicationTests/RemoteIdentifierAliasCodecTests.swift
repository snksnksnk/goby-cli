import Foundation
@testable import GobyApplication
import GobyDomain
import Testing

@Suite("Remote identifier aliases")
struct RemoteIdentifierAliasCodecTests {
    @Test("Path-derived typed identifiers use stable installation-keyed remote aliases")
    func aliasesAreStableAndKeyed() throws {
        let source = AliasFixture(
            projectID: ProjectID.derived(
                fromProjectRoot: URL(fileURLWithPath: "/Users/alice/Desktop/SecretProject")
            ),
            agentID: AgentID(rawValue: "agent-deadbeef"),
            bindingID: ProviderAgentBindingID(rawValue: "binding-cafebabe"),
            text: "project-deadbeef"
        )
        let firstCodec = try RemoteIdentifierAliasCodec(keyData: Data(repeating: 1, count: 32))
        let secondCodec = try RemoteIdentifierAliasCodec(keyData: Data(repeating: 2, count: 32))

        let first = try firstCodec.aliasing(source)
        let repeated = try firstCodec.aliasing(source)
        let second = try secondCodec.aliasing(source)

        #expect(first.value == repeated.value)
        #expect(first.value.projectID.rawValue.hasPrefix("remote-project-v1-"))
        #expect(first.value.agentID.rawValue.hasPrefix("remote-agent-v1-"))
        #expect(first.value.bindingID.rawValue.hasPrefix("remote-binding-v1-"))
        #expect(first.value.projectID != second.value.projectID)
        #expect(first.value.agentID != second.value.agentID)
        #expect(first.value.text == source.text)
        #expect(try firstCodec.localizing(first.value, aliases: first.aliases) == source)
    }

    @Test("Unknown remote aliases fail closed without rewriting ordinary text")
    func unknownAliasesFailClosed() throws {
        let codec = try RemoteIdentifierAliasCodec(keyData: Data(repeating: 3, count: 32))
        let unknown = AliasFixture(
            projectID: ProjectID(rawValue: "remote-project-v1-" + String(repeating: "0", count: 64)),
            agentID: AgentID(rawValue: "agent-local"),
            bindingID: ProviderAgentBindingID(rawValue: "binding-local"),
            text: "remote-project-v1-" + String(repeating: "0", count: 64)
        )

        #expect(throws: RemoteIdentifierAliasCodecError.unknownAlias) {
            try codec.localizing(unknown, aliases: RemoteIdentifierAliasTable())
        }
    }

    @Test("A remote draft command translates only its typed route identifiers")
    func commandLocalizationPreservesPromptBytes() throws {
        let codec = try RemoteIdentifierAliasCodec(keyData: Data(repeating: 4, count: 32))
        let projectID = ProjectID(rawValue: "project-deadbeef")
        let agentID = AgentID(rawValue: "agent-cafebabe")
        let source = GADDraftReplacement(
            expectedRevision: .zero,
            text: "remote-project-v1-" + String(repeating: "9", count: 64),
            projectIDs: [projectID],
            agentTargets: [AgentRouteTarget(agentID: agentID, projectID: projectID)],
            groupID: nil
        )

        let remote = try codec.aliasing(source)
        let localized = try codec.localizing(remote.value, aliases: remote.aliases)

        #expect(remote.value.projectIDs[0].rawValue.hasPrefix("remote-project-v1-"))
        #expect(remote.value.agentTargets[0].agentID.rawValue.hasPrefix("remote-agent-v1-"))
        #expect(localized == source)
        #expect(localized.text == source.text)
    }

    @Test("A reviewed project ID localizes when confirming folder import")
    func localizesReviewedProjectImportSelection() throws {
        let codec = try RemoteIdentifierAliasCodec(keyData: Data(repeating: 5, count: 32))
        let projectID = ProjectID.derived(
            fromProjectRoot: URL(fileURLWithPath: "/Users/alice/Desktop/Pharmacies")
        )
        let candidate = GADHostLocalProjectCandidate(
            id: projectID, name: "Pharmacies",
            rootURL: URL(fileURLWithPath: "/Users/alice/Desktop/Pharmacies"),
            platforms: [.web], frameworks: [],
            isGitRepository: true, evidence: []
        )
        let reviewed = try codec.aliasing(GADHostIPCArtifact.localProjectCandidates([candidate]))
        guard case let .localProjectCandidates(candidates) = reviewed.value,
              let selectedID = candidates.first?.id else {
            Issue.record("Expected a reviewed project candidate")
            return
        }
        #expect(selectedID != projectID)
        #expect(candidates.first?.rootURL == candidate.rootURL)

        let confirmation = GADHostLocalCommand.registerProjectBookmarks(
            bookmarks: [Data([1, 2, 3])], selectedProjectIDs: [selectedID]
        )
        let localized = try codec.localizing(confirmation, aliases: reviewed.aliases)
        #expect(localized == .registerProjectBookmarks(
            bookmarks: [Data([1, 2, 3])], selectedProjectIDs: [projectID]
        ))
    }
}

private struct AliasFixture: Codable, Equatable, Sendable {
    let projectID: ProjectID
    let agentID: AgentID
    let bindingID: ProviderAgentBindingID
    let text: String
}
