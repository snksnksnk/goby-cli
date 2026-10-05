import Foundation
import GobyApplication
import GobyDomain

public enum AgentRestructureError: LocalizedError, Sendable {
    case missingSource(URL)
    case targetExists(URL)
    case recoveryConflict(URL)
    case unsafePath(URL)

    public var errorDescription: String? {
        switch self {
        case let .missingSource(url): "Agent source is missing: \(url.path(percentEncoded: false))"
        case let .targetExists(url): "The proposed agent target already exists: \(url.path(percentEncoded: false))"
        case let .recoveryConflict(url): "Undo stopped to avoid overwriting or deleting a changed file at \(url.path(percentEncoded: false))."
        case let .unsafePath(url): "Agent file safety changed at \(url.path(percentEncoded: false)). Refresh the review before trying again."
        }
    }
}

public actor AgentDefinitionRestructurer: AgentDefinitionRestructuring {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func preview(candidates: [AgentImportCandidate]) throws -> [AgentDefinitionChangePreview] {
        let batch = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        return candidates.compactMap { candidate in
            // Moving an active definition without atomically updating its Codex
            // registration would leave a broken role. Registered roles remain in
            // place; users can still import and route them normally.
            guard candidate.profile.codexRegistrationKey == nil,
                  let originalSource = candidate.profile.sourceURL else { return nil }
            let source = originalSource.resolvingSymlinksInPath().standardizedFileURL
            let directory = source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard normalizedPath(source.deletingLastPathComponent()) == normalizedPath(directory),
                  isSafeRegularFile(source),
                  let sourceContents = boundedString(contentsOf: source),
                  sourceContents == candidate.configurationPreview else { return nil }
            let archive = directory
                .appending(path: ".goby-archive", directoryHint: .isDirectory)
                .appending(path: batch, directoryHint: .isDirectory)
                .appending(path: source.lastPathComponent)
            let target = directory.appending(path: "\(slug(candidate.profile.name)).toml")
            let capabilities = candidate.profile.capabilities.map(\.rawValue).sorted().joined(separator: ", ")
            let header = "# Goby capability structure: \(capabilities)\n# Original archived at: \(archive.path(percentEncoded: false))\n"
            return AgentDefinitionChangePreview(
                agentID: candidate.id,
                sourceURL: source,
                archiveURL: archive,
                targetURL: target,
                proposedContents: header + candidate.configurationPreview.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
                authorizedDirectoryURL: directory,
                expectedSourceContents: sourceContents
            )
        }
    }

    public func apply(_ changes: [AgentDefinitionChangePreview]) throws {
        var applied: [AgentDefinitionChangePreview] = []
        do {
            for change in changes {
                do {
                    try apply(change)
                } catch {
                    throw translated(error, for: change)
                }
                applied.append(change)
            }
        } catch {
            for change in applied.reversed() { try? undo(change) }
            throw error
        }
    }

    public func undo(_ changes: [AgentDefinitionChangePreview]) throws {
        for change in changes.reversed() {
            do {
                try undo(change)
            } catch {
                throw translated(error, for: change)
            }
        }
    }

    private func translated(
        _ error: Error,
        for change: AgentDefinitionChangePreview
    ) -> Error {
        if error is AgentRestructureError { return error }
        guard let mutationError = error as? AnchoredFileMutationError else { return error }
        switch mutationError {
        case .missingFile, .unexpectedFile, .changedFile, .fileTooLarge:
            return AgentRestructureError.recoveryConflict(change.targetURL)
        case .unsafeDirectory, .unsafeName, .operationFailed,
             .directoryComponentFailed, .pathNotContained:
            return AgentRestructureError.unsafePath(change.sourceURL)
        }
    }

    private func apply(_ change: AgentDefinitionChangePreview) throws {
        try validate(change)
        guard let authorizedURL = change.authorizedDirectoryURL?.standardizedFileURL,
              let expected = change.expectedSourceContents else {
            throw AgentRestructureError.recoveryConflict(change.sourceURL)
        }
        let authorized = try AnchoredDirectory.openAbsolute(authorizedURL)
        let sourceName = change.sourceURL.lastPathComponent
        let targetName = change.targetURL.lastPathComponent
        let archiveName = change.archiveURL.lastPathComponent
        let archiveComponents = try relativePathComponents(
            change.archiveURL.deletingLastPathComponent(),
            inside: authorizedURL
        )
        let archive = try authorized.descendant(archiveComponents, create: true)
        let expectedData = Data(expected.utf8)
        guard try authorized.read(sourceName, maximumBytes: 1_048_576) == expectedData else {
            throw AgentRestructureError.recoveryConflict(change.sourceURL)
        }
        let samePath = change.sourceURL.standardizedFileURL == change.targetURL.standardizedFileURL
        if !samePath, try authorized.contains(targetName) {
            throw AgentRestructureError.targetExists(change.targetURL)
        }
        guard try !archive.contains(archiveName) else {
            throw AgentRestructureError.targetExists(change.archiveURL)
        }
        try authorized.move(
            sourceName,
            to: archive,
            as: archiveName,
            expectedContents: expectedData,
            maximumBytes: 1_048_576
        )
        do {
            try authorized.create(targetName, contents: Data(change.proposedContents.utf8))
        } catch {
            try? archive.move(
                archiveName,
                to: authorized,
                as: sourceName,
                expectedContents: expectedData,
                maximumBytes: 1_048_576
            )
            throw error
        }
    }

    private func undo(_ change: AgentDefinitionChangePreview) throws {
        try validate(change)
        guard let authorizedURL = change.authorizedDirectoryURL?.standardizedFileURL,
              let expected = change.expectedSourceContents else {
            throw AgentRestructureError.recoveryConflict(change.archiveURL)
        }
        let authorized = try AnchoredDirectory.openAbsolute(authorizedURL)
        let sourceName = change.sourceURL.lastPathComponent
        let targetName = change.targetURL.lastPathComponent
        let archiveName = change.archiveURL.lastPathComponent
        let archiveComponents = try relativePathComponents(
            change.archiveURL.deletingLastPathComponent(),
            inside: authorizedURL
        )
        let archive = try authorized.descendant(archiveComponents, create: false)
        let expectedData = Data(expected.utf8)
        guard try archive.read(archiveName, maximumBytes: 1_048_576) == expectedData else {
            throw AgentRestructureError.recoveryConflict(change.archiveURL)
        }
        if change.sourceURL.standardizedFileURL != change.targetURL.standardizedFileURL,
           try authorized.contains(sourceName) {
            throw AgentRestructureError.recoveryConflict(change.sourceURL)
        }
        if try authorized.contains(targetName) {
            try authorized.remove(
                targetName,
                expectedContents: Data(change.proposedContents.utf8),
                maximumBytes: 1_048_576
            )
        }
        try archive.move(
            archiveName,
            to: authorized,
            as: sourceName,
            expectedContents: expectedData,
            maximumBytes: 1_048_576
        )
    }

    private func validate(_ change: AgentDefinitionChangePreview) throws {
        guard let authorized = change.authorizedDirectoryURL?.resolvingSymlinksInPath().standardizedFileURL,
              normalizedPath(authorized) == change.authorizedDirectoryURL.map(normalizedPath),
              !isSymbolicLink(authorized),
              normalizedPath(change.sourceURL.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()) == normalizedPath(authorized),
              normalizedPath(change.targetURL.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()) == normalizedPath(authorized),
              isDescendant(change.archiveURL.resolvingSymlinksInPath().standardizedFileURL, of: authorized),
              !containsSymlink(from: authorized, through: change.archiveURL.deletingLastPathComponent()) else {
            throw AgentRestructureError.unsafePath(change.sourceURL)
        }
        if fileManager.fileExists(atPath: change.sourceURL.path(percentEncoded: false)),
           !isSafeRegularFile(change.sourceURL) {
            throw AgentRestructureError.unsafePath(change.sourceURL)
        }
        if fileManager.fileExists(atPath: change.targetURL.path(percentEncoded: false)),
           !isSafeRegularFile(change.targetURL) {
            throw AgentRestructureError.unsafePath(change.targetURL)
        }
    }

    private func containsSymlink(from root: URL, through target: URL) -> Bool {
        let rootPath = normalizedPath(root)
        let targetPath = normalizedPath(target)
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else { return true }
        var current = root.standardizedFileURL
        for component in targetPath.dropFirst(rootPath.count).split(separator: "/") {
            current.append(path: String(component))
            if fileManager.fileExists(atPath: current.path(percentEncoded: false)), isSymbolicLink(current) {
                return true
            }
        }
        return false
    }

    private func boundedString(contentsOf url: URL) -> String? {
        let maximumBytes = 1_048_576
        guard isSafeRegularFile(url),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: maximumBytes + 1),
              bytes.count <= maximumBytes else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    private func isSafeRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? 1_048_577) <= 1_048_576
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = normalizedPath(root)
        let candidatePath = normalizedPath(candidate)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func slug(_ value: String) -> String {
        let words = value.lowercased().split { !$0.isLetter && !$0.isNumber }
        let result = words.joined(separator: "-")
        return result.isEmpty ? "goby-agent" : String(result.prefix(64))
    }
}
