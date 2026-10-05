import Foundation
import GobyApplication
import GobyDomain

public actor FileSystemProjectDiscovery: ProjectDiscovering {
    private struct PackageManifest: Decodable {
        let scripts: [String: String]?
    }

    private struct FileManagerReference: @unchecked Sendable {
        let value: FileManager
    }

    private final class InspectionQueueReference: @unchecked Sendable {
        let value: OperationQueue

        init(maximumConcurrentOperations: Int) {
            let queue = OperationQueue()
            queue.name = "Goby.ProjectDiscovery.Inspection"
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = maximumConcurrentOperations
            value = queue
        }
    }

    private final class InspectionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[ProjectCandidate], Never>?
        private var isResolved = false

        func install(_ continuation: CheckedContinuation<[ProjectCandidate], Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func resolve(with result: [ProjectCandidate]) {
            lock.lock()
            guard !isResolved else {
                lock.unlock()
                return
            }
            isResolved = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    private static let timeoutQueue = DispatchQueue(label: "Goby.ProjectDiscovery.Timeout")
    private static let maximumRootCount = 256
    private static let maximumDirectoryEntries = 512
    private static let maximumAgentFiles = 128
    private static let maximumTextFileBytes = 1_048_576
    private let fileManager: FileManagerReference
    private let inspectionQueue: InspectionQueueReference
    private let rootInspectionTimeout: TimeInterval
    private let maximumConcurrentInspections: Int

    public init(
        fileManager: FileManager = .default,
        rootInspectionTimeout: TimeInterval = 5.0,
        maximumConcurrentInspections: Int = 16
    ) {
        self.fileManager = FileManagerReference(value: fileManager)
        self.rootInspectionTimeout = max(0.1, rootInspectionTimeout)
        self.maximumConcurrentInspections = max(1, maximumConcurrentInspections)
        self.inspectionQueue = InspectionQueueReference(maximumConcurrentOperations: max(1, maximumConcurrentInspections))
    }

    public func discover(selectedRoots: [URL]) async throws -> [ProjectCandidate] {
        var candidates: [ProjectCandidate] = []
        var seen = Set<String>()
        var seenSelectedRoots = Set<String>()
        let roots = selectedRoots.compactMap { selectedRoot -> URL? in
            let root = selectedRoot.resolvingSymlinksInPath().standardizedFileURL
            return seenSelectedRoots.insert(root.path(percentEncoded: false)).inserted ? root : nil
        }.prefix(Self.maximumRootCount)
        let boundedRoots = Array(roots)

        await withTaskGroup(of: [ProjectCandidate].self) { group in
            var nextIndex = 0
            let initialCount = min(maximumConcurrentInspections, boundedRoots.count)
            while nextIndex < initialCount {
                let root = boundedRoots[nextIndex]
                group.addTask { await self.inspectWithinTimeLimit(root) }
                nextIndex += 1
            }

            while let inspected = await group.next() {
                for candidate in inspected {
                    let path = candidate.project.rootURL.path(percentEncoded: false)
                    guard seen.insert(path).inserted else { continue }
                    candidates.append(candidate)
                }
                if nextIndex < boundedRoots.count {
                    let root = boundedRoots[nextIndex]
                    group.addTask { await self.inspectWithinTimeLimit(root) }
                    nextIndex += 1
                }
            }
        }

        return candidates.sorted {
            $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending
        }
    }

    private func inspectWithinTimeLimit(_ root: URL) async -> [ProjectCandidate] {
        let fileManager = self.fileManager
        let inspectionQueue = self.inspectionQueue
        let inspectionTimeout = rootInspectionTimeout
        let gate = InspectionGate()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            inspectionQueue.value.addOperation {
                let result = (try? Self.inspectSelection(root, fileManager: fileManager.value)) ?? []
                gate.resolve(with: result)
            }
            Self.timeoutQueue.asyncAfter(deadline: .now() + inspectionTimeout) {
                gate.resolve(with: [])
            }
        }
    }

    private static func inspectSelection(
        _ selectedRoot: URL,
        fileManager: FileManager
    ) throws -> [ProjectCandidate] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: selectedRoot.path(percentEncoded: false),
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return [] }
        return try rootsToInspect(from: selectedRoot, fileManager: fileManager).compactMap {
            try? inspect($0, fileManager: fileManager)
        }
    }

    private static func rootsToInspect(from selectedRoot: URL, fileManager: FileManager) throws -> [URL] {
        if isProjectRoot(selectedRoot, fileManager: fileManager) {
            return [selectedRoot]
        }

        let children = boundedChildren(
            at: selectedRoot,
            fileManager: fileManager,
            limit: maximumDirectoryEntries
        )
        return children.compactMap { child in
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isHidden != true,
                  values.isSymbolicLink != true else { return nil }
            let canonicalChild = child.resolvingSymlinksInPath().standardizedFileURL
            guard isDescendant(canonicalChild, of: selectedRoot),
                  isProjectRoot(canonicalChild, fileManager: fileManager) else { return nil }
            return canonicalChild
        }
    }

    private static func isProjectRoot(_ url: URL, fileManager: FileManager) -> Bool {
        let markers = [
            "Package.swift", "package.json", "pyproject.toml", "Cargo.toml",
            "build.gradle", "build.gradle.kts", "settings.gradle", "AGENTS.md"
        ]
        if hasSafeGitDirectoryMarker(url)
            || markers.contains(where: { fileManager.fileExists(atPath: url.appending(path: $0).path(percentEncoded: false)) }) {
            return true
        }
        return boundedChildren(
            at: url,
            fileManager: fileManager,
            limit: maximumDirectoryEntries
        ).contains {
            let name = $0.lastPathComponent
            return name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace")
        }
    }

    private static func inspect(_ root: URL, fileManager: FileManager) throws -> ProjectCandidate {
        let childNames = Set(boundedChildren(
            at: root,
            fileManager: fileManager,
            limit: maximumDirectoryEntries
        ).map(\.lastPathComponent))
        let hasXcodeContainer = childNames.contains {
            $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace")
        }
        var platforms = Set<ProjectPlatform>()
        var frameworks: [String] = []
        var tests: [String] = []
        var evidence: [String] = []

        if childNames.contains("package.json") {
            platforms.insert(.web)
            evidence.append("package.json")
            let packageURL = root.appending(path: "package.json")
            if let text = boundedString(contentsOf: packageURL, maximumBytes: maximumTextFileBytes) {
                if let manifest = try? JSONDecoder().decode(PackageManifest.self, from: Data(text.utf8)),
                   let testScript = manifest.scripts?["test"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !testScript.isEmpty {
                    tests.append("npm test")
                }
                for (needle, name) in [("next", "Next.js"), ("react", "React"), ("svelte", "Svelte"), ("vue", "Vue")] where text.localizedCaseInsensitiveContains(needle) {
                    frameworks.append(name)
                }
            }
        }

        if childNames.contains("Package.swift") {
            if !hasXcodeContainer {
                let swiftPlatforms = detectedSwiftPackagePlatforms(at: root)
                platforms.formUnion(swiftPlatforms)
                evidence.append(contentsOf: swiftPlatforms.map { "Swift package target: \($0.displayName)" })
            }
            frameworks.append("Swift Package")
            tests.append("swift test")
            evidence.append("Package.swift")
        }

        if hasXcodeContainer {
            let xcodePlatforms = detectedXcodePlatforms(at: root, fileManager: fileManager)
            platforms.formUnion(xcodePlatforms)
            frameworks.append("Xcode")
            evidence.append("Xcode project")
            evidence.append(contentsOf: xcodePlatforms.map { "Xcode target: \($0.displayName)" })
        }

        if childNames.contains("build.gradle") || childNames.contains("build.gradle.kts") || childNames.contains("gradlew") {
            platforms.insert(.android)
            frameworks.append("Gradle")
            tests.append(childNames.contains("gradlew") ? "./gradlew test" : "gradle test")
            evidence.append("Gradle project")
        }

        if childNames.contains("pyproject.toml") || childNames.contains("Cargo.toml") {
            platforms.insert(.backend)
            evidence.append(childNames.contains("pyproject.toml") ? "pyproject.toml" : "Cargo.toml")
        }

        // A Codex project is often a monorepo whose platform manifests live in
        // immediate module folders. Inspect only one authorized level so Goby
        // can model the lab accurately without recursively scanning unrelated
        // dependency trees such as node_modules or build products.
        let moduleDirectories = boundedChildren(
            at: root,
            fileManager: fileManager,
            limit: maximumDirectoryEntries
        ).filter { child in
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isHidden != true && values.isSymbolicLink != true
        }
        for module in moduleDirectories {
            let moduleName = module.lastPathComponent.lowercased()
            let moduleCommandOperand = Self.shellQuotedPathComponent(module.lastPathComponent)
            let moduleChildren = Set(boundedChildren(
                at: module,
                fileManager: fileManager,
                limit: maximumDirectoryEntries
            ).map(\.lastPathComponent))
            let moduleHasXcodeContainer = moduleChildren.contains {
                $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace")
            }
            let evidencePrefix = module.lastPathComponent + "/"

            if moduleChildren.contains("package.json") {
                platforms.insert(.web)
                evidence.append(evidencePrefix + "package.json")
                let packageURL = module.appending(path: "package.json")
                if let text = boundedString(contentsOf: packageURL, maximumBytes: maximumTextFileBytes) {
                    if let moduleCommandOperand,
                       let manifest = try? JSONDecoder().decode(PackageManifest.self, from: Data(text.utf8)),
                       let testScript = manifest.scripts?["test"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !testScript.isEmpty {
                        tests.append("npm --prefix \(moduleCommandOperand) test")
                    }
                    for (needle, name) in [("next", "Next.js"), ("react", "React"), ("svelte", "Svelte"), ("vue", "Vue")] where text.localizedCaseInsensitiveContains(needle) {
                        frameworks.append(name)
                    }
                }
            }

            if moduleChildren.contains("Package.swift") {
                if moduleName.contains("backend") || moduleName.contains("server") || moduleName.contains("api") {
                    platforms.insert(.backend)
                } else if !moduleHasXcodeContainer {
                    let swiftPlatforms = detectedSwiftPackagePlatforms(at: module)
                    platforms.formUnion(swiftPlatforms)
                    evidence.append(contentsOf: swiftPlatforms.map {
                        evidencePrefix + "Swift package target: \($0.displayName)"
                    })
                }
                frameworks.append("Swift Package")
                if let moduleCommandOperand {
                    tests.append("swift test --package-path \(moduleCommandOperand)")
                }
                evidence.append(evidencePrefix + "Package.swift")
            }

            if moduleHasXcodeContainer {
                let xcodePlatforms = detectedXcodePlatforms(at: module, fileManager: fileManager)
                platforms.formUnion(xcodePlatforms)
                frameworks.append("Xcode")
                evidence.append(evidencePrefix + "Xcode project")
                evidence.append(contentsOf: xcodePlatforms.map {
                    evidencePrefix + "Xcode target: \($0.displayName)"
                })
            }

            if moduleChildren.contains("build.gradle")
                || moduleChildren.contains("build.gradle.kts")
                || moduleChildren.contains("gradlew") {
                platforms.insert(.android)
                frameworks.append("Gradle")
                if moduleChildren.contains("gradlew"),
                   let moduleCommandOperand,
                   let executable = Self.shellQuotedPathComponent("./\(module.lastPathComponent)/gradlew") {
                    tests.append("\(executable) -p \(moduleCommandOperand) test")
                }
                evidence.append(evidencePrefix + "Gradle")
            }

            if moduleChildren.contains("pyproject.toml") || moduleChildren.contains("Cargo.toml") {
                platforms.insert(.backend)
                evidence.append(evidencePrefix + (moduleChildren.contains("pyproject.toml") ? "pyproject.toml" : "Cargo.toml"))
            }
        }

        if platforms.isEmpty {
            platforms.insert(.general)
        }

        let instructionFiles = ["AGENTS.md", "CLAUDE.md"]
            .map { root.appending(path: $0) }
            .filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
        let projectID = ProjectID.derived(fromProjectRoot: root)
        let agents = try discoverAgents(in: root, projectID: projectID, fileManager: fileManager)
        let project = LabProject(
            id: projectID,
            name: root.lastPathComponent,
            rootURL: root,
            platforms: platforms,
            frameworks: Array(Set(frameworks)).sorted(),
            testCommands: Array(Set(tests)).sorted(),
            instructionFiles: instructionFiles,
            isGitRepository: isSafeGitRepositoryRoot(root)
        )
        return ProjectCandidate(project: project, detectedAgents: agents, evidence: evidence.sorted())
    }

    /// Reads bounded Xcode build metadata instead of assuming every Apple project targets iOS.
    /// Empty or nonstandard project bundles keep the legacy iOS fallback until a target SDK is known.
    private static func detectedXcodePlatforms(
        at root: URL,
        fileManager: FileManager
    ) -> Set<ProjectPlatform> {
        var result = Set<ProjectPlatform>()
        let projectBundles = boundedChildren(
            at: root,
            fileManager: fileManager,
            limit: maximumDirectoryEntries
        ).filter { child in
            guard child.lastPathComponent.hasSuffix(".xcodeproj"),
                  let values = try? child.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }

        for projectBundle in projectBundles {
            let projectFile = projectBundle.appending(path: "project.pbxproj", directoryHint: .notDirectory)
            guard let contents = boundedString(
                contentsOf: projectFile,
                maximumBytes: maximumTextFileBytes
            )?.lowercased() else { continue }

            if contents.contains("sdkroot = macosx")
                || contents.contains("macosx_deployment_target")
                || contents.contains("supported_platforms = macosx") {
                result.insert(.macOS)
            }
            if contents.contains("sdkroot = iphoneos")
                || contents.contains("iphoneos_deployment_target")
                || contents.contains("iphonesimulator") {
                result.insert(.iOS)
            }
        }

        return result.isEmpty ? [.iOS] : result
    }

    private static func detectedSwiftPackagePlatforms(at root: URL) -> Set<ProjectPlatform> {
        let manifest = root.appending(path: "Package.swift", directoryHint: .notDirectory)
        guard let contents = boundedString(
            contentsOf: manifest,
            maximumBytes: maximumTextFileBytes
        )?.lowercased() else { return [.general] }
        var result = Set<ProjectPlatform>()
        if contents.contains(".macos(") { result.insert(.macOS) }
        if contents.contains(".ios(") { result.insert(.iOS) }
        return result.isEmpty ? [.general] : result
    }

    /// Produces one inert POSIX-shell operand for a discovered path component.
    /// Control/newline names are omitted because they cannot also be rendered
    /// unambiguously in the review surface and agent instruction.
    nonisolated static func shellQuotedPathComponent(_ value: String) -> String? {
        guard !value.isEmpty,
              value.utf8.count <= 255,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func isSafeGitRepositoryRoot(_ root: URL) -> Bool {
        guard hasSafeGitDirectoryMarker(root) else { return false }
        do {
            let commonDirectory = try HardenedGitProcess.linkedWorktreeCommonDirectory(in: root)
            try HardenedGitProcess.validateRepositoryIdentity(
                in: root,
                allowedLinkedWorktreeCommonDirectory: commonDirectory
            )
            return true
        } catch {
            return false
        }
    }

    private static func hasSafeGitDirectoryMarker(_ root: URL) -> Bool {
        let marker = root.appending(path: ".git")
        guard let values = try? marker.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return (values.isDirectory == true || values.isRegularFile == true)
            && values.isSymbolicLink != true
    }

    private static func discoverAgents(
        in root: URL,
        projectID: ProjectID,
        fileManager: FileManager
    ) throws -> [AgentProfile] {
        let agentsDirectory = root.appending(path: ".codex/agents")
        let codexDirectory = root.appending(path: ".codex")
        guard fileManager.fileExists(atPath: agentsDirectory.path(percentEncoded: false)),
              !isSymbolicLink(codexDirectory),
              !isSymbolicLink(agentsDirectory) else { return [] }
        let canonicalProject = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalAgents = agentsDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(canonicalAgents, of: canonicalProject) else { return [] }
        let files = boundedChildren(
            at: canonicalAgents,
            fileManager: fileManager,
            limit: maximumAgentFiles
        ).filter { $0.pathExtension.lowercased() == "toml" }

        return files.compactMap { file in
            let canonicalFile = file.resolvingSymlinksInPath().standardizedFileURL
            guard normalizedPath(canonicalFile.deletingLastPathComponent()) == normalizedPath(canonicalAgents),
                  isSafeRegularFile(canonicalFile, maximumBytes: maximumTextFileBytes),
                  let text = boundedString(contentsOf: canonicalFile, maximumBytes: maximumTextFileBytes) else { return nil }
            let name = TOMLStringParser.string(named: "name", in: text) ?? canonicalFile.deletingPathExtension().lastPathComponent
            let summary = TOMLStringParser.string(named: "description", in: text) ?? "Imported project agent"
            let instructions = TOMLStringParser.string(named: "developer_instructions", in: text)
            let searchable = "\(name) \(summary) \(text)".lowercased()
            let capabilities = classifyCapabilities(searchable)
            let toolPreset: AgentToolPreset? = text.contains("[mcp_servers.icon_composer]")
                && text.contains("icon-composer-mcp")
                ? .iconComposer
                : nil
            return AgentProfile(
                id: AgentID(rawValue: stableID(prefix: "agent", value: canonicalFile.path(percentEncoded: false))),
                name: name,
                summary: summary,
                instructions: instructions,
                capabilities: capabilities.isEmpty ? [.routing] : capabilities,
                scope: .project(projectID),
                sourceURL: canonicalFile,
                toolPreset: toolPreset,
                reviewedDefinitionDigest: DefinitionReviewDigest.sha256(text)
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func boundedChildren(at url: URL, fileManager: FileManager, limit: Int) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in false }
        ) else { return [] }
        var result: [URL] = []
        while result.count < limit, let child = enumerator.nextObject() as? URL {
            enumerator.skipDescendants()
            result.append(child)
        }
        return result
    }

    private static func boundedString(contentsOf url: URL, maximumBytes: Int) -> String? {
        guard isSafeRegularFile(url, maximumBytes: maximumBytes),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func isSafeRegularFile(_ url: URL, maximumBytes: Int) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? maximumBytes + 1) <= maximumBytes
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = normalizedPath(root)
        let candidatePath = normalizedPath(candidate)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func classifyCapabilities(_ text: String) -> Set<AgentCapability> {
        var result = Set<AgentCapability>()
        let matches: [(AgentCapability, [String])] = [
            (.routing, ["route", "orchestrat", "coordinat"]),
            (.research, ["research", "source", "investigat"]),
            (.web, ["web", "frontend", "react", "next.js"]),
            (.macOS, ["macos", "mac os", "appkit", "mac app"]),
            (.iOS, ["ios", "iphone", "ipad", "uikit"]),
            (.android, ["android", "kotlin", "gradle"]),
            (.backend, ["backend", "server", "database", "api"]),
            (.testing, ["test", "qa", "verification"]),
            (.review, ["review", "audit"]),
            (.security, ["security", "vulnerab", "threat"]),
            (.documentation, ["documentation", "docs", "writer"]),
            (.release, ["release", "deploy", "ship"]),
            (.design, ["icon", "logo", "brand", "visual design", "icon-composer"])
        ]
        for (capability, terms) in matches where terms.contains(where: text.contains) {
            result.insert(capability)
        }
        return result
    }

    private static func stableID(prefix: String, value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(prefix)-\(String(hash, radix: 16))"
    }
}
