import Darwin
import Foundation
import GobyApplication
import GobyDomain

public actor LocalProjectDirectoryCreator: ProjectDirectoryCreating {
    private let cloneTimeout: TimeInterval
    private let maximumCloneBytes: Int64
    private let maximumCloneEntries: Int
    private let gitHubCredentialHelperURL: URL?

    public init(
        cloneTimeout: TimeInterval = 15 * 60,
        maximumCloneBytes: Int64 = 8 * 1_024 * 1_024 * 1_024,
        maximumCloneEntries: Int = 250_000,
        gitHubCredentialHelperURL: URL? = nil
    ) {
        self.cloneTimeout = max(1, cloneTimeout)
        self.maximumCloneBytes = max(1, maximumCloneBytes)
        self.maximumCloneEntries = max(1, maximumCloneEntries)
        self.gitHubCredentialHelperURL = gitHubCredentialHelperURL
            ?? InstalledGitHubCLICredentialHelperLocator.locate()
    }

    public func createProjectDirectory(
        named directoryName: String,
        in parentURL: URL,
        expectedParentIdentity: GADFileSystemIdentity
    ) throws -> ProjectDirectoryPlacement {
        let (cleanName, root, parent) = try availableProjectRoot(
            named: directoryName,
            in: parentURL,
            expectedParentIdentity: expectedParentIdentity
        )
        guard mkdirat(parent.descriptor, cleanName, 0o700) == 0 else {
            if errno == EEXIST { throw GobyApplicationError.projectDirectoryAlreadyExists(cleanName) }
            throw CocoaError(.fileWriteUnknown)
        }
        let child = openat(parent.descriptor, cleanName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
            let failure = errno
            _ = unlinkat(parent.descriptor, cleanName, AT_REMOVEDIR)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        guard let childIdentity = GADFileSystemIdentity.capture(fileDescriptor: child),
              childIdentity.kind == .directory else {
            close(child)
            _ = unlinkat(parent.descriptor, cleanName, AT_REMOVEDIR)
            throw GobyApplicationError.projectDirectoryAuthorizationChanged
        }
        close(child)
        let placement = ProjectDirectoryPlacement(rootURL: root, fileSystemIdentity: childIdentity)
        guard expectedParentIdentity.matchesCurrentObject(at: parentURL),
              placement.matchesCurrentObject() else {
            _ = unlinkat(parent.descriptor, cleanName, AT_REMOVEDIR)
            throw GobyApplicationError.projectParentAuthorizationChanged
        }
        return placement
    }

    public func cloneProjectRepository(
        from repository: String,
        named directoryName: String,
        in parentURL: URL,
        expectedParentIdentity: GADFileSystemIdentity
    ) throws -> ProjectDirectoryPlacement {
        let source = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidRepositorySource(source) else {
            throw GobyApplicationError.invalidGitRepositorySource
        }
        let (cleanName, root, parent) = try availableProjectRoot(
            named: directoryName,
            in: parentURL,
            expectedParentIdentity: expectedParentIdentity
        )
        let stagingParent = FileManager.default.temporaryDirectory
            .appending(path: "goby-project-clone-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: stagingParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: stagingParent) }
        let stagedRoot = stagingParent.appending(path: cleanName, directoryHint: .isDirectory)

        do {
            let credentialHelperURL = Self.isGitHubHTTPSRepository(source)
                ? gitHubCredentialHelperURL
                : nil
            let result = try HardenedGitProcess.run(
                arguments: ["clone", "--", source, stagedRoot.path(percentEncoded: false)],
                currentDirectory: stagingParent,
                timeout: cloneTimeout,
                maximumOutputBytes: 1_048_576,
                directoryBudget: HardenedGitProcess.DirectoryBudget(
                    rootURL: stagingParent,
                    maximumBytes: maximumCloneBytes,
                    maximumEntries: maximumCloneEntries
                ),
                preflightRepository: false,
                credentialHelperURL: credentialHelperURL
            )
            guard result.status == 0 else {
                throw GobyApplicationError.gitCloneFailed(Self.cloneFailureMessage(
                    result.output,
                    source: source,
                    stagingParent: stagingParent,
                    usedGitHubCredentialHelper: credentialHelperURL != nil
                ))
            }
            try HardenedGitProcess.validateRepositoryIdentity(in: stagedRoot)
        } catch let failure as GobyApplicationError {
            throw failure
        } catch {
            throw GobyApplicationError.gitCloneFailed(Self.cloneFailureMessage(
                error.localizedDescription,
                source: source,
                stagingParent: stagingParent,
                usedGitHubCredentialHelper: Self.isGitHubHTTPSRepository(source)
                    && gitHubCredentialHelperURL != nil
            ))
        }

        let stagedParent = try AnchoredDirectory.openAbsolute(stagingParent)
        guard try stagedParent.contains(cleanName),
              matches(expectedParentIdentity, descriptor: parent.descriptor) else {
            throw GobyApplicationError.projectParentAuthorizationChanged
        }
        guard renameatx_np(
            stagedParent.descriptor,
            cleanName,
            parent.descriptor,
            cleanName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            switch errno {
            case EEXIST:
                throw GobyApplicationError.projectDirectoryAlreadyExists(cleanName)
            case EXDEV:
                throw GobyApplicationError.gitCloneFailed(
                    "The selected parent folder is on a different volume from Goby's protected staging area. Choose a folder on the startup volume for this beta."
                )
            default:
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let child = openat(parent.descriptor, cleanName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0,
              let childIdentity = GADFileSystemIdentity.capture(fileDescriptor: child),
              childIdentity.kind == .directory else {
            if child >= 0 { close(child) }
            throw GobyApplicationError.projectDirectoryAuthorizationChanged
        }
        close(child)
        let placement = ProjectDirectoryPlacement(rootURL: root, fileSystemIdentity: childIdentity)
        guard expectedParentIdentity.matchesCurrentObject(at: parentURL),
              placement.matchesCurrentObject() else {
            throw GobyApplicationError.projectParentAuthorizationChanged
        }
        return placement
    }

    public func removeProjectDirectoryIfEmpty(_ placement: ProjectDirectoryPlacement) throws {
        let root = placement.rootURL.standardizedFileURL
        let parentURL = root.deletingLastPathComponent()
        let rootName = root.lastPathComponent
        guard !rootName.isEmpty else {
            throw GobyApplicationError.projectDirectoryAuthorizationChanged
        }
        let parent = try AnchoredDirectory.openAbsolute(parentURL)
        guard let rootDescriptor = try openDirectory(named: rootName, relativeTo: parent.descriptor) else {
            throw GobyApplicationError.projectDirectoryAuthorizationChanged
        }
        defer { close(rootDescriptor) }
        guard placement.fileSystemIdentity.matches(fileDescriptor: rootDescriptor),
              placement.matchesCurrentObject() else {
            throw GobyApplicationError.projectDirectoryAuthorizationChanged
        }

        if let codexDescriptor = try openDirectory(named: ".codex", relativeTo: rootDescriptor) {
            defer { close(codexDescriptor) }
            try removeEmptyDirectory(named: "agents", relativeTo: codexDescriptor)
        }
        try removeEmptyDirectory(named: ".codex", relativeTo: rootDescriptor)

        guard placement.fileSystemIdentity.matches(fileDescriptor: rootDescriptor),
              placement.matchesCurrentObject(),
              matchesAtParent(
                placement.fileSystemIdentity,
                name: rootName,
                parentDescriptor: parent.descriptor
              ) else {
            throw GobyApplicationError.projectDirectoryAuthorizationChanged
        }
        try removeEmptyDirectory(named: rootName, relativeTo: parent.descriptor)
    }

    private func openDirectory(named name: String, relativeTo parentDescriptor: Int32) throws -> Int32? {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor >= 0 { return descriptor }
        switch errno {
        case ENOENT, ENOTDIR, ELOOP:
            return nil
        default:
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func removeEmptyDirectory(named name: String, relativeTo parentDescriptor: Int32) throws {
        guard unlinkat(parentDescriptor, name, AT_REMOVEDIR) != 0 else { return }
        switch errno {
        case ENOENT, ENOTEMPTY, EEXIST, ENOTDIR, ELOOP:
            return
        default:
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func matchesAtParent(
        _ identity: GADFileSystemIdentity,
        name: String,
        parentDescriptor: Int32
    ) -> Bool {
        var info = stat()
        return fstatat(parentDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            && info.st_mode & S_IFMT == S_IFDIR
            && UInt64(info.st_dev) == identity.device
            && UInt64(info.st_ino) == identity.inode
            && identity.kind == .directory
    }

    private func availableProjectRoot(
        named directoryName: String,
        in parentURL: URL,
        expectedParentIdentity: GADFileSystemIdentity
    ) throws -> (String, URL, AnchoredDirectory) {
        let cleanName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidDirectoryName(cleanName) else {
            throw GobyApplicationError.invalidProjectDirectoryName
        }

        let parent = parentURL.standardizedFileURL
        let anchoredParent = try AnchoredDirectory.openAbsolute(parent)
        guard matches(expectedParentIdentity, descriptor: anchoredParent.descriptor),
              expectedParentIdentity.matchesCurrentObject(at: parent) else {
            throw GobyApplicationError.projectParentAuthorizationChanged
        }

        let root = parent.appending(path: cleanName, directoryHint: .isDirectory).standardizedFileURL
        guard root.deletingLastPathComponent() == parent else {
            throw GobyApplicationError.invalidProjectDirectoryName
        }
        guard try !anchoredParent.contains(cleanName) else {
            throw GobyApplicationError.projectDirectoryAlreadyExists(cleanName)
        }
        return (cleanName, root, anchoredParent)
    }

    private func matches(_ identity: GADFileSystemIdentity, descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0
            && info.st_mode & S_IFMT == S_IFDIR
            && UInt64(info.st_dev) == identity.device
            && UInt64(info.st_ino) == identity.inode
            && identity.kind == .directory
    }

    private func isValidRepositorySource(_ source: String) -> Bool {
        guard !source.isEmpty,
              !source.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        if let components = URLComponents(string: source),
           components.scheme != nil,
           components.user != nil || components.password != nil {
            return false
        }
        return source.contains("://")
            || source.hasPrefix("git@")
            || source.hasPrefix("ssh://")
            || source.hasPrefix("file://")
            || source.hasPrefix("/")
    }

    static func isGitHubHTTPSRepository(_ source: String) -> Bool {
        guard let components = URLComponents(string: source),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.user == nil,
              components.password == nil else { return false }
        return true
    }

    static func cloneFailureMessage(
        _ rawMessage: String,
        source: String,
        stagingParent: URL,
        usedGitHubCredentialHelper: Bool
    ) -> String {
        var message = rawMessage
            .replacingOccurrences(of: source, with: "the selected repository")
            .replacingOccurrences(
                of: stagingParent.path(percentEncoded: false),
                with: "Goby's protected staging folder"
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while message.hasPrefix("Git could not clone the repository. ") {
            message.removeFirst("Git could not clone the repository. ".count)
        }
        let lowercased = message.lowercased()
        let authenticationFailed = [
            "could not read username",
            "authentication failed",
            "repository not found",
            "not logged into any github hosts",
            "gh auth login",
        ].contains(where: lowercased.contains)
        if authenticationFailed {
            if usedGitHubCredentialHelper {
                return "GitHub denied access to this repository. Confirm that the active GitHub CLI account can access it, then retry. You can also clone it separately and choose Add Existing Project."
            }
            return "This private GitHub repository needs an authenticated GitHub CLI installation. Sign in with `gh auth login`, then retry, or clone it separately and choose Add Existing Project."
        }
        if message.isEmpty {
            message = "Check the repository address, access, and network connection, then try again."
        }
        return String(message.prefix(1_000))
    }

    private func isValidDirectoryName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains(":")
            && !name.contains("\0")
    }
}
