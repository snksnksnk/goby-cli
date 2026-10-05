import Foundation
import GobyApplication
import GobyDomain
import GobyInfrastructure
import Testing

@Suite("Bundled project templates")
struct ProjectTemplateTests {
    @Test("Template option validation is shared and rejects unsafe Swift names")
    func sharedParameterValidation() {
        #expect(
            ProjectTemplateCatalog.normalizedParameterValue(
                "  ExampleApp  ",
                kind: .swiftIdentifier
            ) == "ExampleApp"
        )
        #expect(ProjectTemplateCatalog.normalizedParameterValue("class", kind: .swiftIdentifier) == nil)
        #expect(ProjectTemplateCatalog.normalizedParameterValue("9Lives", kind: .swiftIdentifier) == nil)
        #expect(
            ProjectTemplateCatalog.normalizedParameterValue(
                "com.example.ExampleApp",
                kind: .bundleIdentifier
            ) == "com.example.ExampleApp"
        )
        #expect(ProjectTemplateCatalog.normalizedParameterValue("example", kind: .bundleIdentifier) == nil)
        #expect(ProjectTemplateCatalog.normalizedParameterValue("com..example", kind: .bundleIdentifier) == nil)
    }

    @Test("The macOS app template declares macOS platform and agent capability")
    func macOSDescriptorUsesDesktopPlatform() throws {
        let descriptor = try #require(
            ProjectTemplateCatalog.descriptor(for: "macos-swiftui-clean", version: 1)
        )

        #expect(descriptor.platforms == [.macOS])
        #expect(descriptor.suggestedAgents.first?.capabilities.contains(.macOS) == true)
        #expect(descriptor.suggestedAgents.first?.capabilities.contains(.iOS) == false)
    }

    @Test("Every descriptor previews the declared signed artifact set")
    func descriptorsMatchManifests() async throws {
        let templates = BundledProjectTemplateInstantiator()
        for descriptor in ProjectTemplateCatalog.builtIn {
            let plan = try await templates.preview(
                selection: selection(for: descriptor),
                projectName: "Template Test"
            )
            #expect(plan.artifacts.count == descriptor.artifactCount)
            #expect(plan.descriptor == descriptor)
            #expect(plan.artifacts.allSatisfy { !$0.relativePath.hasPrefix("/") })
            #expect(Set(plan.artifacts.map(\.relativePath)).count == plan.artifacts.count)
        }
    }

    @Test("A package template is installed atomically and can be safely rolled back")
    func installsAndRollsBackPackage() async throws {
        let parent = try temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let parentIdentity = try #require(GADFileSystemIdentity.capture(parent))
        let descriptor = try #require(ProjectTemplateCatalog.descriptor(for: "swift-package-clean", version: 1))
        let templates = BundledProjectTemplateInstantiator()

        let receipt = try await templates.instantiate(
            selection: selection(for: descriptor),
            projectName: "Sample Package",
            directoryName: "SamplePackage",
            in: parent,
            expectedParentIdentity: parentIdentity
        )

        let manifest = receipt.placement.rootURL.appending(path: "Package.swift")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(try String(contentsOf: manifest, encoding: .utf8).contains("SamplePackageDomain"))
        #expect(try await templates.rollback(receipt) == .removed)
        try await LocalProjectDirectoryCreator().removeProjectDirectoryIfEmpty(receipt.placement)
        #expect(!FileManager.default.fileExists(atPath: receipt.placement.rootURL.path))
    }

    @Test("Rollback preserves a generated file after it changes")
    func rollbackPreservesChanges() async throws {
        let parent = try temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let parentIdentity = try #require(GADFileSystemIdentity.capture(parent))
        let descriptor = try #require(ProjectTemplateCatalog.descriptor(for: "swift-package-clean", version: 1))
        let templates = BundledProjectTemplateInstantiator()
        let receipt = try await templates.instantiate(
            selection: selection(for: descriptor),
            projectName: "Sample Package",
            directoryName: "SamplePackage",
            in: parent,
            expectedParentIdentity: parentIdentity
        )
        let readme = receipt.placement.rootURL.appending(path: "README.md")
        try Data("User edit\n".utf8).write(to: readme)

        let result = try await templates.rollback(receipt)
        guard case let .preservedChanges(paths) = result else {
            Issue.record("Expected changed content to be preserved")
            return
        }
        #expect(paths.contains("README.md"))
        #expect(try String(contentsOf: readme, encoding: .utf8) == "User edit\n")
    }

    @Test("Unknown versions and unsafe parameters fail closed")
    func validationFailsClosed() async throws {
        let templates = BundledProjectTemplateInstantiator()
        await #expect(throws: GobyApplicationError.self) {
            try await templates.preview(
                selection: ProjectTemplateSelection(
                    id: "ios-swiftui-clean",
                    version: 99,
                    parameters: [.moduleName: "Sample", .bundleIdentifier: "com.example.Sample"]
                ),
                projectName: "Sample"
            )
        }
        await #expect(throws: GobyApplicationError.self) {
            try await templates.preview(
                selection: ProjectTemplateSelection(
                    id: "ios-swiftui-clean",
                    version: 1,
                    parameters: [.moduleName: "../Escape", .bundleIdentifier: "invalid"]
                ),
                projectName: "Sample"
            )
        }
    }

    @Test("Project creation persists template provenance and discovered verification metadata")
    func createProjectPersistsTemplateMetadata() async throws {
        let root = try temporaryParent()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: false)
        let repository = PersistentStore(
            directoryURL: root.appending(path: "State", directoryHint: .isDirectory)
        )
        let descriptor = try #require(
            ProjectTemplateCatalog.descriptor(for: "swift-package-clean", version: 1)
        )
        let createProject = CreateProjectUseCase(
            catalog: repository,
            projectCatalog: repository,
            groups: repository,
            agentCatalog: repository,
            providerConfigurations: repository,
            definitions: CodexAgentDefinitionStore(
                globalAgentsURL: root.appending(path: "Codex/agents", directoryHint: .isDirectory)
            ),
            directories: LocalProjectDirectoryCreator(),
            templates: BundledProjectTemplateInstantiator()
        )

        let created = try await createProject(NewProjectDraft(
            name: "Ledger Core",
            directoryName: "LedgerCore",
            parentURL: projectsRoot,
            platforms: descriptor.platforms,
            template: selection(for: descriptor)
        ))

        #expect(created.project.template == ProjectTemplateReference(id: descriptor.id, version: 1))
        #expect(created.project.frameworks == ["Swift Package"])
        #expect(created.project.testCommands == ["swift test"])
        #expect(created.project.instructionFiles == [created.project.rootURL.appending(path: "AGENTS.md")])
        #expect(FileManager.default.fileExists(atPath: created.project.rootURL.appending(path: "Package.swift").path))
        #expect(try await repository.snapshot().projects == [created.project])
    }

    @Test("A downstream catalog failure rolls back unchanged generated template content")
    func createProjectRollsBackTemplateAfterFailure() async throws {
        let root = try temporaryParent()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: false)
        let repository = PersistentStore(
            directoryURL: root.appending(path: "State", directoryHint: .isDirectory)
        )
        let descriptor = try #require(
            ProjectTemplateCatalog.descriptor(for: "swift-package-clean", version: 1)
        )
        let createProject = CreateProjectUseCase(
            catalog: repository,
            projectCatalog: repository,
            groups: repository,
            agentCatalog: repository,
            providerConfigurations: RejectingProjectTemplateProviderCatalog(),
            definitions: CodexAgentDefinitionStore(
                globalAgentsURL: root.appending(path: "Codex/agents", directoryHint: .isDirectory)
            ),
            directories: LocalProjectDirectoryCreator(),
            templates: BundledProjectTemplateInstantiator()
        )

        await #expect(throws: ProjectTemplateTestFailure.rejected) {
            try await createProject(NewProjectDraft(
                name: "Rejected Package",
                directoryName: "RejectedPackage",
                parentURL: projectsRoot,
                platforms: descriptor.platforms,
                template: selection(for: descriptor)
            ))
        }
        #expect(!FileManager.default.fileExists(
            atPath: projectsRoot.appending(path: "RejectedPackage").path
        ))
        #expect(try await repository.snapshot() == .empty)
    }

    @Test("Every generated starter project compiles with strict Swift 6 settings")
    func generatedProjectsCompile() async throws {
        let root = try temporaryParent()
        defer { try? FileManager.default.removeItem(at: root) }
        let parentIdentity = try #require(GADFileSystemIdentity.capture(root))
        let templates = BundledProjectTemplateInstantiator()

        for descriptor in ProjectTemplateCatalog.builtIn {
            let moduleName = switch descriptor.kind {
            case .iOSApp: "TemplateIOSApp"
            case .macOSApp: "TemplateMacApp"
            case .swiftPackage: "TemplatePackage"
            }
            let parameters = Dictionary(uniqueKeysWithValues: descriptor.parameters.map { parameter in
                switch parameter.id {
                case .moduleName: (parameter.id, moduleName)
                case .bundleIdentifier: (parameter.id, "com.example.\(moduleName)")
                }
            })
            let receipt = try await templates.instantiate(
                selection: ProjectTemplateSelection(
                    id: descriptor.id,
                    version: descriptor.version,
                    parameters: parameters
                ),
                projectName: descriptor.name,
                directoryName: moduleName,
                in: root,
                expectedParentIdentity: parentIdentity
            )
            let projectRoot = receipt.placement.rootURL
            switch descriptor.kind {
            case .swiftPackage:
                try run(
                    "/usr/bin/xcrun",
                    arguments: ["swift", "test", "--disable-sandbox", "--scratch-path", projectRoot.appending(path: ".build").path],
                    currentDirectory: projectRoot
                )
            case .iOSApp, .macOSApp:
                try run(
                    "/usr/bin/xcrun",
                    arguments: [
                        "swift", "test", "--disable-sandbox", "--package-path", projectRoot.appending(path: "AppCore").path,
                        "--scratch-path", projectRoot.appending(path: ".build").path,
                    ],
                    currentDirectory: projectRoot
                )
                let destination = descriptor.kind == .iOSApp
                    ? "generic/platform=iOS"
                    : "platform=macOS"
                try run(
                    "/usr/bin/xcrun",
                    arguments: [
                        "xcodebuild",
                        "-project", projectRoot.appending(path: "\(moduleName).xcodeproj").path,
                        "-scheme", moduleName,
                        "-destination", destination,
                        "-derivedDataPath", projectRoot.appending(path: "DerivedData").path,
                        "CODE_SIGNING_ALLOWED=NO",
                        "build-for-testing",
                    ],
                    currentDirectory: projectRoot
                )
            }
        }
    }

    private func selection(for descriptor: ProjectTemplateDescriptor) -> ProjectTemplateSelection {
        var parameters: [ProjectTemplateParameterID: String] = [.moduleName: "SamplePackage"]
        if descriptor.parameters.contains(where: { $0.id == .bundleIdentifier }) {
            parameters[.bundleIdentifier] = "com.example.SamplePackage"
        }
        return ProjectTemplateSelection(id: descriptor.id, version: descriptor.version, parameters: parameters)
    }

    private func temporaryParent() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "goby-template-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL
    ) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let buildHome = currentDirectory.appending(path: ".goby-build-home", directoryHint: .isDirectory)
        let moduleCache = currentDirectory.appending(path: ".goby-module-cache", directoryHint: .isDirectory)
        let packageCache = currentDirectory.appending(path: ".goby-package-cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: buildHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moduleCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageCache, withIntermediateDirectories: true)
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CFFIXED_USER_HOME": buildHome.path,
            "CLANG_MODULE_CACHE_PATH": moduleCache.path,
            "SWIFTPM_MODULECACHE_OVERRIDE": moduleCache.path,
            "XDG_CACHE_HOME": packageCache.path,
        ]) { _, isolated in isolated }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let command = ([executable] + arguments).joined(separator: " ")
            let transcript = String(decoding: data, as: UTF8.self)
            Issue.record("Generated project command failed: \(command)\n\(transcript)")
            throw ProjectTemplateTestFailure.buildFailed
        }
    }
}

private enum ProjectTemplateTestFailure: Error, Equatable {
    case rejected
    case buildFailed
}

private actor RejectingProjectTemplateProviderCatalog: ProviderConfigurationCatalogManaging {
    func saveProjectProviderConfiguration(_ configuration: ProjectProviderConfiguration) async throws {
        throw ProjectTemplateTestFailure.rejected
    }

    func removeProjectProviderConfiguration(projectID: ProjectID) async throws {}
    func saveProviderBinding(_ binding: ProviderAgentBinding) async throws {}
    func removeProviderBinding(id: ProviderAgentBindingID) async throws {}
    func saveProviderCollaborationSet(_ collaborationSet: ProviderCollaborationSet) async throws {}
    func removeProviderCollaborationSet(id: ProviderCollaborationSetID) async throws {}
}
