import Foundation
import Testing
@testable import GobyInfrastructure

@Suite("Anchored agent-definition file mutations", .serialized)
struct AnchoredFileMutationTests {
    @Test("Replacing an authorized parent cannot redirect a reviewed create")
    func parentReplacementCannotRedirectCreate() throws {
        let container = FileManager.default.temporaryDirectory.appending(
            path: "goby-anchored-mutation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        ).resolvingSymlinksInPath()
        let authorized = container.appending(path: "authorized", directoryHint: .isDirectory)
        let retained = container.appending(path: "retained", directoryHint: .isDirectory)
        let outside = container.appending(path: "outside", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let directory = try AnchoredDirectory.openAbsolute(authorized)
        try FileManager.default.moveItem(at: authorized, to: retained)
        try FileManager.default.createSymbolicLink(at: authorized, withDestinationURL: outside)

        try directory.create("agent.toml", contents: Data("safe\n".utf8))

        #expect(FileManager.default.fileExists(atPath: retained.appending(path: "agent.toml").path()))
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "agent.toml").path()))
        #expect(try String(contentsOf: retained.appending(path: "agent.toml"), encoding: .utf8) == "safe\n")
    }

    @Test("A reviewed source is rechecked before a descriptor-relative move")
    func changedSourceCannotMove() throws {
        let container = FileManager.default.temporaryDirectory.appending(
            path: "goby-anchored-source-\(UUID().uuidString)",
            directoryHint: .isDirectory
        ).resolvingSymlinksInPath()
        let sourceURL = container.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = container.appending(path: "archive", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)
        try Data("changed".utf8).write(to: sourceURL.appending(path: "agent.toml"))

        let source = try AnchoredDirectory.openAbsolute(sourceURL)
        let archive = try AnchoredDirectory.openAbsolute(archiveURL)
        #expect(throws: AnchoredFileMutationError.changedFile) {
            try source.move(
                "agent.toml",
                to: archive,
                as: "agent.toml",
                expectedContents: Data("reviewed".utf8),
                maximumBytes: 1_024
            )
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.appending(path: "agent.toml").path()))
        #expect(!FileManager.default.fileExists(atPath: archiveURL.appending(path: "agent.toml").path()))
    }
}
