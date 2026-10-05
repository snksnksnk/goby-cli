import Foundation
import GobyDomain

public struct ProjectGitBranchSnapshot: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let currentBranch: String?
    public let localBranches: [String]
    public let hasUncommittedChanges: Bool
    /// The current branch's upstream remote, or `origin` when the branch has
    /// none. Absent from older hosts.
    public let pushRemote: String?
    /// Changed and untracked files in the working copy. Absent from older hosts.
    public let changedFileCount: Int?

    public init(
        projectID: ProjectID,
        currentBranch: String?,
        localBranches: [String],
        hasUncommittedChanges: Bool,
        pushRemote: String? = nil,
        changedFileCount: Int? = nil
    ) {
        self.projectID = projectID
        self.currentBranch = currentBranch
        self.localBranches = localBranches
        self.hasUncommittedChanges = hasUncommittedChanges
        self.pushRemote = pushRemote
        self.changedFileCount = changedFileCount
    }
}

/// Exact user-approved branch transition. The destination is deliberately a
/// local branch: fetching, creating branches, and modifying remotes remain
/// separate operations with their own approval boundaries.
public struct ProjectGitBranchSwitchApproval: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let expectedCurrentBranch: String?
    public let destinationBranch: String

    public init(
        projectID: ProjectID,
        expectedCurrentBranch: String?,
        destinationBranch: String
    ) {
        self.projectID = projectID
        self.expectedCurrentBranch = expectedCurrentBranch
        self.destinationBranch = destinationBranch
    }
}

public protocol ProjectGitBranchManaging: Sendable {
    func inspect(project: LabProject) async throws -> ProjectGitBranchSnapshot
    func switchBranch(
        project: LabProject,
        approval: ProjectGitBranchSwitchApproval
    ) async throws -> ProjectGitBranchSnapshot
}

public struct InspectProjectGitBranchesUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let branches: any ProjectGitBranchManaging

    public init(catalog: any LabCatalogRepository, branches: any ProjectGitBranchManaging) {
        self.catalog = catalog
        self.branches = branches
    }

    public func callAsFunction(projectID: ProjectID) async throws -> ProjectGitBranchSnapshot {
        let snapshot = try await catalog.snapshot()
        guard let project = snapshot.projects.first(where: { $0.id == projectID }) else {
            throw GobyApplicationError.unknownProject(projectID)
        }
        guard project.isGitRepository else {
            throw GobyApplicationError.projectIsNotGitRepository(project.name)
        }
        return try await branches.inspect(project: project)
    }
}

public struct SwitchProjectGitBranchUseCase: Sendable {
    private let catalog: any LabCatalogRepository
    private let branches: any ProjectGitBranchManaging

    public init(catalog: any LabCatalogRepository, branches: any ProjectGitBranchManaging) {
        self.catalog = catalog
        self.branches = branches
    }

    public func callAsFunction(
        approval: ProjectGitBranchSwitchApproval
    ) async throws -> ProjectGitBranchSnapshot {
        let snapshot = try await catalog.snapshot()
        guard let project = snapshot.projects.first(where: { $0.id == approval.projectID }) else {
            throw GobyApplicationError.unknownProject(approval.projectID)
        }
        guard project.isGitRepository else {
            throw GobyApplicationError.projectIsNotGitRepository(project.name)
        }
        let destination = approval.destinationBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty,
              destination == approval.destinationBranch,
              !destination.hasPrefix("-"),
              destination != approval.expectedCurrentBranch else {
            throw GobyApplicationError.invalidProjectGitBranchSwitch
        }
        return try await branches.switchBranch(project: project, approval: approval)
    }
}
