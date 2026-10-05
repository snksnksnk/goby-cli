import Foundation
import Testing
import GobyApplication
import GobyDomain
@testable import GobyInfrastructure

struct WorkspaceIdentityValidationTests {
    @Test("Working-copy preparation accepts the same authorized folder after a volume remount", arguments: [false, true])
    func acceptsRemountedDirectory(legacy: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try #require(GADFileSystemIdentity.capture(root))
        let volumeUUID = try #require(current.volumeUUIDString)
        let approved = GADFileSystemIdentity(
            device: current.device ^ 1, inode: current.inode, kind: current.kind,
            volumeUUIDString: legacy ? nil : volumeUUID
        )
        #expect(approved != current)
        #expect(approved.matchesCurrentObject(at: root))

        for isGitRepository in [false, true] {
            let project = project(at: root, identity: approved, isGitRepository: isGitRepository)
            let placement = try await manager(at: root).prepare(project: project, for: readOnlyRun())
            #expect(placement.fileSystemIdentity == current)
            #expect(placement.matchesCurrentObject())
        }
    }

    @Test("Working-copy preparation rejects a different authorized volume")
    func rejectsDifferentVolume() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try #require(GADFileSystemIdentity.capture(root))
        _ = try #require(current.volumeUUIDString)
        let wrongVolume = GADFileSystemIdentity(
            device: current.device, inode: current.inode, kind: current.kind,
            volumeUUIDString: UUID().uuidString
        )
        await #expect(throws: (any Error).self) {
            _ = try await manager(at: root).prepare(
                project: project(at: root, identity: wrongVolume), for: readOnlyRun()
            )
        }
    }

    @Test("Working-copy preparation still rejects replaced folders and directory symlinks")
    func rejectsPathSubstitution() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "Project", directoryHint: .isDirectory)
        let moved = root.appending(path: "Original", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let approved = try #require(GADFileSystemIdentity.capture(path))
        let project = project(at: path, identity: approved)
        try FileManager.default.moveItem(at: path, to: moved)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) {
            _ = try await manager(at: root).prepare(project: project, for: readOnlyRun())
        }
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: moved)
        await #expect(throws: (any Error).self) {
            _ = try await manager(at: root).prepare(project: project, for: readOnlyRun())
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "goby-workspace-identity-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func project(
        at root: URL, identity: GADFileSystemIdentity, isGitRepository: Bool = true
    ) -> LabProject {
        LabProject(
            id: "project", name: "Project", rootURL: root, platforms: [.macOS],
            isGitRepository: isGitRepository, fileSystemIdentity: identity
        )
    }

    private func manager(at root: URL) -> GitWorkspaceManager {
        GitWorkspaceManager(worktreesRoot: root.appending(path: "Worktrees"), approvals: ApprovalPolicy())
    }

    private func readOnlyRun() -> RunRecord {
        RunRecord(
            id: "run", plan: .init(id: "run", interpretedGoal: "Review", routes: [], risk: .readOnly, confidence: 1),
            status: .ready, assignments: []
        )
    }
}
