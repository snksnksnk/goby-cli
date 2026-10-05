import Darwin
import Foundation
import GobyApplication
import GobyDomain

public enum CodexAgentDefinitionError: LocalizedError, Sendable {
    case duplicateName(String)
    case targetExists(URL)
    case missingSource(URL)
    case changedSource(URL)
    case incompleteReview(URL)
    case unsafePath(URL)

    public var errorDescription: String? {
        switch self {
        case let .duplicateName(name):
            "Codex already has an agent named \(name) in this scope. Choose a different name."
        case let .targetExists(url):
            "An agent definition already exists at \(url.path(percentEncoded: false)). Goby did not overwrite it."
        case let .missingSource(url):
            "The Codex agent definition is missing at \(url.path(percentEncoded: false)). Refresh agents before trying again."
        case let .changedSource(url):
            "The Codex agent definition changed at \(url.path(percentEncoded: false)). Goby stopped to avoid overwriting newer work."
        case let .incompleteReview(url):
            "The complete Codex agent definition was not reviewed at \(url.path(percentEncoded: false)). Review the complete local file before activating it."
        case let .unsafePath(url):
            "The agent definition path is not safe to modify: \(url.path(percentEncoded: false))."
        }
    }
}

enum CodexAgentIdentity {
    static func id(for sourceURL: URL) -> AgentID {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in sourceURL.standardizedFileURL.path(percentEncoded: false).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return AgentID(rawValue: "agent-\(String(hash, radix: 16))")
    }
}

public actor CodexAgentDefinitionStore: CodexAgentDefinitionManaging {
    private static let maximumDefinitionBytes = 1_048_576
    private static let maximumConfigurationBytes = 4_194_304
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600

    private let globalAgentsURL: URL
    private let fileManager: FileManager

    public init(
        globalAgentsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/agents"),
        fileManager: FileManager = .default
    ) {
        self.globalAgentsURL = globalAgentsURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public func createDefinition(
        from draft: AgentDefinitionDraft,
        projectRootURL: URL?,
        expectedProjectIdentity: GADFileSystemIdentity?
    ) throws -> AgentProfile {
        let directory = try definitionDirectory(for: draft.scope, projectRootURL: projectRootURL)
        let anchoredDirectory = try prepareDefinitionDirectory(
            directory,
            projectRootURL: projectRootURL,
            expectedProjectIdentity: expectedProjectIdentity
        )
        try prepareGlobalConfigurationDirectory()
        try rejectDuplicateName(draft.name, in: directory)

        let target = directory.appending(path: "\(slug(draft.name)).toml").standardizedFileURL
        let configurationURL = registrationConfigurationURL()
        let key = registrationKey(for: draft.name, scope: draft.scope, source: target)
        guard normalizedPath(target.deletingLastPathComponent()) == normalizedPath(directory),
              !fileManager.fileExists(atPath: target.path(percentEncoded: false)),
              !isSymbolicLink(target) else {
            throw CodexAgentDefinitionError.targetExists(target)
        }

        let configuration = try configurationContents(at: configurationURL)
        try rejectRegistrationConflict(
            key: key,
            source: target,
            configuration: configuration,
            configurationURL: configurationURL
        )

        let contents = definitionContents(for: draft)
        guard contents.utf8.count <= Self.maximumDefinitionBytes else {
            throw CodexAgentDefinitionError.unsafePath(target)
        }

        var createdDefinition = false
        do {
            try anchoredDirectory.create(
                target.lastPathComponent,
                contents: Data(contents.utf8),
                permissions: mode_t(Self.filePermissions)
            )
            createdDefinition = true
            try validateExpectedProjectIdentity(
                expectedProjectIdentity,
                at: projectRootURL
            )
            let registration = registrationBlock(key: key, summary: draft.summary, source: target)
            try replaceConfiguration(
                appendingRegistration(registration, to: configuration),
                at: configurationURL,
                expectedCurrent: configuration
            )
        } catch {
            if createdDefinition {
                try? anchoredDirectory.remove(
                    target.lastPathComponent,
                    expectedContents: Data(contents.utf8),
                    maximumBytes: Self.maximumDefinitionBytes
                )
            }
            throw error
        }

        return AgentProfile(
            id: CodexAgentIdentity.id(for: target),
            name: draft.name,
            summary: draft.summary,
            instructions: draft.instructions,
            capabilities: draft.capabilities,
            scope: draft.scope,
            sourceURL: target,
            toolPreset: draft.toolPreset,
            reviewedDefinitionDigest: DefinitionReviewDigest.sha256(contents),
            definitionReviewProvenance: .gobyGenerated,
            codexRegistrationKey: key
        )
    }

    public func activateDefinition(
        for agent: AgentProfile,
        projectRootURL: URL?
    ) throws -> AgentDefinitionActivationResult {
        guard let source = agent.sourceURL?.standardizedFileURL,
              source.lastPathComponent.hasSuffix(".toml"),
              isSafeRegularFile(source, maximumBytes: Self.maximumDefinitionBytes) else {
            throw CodexAgentDefinitionError.unsafePath(agent.sourceURL ?? globalAgentsURL)
        }
        let directory = try definitionDirectory(for: agent.scope, projectRootURL: projectRootURL)
        guard normalizedPath(source.deletingLastPathComponent()) == normalizedPath(directory),
              !containsSymlink(from: definitionBase(for: directory), through: source) else {
            throw CodexAgentDefinitionError.unsafePath(source)
        }
        let anchoredDirectory: AnchoredDirectory
        do {
            anchoredDirectory = try AnchoredDirectory.openAbsolute(directory)
        } catch {
            throw CodexAgentDefinitionError.unsafePath(source)
        }
        try requireReviewedDefinition(agent, named: source.lastPathComponent, in: anchoredDirectory, sourceURL: source)

        try prepareGlobalConfigurationDirectory()
        let configurationURL = registrationConfigurationURL()
        let configuration = try configurationContents(at: configurationURL)
        if let existing = try registrationTargeting(
            source,
            in: configuration,
            configurationURL: configurationURL
        ) {
            return AgentDefinitionActivationResult(
                agent: profile(agent, registrationKey: existing.key),
                createdRegistration: false
            )
        }

        let key = registrationKey(for: agent.name, scope: agent.scope, source: source)
        try rejectRegistrationConflict(
            key: key,
            source: source,
            configuration: configuration,
            configurationURL: configurationURL
        )
        let registration = registrationBlock(key: key, summary: agent.summary, source: source)
        try replaceConfiguration(
            appendingRegistration(registration, to: configuration),
            at: configurationURL,
            expectedCurrent: configuration
        )
        return AgentDefinitionActivationResult(
            agent: profile(agent, registrationKey: key),
            createdRegistration: true
        )
    }

    public func undoActivatedDefinition(_ agent: AgentProfile) throws {
        guard let source = agent.sourceURL?.standardizedFileURL,
              let key = agent.codexRegistrationKey,
              source.lastPathComponent.hasSuffix(".toml"),
              isSafeRegularFile(source, maximumBytes: Self.maximumDefinitionBytes) else {
            throw CodexAgentDefinitionError.unsafePath(agent.sourceURL ?? globalAgentsURL)
        }
        try prepareGlobalConfigurationDirectory()
        let configurationURL = registrationConfigurationURL()
        let configuration = try configurationContents(at: configurationURL)
        let expectedBlock = registrationBlock(key: key, summary: agent.summary, source: source)
        let section = try exactRegistration(
            key: key,
            source: source,
            expectedBlock: expectedBlock,
            configuration: configuration,
            configurationURL: configurationURL
        )
        try replaceConfiguration(
            removing(section: section, from: configuration),
            at: configurationURL,
            expectedCurrent: configuration
        )
    }

    public func undoCreatedDefinition(
        _ agent: AgentProfile,
        expectedProjectIdentity: GADFileSystemIdentity?
    ) throws {
        guard let source = agent.sourceURL?.standardizedFileURL,
              source.lastPathComponent.hasSuffix(".toml"),
              source.deletingLastPathComponent().lastPathComponent == "agents",
              isSafeRegularFile(source, maximumBytes: Self.maximumDefinitionBytes) else {
            throw CodexAgentDefinitionError.unsafePath(agent.sourceURL ?? globalAgentsURL)
        }
        let anchoredDirectory: AnchoredDirectory
        if let expectedProjectIdentity {
            let projectRoot = source
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let anchoredRoot = try AnchoredDirectory.openAbsolute(projectRoot)
            guard expectedProjectIdentity.matches(fileDescriptor: anchoredRoot.descriptor),
                  expectedProjectIdentity.matchesCurrentObject(at: projectRoot) else {
                throw CodexAgentDefinitionError.unsafePath(projectRoot)
            }
            anchoredDirectory = try anchoredRoot.descendant(
                [".codex", "agents"],
                create: false,
                permissions: mode_t(Self.directoryPermissions)
            )
        } else {
            anchoredDirectory = try AnchoredDirectory.openAbsolute(source.deletingLastPathComponent())
        }
        let draft = AgentDefinitionDraft(
            name: agent.name,
            summary: agent.summary,
            instructions: agent.instructions ?? agent.summary,
            capabilities: agent.capabilities,
            scope: agent.scope,
            toolPreset: agent.toolPreset
        )
        guard boundedString(contentsOf: source, maximumBytes: Self.maximumDefinitionBytes) == definitionContents(for: draft) else {
            throw CodexAgentDefinitionError.changedSource(source)
        }

        try prepareGlobalConfigurationDirectory()
        let configurationURL = registrationConfigurationURL()
        let configuration = try configurationContents(at: configurationURL)
        let key = registrationKey(for: agent.name, scope: agent.scope, source: source)
        let expectedBlock = registrationBlock(key: key, summary: agent.summary, source: source)
        let section = try exactRegistration(
            key: key,
            source: source,
            expectedBlock: expectedBlock,
            configuration: configuration,
            configurationURL: configurationURL
        )
        let updatedConfiguration = removing(section: section, from: configuration)
        if let expectedProjectIdentity {
            let projectRoot = source
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            try validateExpectedProjectIdentity(expectedProjectIdentity, at: projectRoot)
        }
        try replaceConfiguration(
            updatedConfiguration,
            at: configurationURL,
            expectedCurrent: configuration
        )
        do {
            try anchoredDirectory.remove(
                source.lastPathComponent,
                expectedContents: Data(definitionContents(for: draft).utf8),
                maximumBytes: Self.maximumDefinitionBytes
            )
        } catch {
            try? restoreConfiguration(
                configuration,
                replacing: updatedConfiguration,
                at: configurationURL
            )
            throw error
        }
    }

    public func archiveDefinition(
        for agent: AgentProfile,
        projectRootURL: URL?
    ) throws -> DeletedAgentRecord {
        guard let originalSource = agent.sourceURL else {
            return DeletedAgentRecord(agent: agent)
        }
        let directory = try definitionDirectory(for: agent.scope, projectRootURL: projectRootURL)
        let source = originalSource.standardizedFileURL
        guard normalizedPath(source.deletingLastPathComponent()) == normalizedPath(directory),
              isSafeRegularFile(source, maximumBytes: Self.maximumDefinitionBytes),
              let contents = boundedString(contentsOf: source, maximumBytes: Self.maximumDefinitionBytes) else {
            if !fileManager.fileExists(atPath: source.path(percentEncoded: false)) {
                throw CodexAgentDefinitionError.missingSource(source)
            }
            throw CodexAgentDefinitionError.unsafePath(source)
        }

        try prepareGlobalConfigurationDirectory()
        let configurationURL = registrationConfigurationURL()
        let configuration = try configurationContents(at: configurationURL)
        let registration = try registrationTargeting(
            source,
            in: configuration,
            configurationURL: configurationURL
        )
        let updatedConfiguration = registration.map { removing(section: $0, from: configuration) }

        let batch = archiveBatchName()
        let archive = directory
            .appending(path: ".goby-archive", directoryHint: .isDirectory)
            .appending(path: "deleted", directoryHint: .isDirectory)
            .appending(path: batch, directoryHint: .isDirectory)
            .appending(path: source.lastPathComponent)
            .standardizedFileURL
        try prepareArchiveDirectory(archive.deletingLastPathComponent(), inside: directory)
        guard !fileManager.fileExists(atPath: archive.path(percentEncoded: false)),
              !isSymbolicLink(archive) else {
            throw CodexAgentDefinitionError.targetExists(archive)
        }

        let anchoredDirectory = try AnchoredDirectory.openAbsolute(directory)
        let archiveComponents = try relativePathComponents(
            archive.deletingLastPathComponent(),
            inside: directory
        )
        let anchoredArchive = try anchoredDirectory.descendant(
            archiveComponents,
            create: false,
            permissions: mode_t(Self.directoryPermissions)
        )
        try anchoredDirectory.move(
            source.lastPathComponent,
            to: anchoredArchive,
            as: archive.lastPathComponent,
            expectedContents: Data(contents.utf8),
            maximumBytes: Self.maximumDefinitionBytes
        )
        do {
            if let updatedConfiguration {
                try replaceConfiguration(
                    updatedConfiguration,
                    at: configurationURL,
                    expectedCurrent: configuration
                )
            }
        } catch {
            try? anchoredArchive.move(
                archive.lastPathComponent,
                to: anchoredDirectory,
                as: source.lastPathComponent,
                expectedContents: Data(contents.utf8),
                maximumBytes: Self.maximumDefinitionBytes
            )
            throw error
        }

        return DeletedAgentRecord(
            agent: profile(agent, registrationKey: registration?.key),
            sourceURL: source,
            archiveURL: archive,
            expectedContents: contents,
            registrationURL: registration == nil ? nil : configurationURL,
            registrationKey: registration?.key,
            registrationBlock: registration?.block
        )
    }

    public func restoreDefinition(from record: DeletedAgentRecord) throws {
        guard let source = record.sourceURL?.standardizedFileURL,
              let archive = record.archiveURL?.standardizedFileURL,
              let expectedContents = record.expectedContents else {
            return
        }
        guard record.agent.definitionReviewProvenance == .fullContent
                || record.agent.definitionReviewProvenance == .gobyGenerated else {
            throw CodexAgentDefinitionError.incompleteReview(source)
        }
        guard let reviewedDigest = record.agent.reviewedDefinitionDigest,
              reviewedDigest.count == 64,
              reviewedDigest.allSatisfy({ $0.isHexDigit }),
              DefinitionReviewDigest.sha256(expectedContents) == reviewedDigest else {
            throw CodexAgentDefinitionError.changedSource(source)
        }
        let directory = source.deletingLastPathComponent().standardizedFileURL
        let requiredArchiveRoot = directory
            .appending(path: ".goby-archive", directoryHint: .isDirectory)
            .appending(path: "deleted", directoryHint: .isDirectory)
            .standardizedFileURL
        guard directory.lastPathComponent == "agents",
              isDescendant(archive, of: requiredArchiveRoot),
              !containsSymlink(from: directory, through: archive.deletingLastPathComponent()),
              !fileManager.fileExists(atPath: source.path(percentEncoded: false)),
              !isSymbolicLink(source),
              isSafeRegularFile(archive, maximumBytes: Self.maximumDefinitionBytes),
              boundedString(contentsOf: archive, maximumBytes: Self.maximumDefinitionBytes) == expectedContents else {
            throw CodexAgentDefinitionError.changedSource(source)
        }

        let registration = try registrationDetails(from: record, source: source, directory: directory)
        try prepareGlobalConfigurationDirectory()
        let configurationURL = registrationConfigurationURL()
        let configuration = try configurationContents(at: configurationURL)
        if let registration {
            try rejectRegistrationConflict(
                key: registration.key,
                source: source,
                configuration: configuration,
                configurationURL: configurationURL
            )
        }

        let anchoredDirectory = try AnchoredDirectory.openAbsolute(directory)
        let archiveComponents = try relativePathComponents(
            archive.deletingLastPathComponent(),
            inside: directory
        )
        let anchoredArchive = try anchoredDirectory.descendant(archiveComponents, create: false)
        try anchoredArchive.move(
            archive.lastPathComponent,
            to: anchoredDirectory,
            as: source.lastPathComponent,
            expectedContents: Data(expectedContents.utf8),
            maximumBytes: Self.maximumDefinitionBytes
        )
        do {
            if let registration {
                try replaceConfiguration(
                    appendingRegistration(registration.block, to: configuration),
                    at: configurationURL,
                    expectedCurrent: configuration
                )
            }
        } catch {
            try? anchoredDirectory.move(
                source.lastPathComponent,
                to: anchoredArchive,
                as: archive.lastPathComponent,
                expectedContents: Data(expectedContents.utf8),
                maximumBytes: Self.maximumDefinitionBytes
            )
            throw error
        }
    }

    public func undoRestoredDefinition(from record: DeletedAgentRecord) throws {
        guard let source = record.sourceURL?.standardizedFileURL,
              let archive = record.archiveURL?.standardizedFileURL,
              let expectedContents = record.expectedContents else {
            return
        }
        let directory = source.deletingLastPathComponent().standardizedFileURL
        let requiredArchiveRoot = directory
            .appending(path: ".goby-archive", directoryHint: .isDirectory)
            .appending(path: "deleted", directoryHint: .isDirectory)
            .standardizedFileURL
        guard directory.lastPathComponent == "agents",
              isDescendant(archive, of: requiredArchiveRoot),
              !containsSymlink(from: directory, through: archive.deletingLastPathComponent()),
              !fileManager.fileExists(atPath: archive.path(percentEncoded: false)),
              isSafeRegularFile(source, maximumBytes: Self.maximumDefinitionBytes),
              boundedString(contentsOf: source, maximumBytes: Self.maximumDefinitionBytes) == expectedContents else {
            throw CodexAgentDefinitionError.changedSource(source)
        }

        let registration = try registrationDetails(from: record, source: source, directory: directory)
        try prepareGlobalConfigurationDirectory()
        let configurationURL = registrationConfigurationURL()
        let configuration = try configurationContents(at: configurationURL)
        let updatedConfiguration: String?
        if let registration {
            let section = try exactRegistration(
                key: registration.key,
                source: source,
                expectedBlock: registration.block,
                configuration: configuration,
                configurationURL: configurationURL
            )
            updatedConfiguration = removing(section: section, from: configuration)
        } else {
            updatedConfiguration = nil
        }

        let anchoredDirectory = try AnchoredDirectory.openAbsolute(directory)
        let archiveComponents = try relativePathComponents(
            archive.deletingLastPathComponent(),
            inside: directory
        )
        let anchoredArchive = try anchoredDirectory.descendant(
            archiveComponents,
            create: true,
            permissions: mode_t(Self.directoryPermissions)
        )
        try anchoredDirectory.move(
            source.lastPathComponent,
            to: anchoredArchive,
            as: archive.lastPathComponent,
            expectedContents: Data(expectedContents.utf8),
            maximumBytes: Self.maximumDefinitionBytes
        )
        do {
            if let updatedConfiguration {
                try replaceConfiguration(
                    updatedConfiguration,
                    at: configurationURL,
                    expectedCurrent: configuration
                )
            }
        } catch {
            try? anchoredArchive.move(
                archive.lastPathComponent,
                to: anchoredDirectory,
                as: source.lastPathComponent,
                expectedContents: Data(expectedContents.utf8),
                maximumBytes: Self.maximumDefinitionBytes
            )
            throw error
        }
    }

    private struct RegistrationSection {
        let key: String
        let range: Range<String.Index>
        let block: String
        let configFile: String?
    }

    private struct RegistrationDetails {
        let key: String
        let block: String
    }

    private struct TableHeader {
        let start: String.Index
        let agentKey: String?
    }

    private func profile(_ agent: AgentProfile, registrationKey: String?) -> AgentProfile {
        AgentProfile(
            id: agent.id,
            name: agent.name,
            summary: agent.summary,
            instructions: agent.instructions,
            capabilities: agent.capabilities,
            scope: agent.scope,
            sourceURL: agent.sourceURL,
            toolPreset: agent.toolPreset,
            reviewedDefinitionDigest: agent.reviewedDefinitionDigest,
            definitionReviewProvenance: agent.definitionReviewProvenance,
            codexRegistrationKey: registrationKey,
            isEnabled: agent.isEnabled
        )
    }

    private func definitionDirectory(for scope: AgentScope, projectRootURL: URL?) throws -> URL {
        switch scope {
        case .global, .union:
            return globalAgentsURL
        case .project:
            guard let projectRootURL else {
                throw CodexAgentDefinitionError.unsafePath(URL(fileURLWithPath: "/", isDirectory: true))
            }
            let root = projectRootURL.standardizedFileURL
            _ = try AnchoredDirectory.openAbsolute(root)
            return root
                .appending(path: ".codex", directoryHint: .isDirectory)
                .appending(path: "agents", directoryHint: .isDirectory)
                .standardizedFileURL
        }
    }

    private func registrationConfigurationURL() -> URL {
        globalAgentsURL
            .deletingLastPathComponent()
            .appending(path: "config.toml")
            .standardizedFileURL
    }

    private func prepareDefinitionDirectory(
        _ directory: URL,
        projectRootURL: URL?,
        expectedProjectIdentity: GADFileSystemIdentity?
    ) throws -> AnchoredDirectory {
        if let expectedProjectIdentity {
            guard let projectRootURL else {
                throw CodexAgentDefinitionError.unsafePath(directory)
            }
            let root = projectRootURL.standardizedFileURL
            let anchoredRoot = try AnchoredDirectory.openAbsolute(root)
            guard expectedProjectIdentity.matches(fileDescriptor: anchoredRoot.descriptor),
                  expectedProjectIdentity.matchesCurrentObject(at: root) else {
                throw CodexAgentDefinitionError.unsafePath(root)
            }
            let components = try relativePathComponents(directory, inside: root)
            let anchoredDirectory = try anchoredRoot.descendant(
                components,
                create: true,
                permissions: mode_t(Self.directoryPermissions)
            )
            try anchoredDirectory.setPermissions(mode_t(Self.directoryPermissions))
            return anchoredDirectory
        }
        let base = definitionBase(for: directory)
        guard isDescendant(directory, of: base),
              !containsSymlink(from: base, through: directory) else {
            throw CodexAgentDefinitionError.unsafePath(directory)
        }
        let mayCreateBase = normalizedPath(directory) == normalizedPath(globalAgentsURL)
            && !isDescendant(directory, of: fileManager.homeDirectoryForCurrentUser)
        let anchoredBase = try AnchoredDirectory.openAbsolute(
            base,
            createIfMissing: mayCreateBase,
            permissions: mode_t(Self.directoryPermissions)
        )
        let components = normalizedPath(directory) == normalizedPath(base)
            ? []
            : try relativePathComponents(directory, inside: base)
        let anchoredDirectory = try anchoredBase.descendant(
            components,
            create: true,
            permissions: mode_t(Self.directoryPermissions)
        )
        try anchoredDirectory.setPermissions(mode_t(Self.directoryPermissions))
        return anchoredDirectory
    }

    private func validateExpectedProjectIdentity(
        _ expectedProjectIdentity: GADFileSystemIdentity?,
        at projectRootURL: URL?
    ) throws {
        guard let expectedProjectIdentity else { return }
        guard let projectRootURL,
              expectedProjectIdentity.matchesCurrentObject(at: projectRootURL.standardizedFileURL) else {
            throw CodexAgentDefinitionError.unsafePath(
                projectRootURL ?? URL(fileURLWithPath: "/", isDirectory: true)
            )
        }
    }

    private func prepareGlobalConfigurationDirectory() throws {
        let directory = globalAgentsURL.deletingLastPathComponent().standardizedFileURL
        let base: URL
        let home = fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        if isDescendant(directory, of: home) {
            base = home
        } else {
            base = directory
        }
        guard !containsSymlink(from: base, through: directory),
              !isSymbolicLink(directory) else {
            throw CodexAgentDefinitionError.unsafePath(directory)
        }
        let anchoredBase = try AnchoredDirectory.openAbsolute(
            base,
            createIfMissing: !isDescendant(directory, of: home),
            permissions: mode_t(Self.directoryPermissions)
        )
        let components = normalizedPath(directory) == normalizedPath(base)
            ? []
            : try relativePathComponents(directory, inside: base)
        let anchoredDirectory = try anchoredBase.descendant(
            components,
            create: true,
            permissions: mode_t(Self.directoryPermissions)
        )
        try anchoredDirectory.setPermissions(mode_t(Self.directoryPermissions))
    }

    private func prepareArchiveDirectory(_ archiveDirectory: URL, inside definitionDirectory: URL) throws {
        guard isDescendant(archiveDirectory, of: definitionDirectory),
              !containsSymlink(from: definitionDirectory, through: archiveDirectory) else {
            throw CodexAgentDefinitionError.unsafePath(archiveDirectory)
        }
        let anchoredDefinitions = try AnchoredDirectory.openAbsolute(definitionDirectory)
        let components = try relativePathComponents(archiveDirectory, inside: definitionDirectory)
        let anchoredArchive = try anchoredDefinitions.descendant(
            components,
            create: true,
            permissions: mode_t(Self.directoryPermissions)
        )
        try anchoredArchive.setPermissions(mode_t(Self.directoryPermissions))
    }

    private func definitionBase(for directory: URL) -> URL {
        if normalizedPath(directory) == normalizedPath(globalAgentsURL) {
            let home = fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
            return isDescendant(directory, of: home)
                ? home
                : directory.deletingLastPathComponent().standardizedFileURL
        }
        return directory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private func rejectDuplicateName(_ name: String, in directory: URL) throws {
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        )) ?? []
        for file in files where file.pathExtension.lowercased() == "toml" {
            guard let source = boundedString(contentsOf: file, maximumBytes: Self.maximumDefinitionBytes),
                  let existingName = TOMLStringParser.string(named: "name", in: source) else { continue }
            if existingName.caseInsensitiveCompare(name) == .orderedSame {
                throw CodexAgentDefinitionError.duplicateName(name)
            }
        }
    }

    private func requireReviewedDefinition(
        _ agent: AgentProfile,
        named name: String,
        in directory: AnchoredDirectory,
        sourceURL: URL
    ) throws {
        guard agent.definitionReviewProvenance == .fullContent
                || agent.definitionReviewProvenance == .gobyGenerated else {
            throw CodexAgentDefinitionError.incompleteReview(sourceURL)
        }
        guard let reviewedDigest = agent.reviewedDefinitionDigest,
              reviewedDigest.count == 64,
              reviewedDigest.allSatisfy({ $0.isHexDigit }) else {
            throw CodexAgentDefinitionError.changedSource(sourceURL)
        }
        let current: Data
        do {
            current = try directory.read(name, maximumBytes: Self.maximumDefinitionBytes)
        } catch {
            throw CodexAgentDefinitionError.changedSource(sourceURL)
        }
        guard DefinitionReviewDigest.sha256(current) == reviewedDigest else {
            throw CodexAgentDefinitionError.changedSource(sourceURL)
        }
    }

    private func definitionContents(for draft: AgentDefinitionDraft) -> String {
        let capabilities = draft.capabilities.map(\.rawValue).sorted().joined(separator: ", ")
        let scopeMarker = draft.scope == .union ? "# Goby scope: union\n" : ""
        let toolConfiguration = toolConfiguration(for: draft.toolPreset)
        return """
        # Managed by Goby Agentic Dashboard.
        # Goby capabilities: \(capabilities)
        \(scopeMarker)name = \(quotedTOML(draft.name))
        description = \(quotedTOML(draft.summary))
        developer_instructions = \(quotedTOML(draft.instructions))
        \(toolConfiguration)
        """
    }

    private func toolConfiguration(for preset: AgentToolPreset?) -> String {
        guard preset == .iconComposer else { return "" }
        return """

        # Goby tool preset: icon-composer
        # Source: https://github.com/ethbak/icon-composer-mcp
        [mcp_servers.icon_composer]
        command = "npx"
        args = ["-y", "icon-composer-mcp@1.1.0"]
        enabled = true
        required = true
        default_tools_approval_mode = "writes"

        """
    }

    private func registrationBlock(key: String, summary: String, source: URL) -> String {
        """
        [agents.\(key)]
        # Managed by Goby Agentic Dashboard.
        description = \(quotedTOML(summary))
        config_file = \(quotedTOML(registrationPath(for: source)))

        """
    }

    private func registrationPath(for source: URL) -> String {
        let configurationDirectory = registrationConfigurationURL().deletingLastPathComponent()
        if normalizedPath(source.deletingLastPathComponent()) == normalizedPath(globalAgentsURL) {
            return "\(globalAgentsURL.lastPathComponent)/\(source.lastPathComponent)"
        }
        guard !isDescendant(source, of: configurationDirectory) else {
            let basePath = normalizedPath(configurationDirectory)
            return String(normalizedPath(source).dropFirst(basePath.count + 1))
        }
        return normalizedPath(source)
    }

    private func registrationDetails(
        from record: DeletedAgentRecord,
        source: URL,
        directory: URL
    ) throws -> RegistrationDetails? {
        let absent = [
            record.registrationURL == nil,
            record.registrationKey == nil,
            record.registrationBlock == nil
        ]
        if absent.allSatisfy({ $0 }) { return nil }
        let sections = record.registrationBlock.map(registrationSections(in:)) ?? []
        guard absent.allSatisfy({ !$0 }),
              let registrationURL = record.registrationURL?.standardizedFileURL,
              let key = record.registrationKey,
              let block = record.registrationBlock,
              normalizedPath(registrationURL) == normalizedPath(registrationConfigurationURL()),
              sections.count == 1,
              let section = sections.first,
              section.key == key,
              resolvedDefinitionURL(from: section, configurationURL: registrationURL).map(normalizedPath) == normalizedPath(source) else {
            throw CodexAgentDefinitionError.changedSource(source)
        }
        return RegistrationDetails(key: key, block: block)
    }

    private func rejectRegistrationConflict(
        key: String,
        source: URL,
        configuration: String,
        configurationURL: URL
    ) throws {
        for section in registrationSections(in: configuration) {
            if section.key == key {
                throw CodexAgentDefinitionError.duplicateName(key)
            }
            if resolvedDefinitionURL(from: section, configurationURL: configurationURL).map(normalizedPath) == normalizedPath(source) {
                throw CodexAgentDefinitionError.targetExists(source)
            }
        }
    }

    private func registrationTargeting(
        _ source: URL,
        in configuration: String,
        configurationURL: URL
    ) throws -> RegistrationSection? {
        let matches = registrationSections(in: configuration).filter {
            resolvedDefinitionURL(from: $0, configurationURL: configurationURL).map(normalizedPath) == normalizedPath(source)
        }
        guard matches.count <= 1 else {
            throw CodexAgentDefinitionError.changedSource(configurationURL)
        }
        return matches.first
    }

    private func exactRegistration(
        key: String,
        source: URL,
        expectedBlock: String,
        configuration: String,
        configurationURL: URL
    ) throws -> RegistrationSection {
        guard let section = try registrationTargeting(source, in: configuration, configurationURL: configurationURL),
              section.key == key,
              normalizedRegistrationBlock(section.block) == normalizedRegistrationBlock(expectedBlock) else {
            throw CodexAgentDefinitionError.changedSource(configurationURL)
        }
        return section
    }

    private func registrationSections(in source: String) -> [RegistrationSection] {
        guard !source.isEmpty else { return [] }
        var headers: [TableHeader] = []
        var lineStart = source.startIndex
        while lineStart < source.endIndex {
            let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
            let line = String(source[lineStart..<lineEnd])
            if let header = tableHeader(from: line) {
                headers.append(TableHeader(start: lineStart, agentKey: agentKey(from: header)))
            }
            guard lineEnd < source.endIndex else { break }
            lineStart = source.index(after: lineEnd)
        }

        return headers.enumerated().compactMap { index, header in
            guard let key = header.agentKey else { return nil }
            let end = index + 1 < headers.count ? headers[index + 1].start : source.endIndex
            let range = header.start..<end
            let block = String(source[range])
            return RegistrationSection(
                key: key,
                range: range,
                block: block,
                configFile: TOMLStringParser.string(named: "config_file", in: block)
            )
        }
    }

    private func tableHeader(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[["),
              let closing = trimmed.firstIndex(of: "]") else { return nil }
        let suffix = trimmed[trimmed.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        guard suffix.isEmpty || suffix.hasPrefix("#") else { return nil }
        return String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            .trimmingCharacters(in: .whitespaces)
    }

    private func agentKey(from tableHeader: String) -> String? {
        let prefix = "agents."
        guard tableHeader.hasPrefix(prefix) else { return nil }
        let raw = String(tableHeader.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") {
            return TOMLStringParser.string(named: "value", in: "value = \(raw)")
        }
        return raw
    }

    private func resolvedDefinitionURL(
        from section: RegistrationSection,
        configurationURL: URL
    ) -> URL? {
        guard let configFile = section.configFile, !configFile.isEmpty else { return nil }
        if configFile.hasPrefix("/") {
            return URL(fileURLWithPath: configFile).standardizedFileURL
        }
        return URL(
            fileURLWithPath: configFile,
            relativeTo: configurationURL.deletingLastPathComponent()
        ).standardizedFileURL
    }

    private func appendingRegistration(_ block: String, to configuration: String) -> String {
        guard !configuration.isEmpty else { return block }
        return configuration.hasSuffix("\n")
            ? configuration + block
            : configuration + "\n" + block
    }

    private func removing(section: RegistrationSection, from configuration: String) -> String {
        var result = configuration
        result.removeSubrange(section.range)
        return result
    }

    private func normalizedRegistrationBlock(_ block: String) -> String {
        block.trimmingCharacters(in: .newlines)
    }

    private func configurationContents(at configurationURL: URL) throws -> String {
        let expectedURL = registrationConfigurationURL()
        let parent = configurationURL.deletingLastPathComponent().standardizedFileURL
        let home = fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        let base = isDescendant(parent, of: home) ? home : parent
        guard normalizedPath(configurationURL) == normalizedPath(expectedURL),
              isSafeDirectory(parent),
              !containsSymlink(from: base, through: configurationURL),
              !isSymbolicLink(configurationURL) else {
            throw CodexAgentDefinitionError.unsafePath(configurationURL)
        }
        guard fileManager.fileExists(atPath: configurationURL.path(percentEncoded: false)) else {
            return ""
        }
        guard let contents = boundedString(
            contentsOf: configurationURL,
            maximumBytes: Self.maximumConfigurationBytes
        ) else {
            throw CodexAgentDefinitionError.unsafePath(configurationURL)
        }
        return contents
    }

    private func replaceConfiguration(
        _ contents: String,
        at configurationURL: URL,
        expectedCurrent: String
    ) throws {
        guard contents.utf8.count <= Self.maximumConfigurationBytes else {
            throw CodexAgentDefinitionError.unsafePath(configurationURL)
        }
        guard try configurationContents(at: configurationURL) == expectedCurrent else {
            throw CodexAgentDefinitionError.changedSource(configurationURL)
        }
        let directory = try AnchoredDirectory.openAbsolute(configurationURL.deletingLastPathComponent())
        let name = configurationURL.lastPathComponent
        if try directory.contains(name) {
            try directory.replace(
                name,
                contents: Data(contents.utf8),
                expectedCurrent: Data(expectedCurrent.utf8),
                maximumBytes: Self.maximumConfigurationBytes,
                permissions: mode_t(Self.filePermissions)
            )
        } else {
            guard expectedCurrent.isEmpty else {
                throw CodexAgentDefinitionError.changedSource(configurationURL)
            }
            try directory.create(
                name,
                contents: Data(contents.utf8),
                permissions: mode_t(Self.filePermissions)
            )
        }
    }

    private func restoreConfiguration(
        _ previous: String,
        replacing written: String,
        at configurationURL: URL
    ) throws {
        guard try configurationContents(at: configurationURL) == written else {
            throw CodexAgentDefinitionError.changedSource(configurationURL)
        }
        try replaceConfiguration(
            previous,
            at: configurationURL,
            expectedCurrent: written
        )
    }

    private func quotedTOML(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x00...0x1F, 0x7F:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private func boundedString(contentsOf url: URL, maximumBytes: Int) -> String? {
        guard isSafeRegularFile(url, maximumBytes: maximumBytes),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard bytes.count <= maximumBytes else { return nil }
            return String(data: bytes, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func isSafeRegularFile(_ url: URL, maximumBytes: Int) -> Bool {
        guard !isSymbolicLink(url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? maximumBytes + 1) <= maximumBytes
    }

    private func isSafeDirectory(_ url: URL) -> Bool {
        guard !isSymbolicLink(url),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func containsSymlink(from root: URL, through target: URL) -> Bool {
        let rootPath = normalizedPath(root)
        let targetPath = normalizedPath(target)
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else { return true }
        var current = root.standardizedFileURL
        if isSymbolicLink(current) { return true }
        for component in targetPath.dropFirst(rootPath.count).split(separator: "/") {
            current.append(path: String(component))
            if isSymbolicLink(current) { return true }
        }
        return false
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))) != nil {
            return true
        }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = normalizedPath(root)
        let candidatePath = normalizedPath(candidate)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func normalizedPath(_ url: URL) -> String {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while existingAncestor.path(percentEncoded: false) != "/",
              !fileManager.fileExists(atPath: existingAncestor.path(percentEncoded: false)) {
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }

        var canonical = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() where !component.isEmpty {
            canonical.append(path: component)
        }
        let path = canonical.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func slug(_ value: String) -> String {
        let words = value.lowercased().split { !$0.isLetter && !$0.isNumber }
        let result = words.joined(separator: "-")
        return result.isEmpty ? "goby-agent" : String(result.prefix(64))
    }

    private func registrationKey(for value: String, scope: AgentScope, source: URL) -> String {
        let words = value.lowercased().split { !$0.isLetter && !$0.isNumber }
        var result = words.joined(separator: "_")
        if result.isEmpty { result = "goby_agent" }
        if result.first?.isNumber == true { result = "goby_\(result)" }
        guard case .project = scope else { return String(result.prefix(64)) }
        let identity = CodexAgentIdentity.id(for: source).rawValue
        let suffix = String(identity.suffix(8))
        return String("goby_\(result)_\(suffix)".prefix(64))
    }

    private func archiveBatchName() -> String {
        let timestamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        return "\(timestamp)-\(UUID().uuidString.lowercased())"
    }
}
