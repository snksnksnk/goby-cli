import Foundation
import GobyApplication
import GobyDomain

public actor CodexAgentDiscovery: AgentDiscovering {
    private struct SearchRoot: Sendable {
        let url: URL
        let authorizedBaseURL: URL
        let scope: AgentScope
    }

    private static let maximumSearchRoots = 256
    private static let maximumFilesPerRoot = 128
    private static let maximumTotalAgents = 512
    private static let maximumTOMLBytes = 1_048_576
    private static let maximumConfigurationBytes = 4_194_304
    private let fileManager: FileManager
    private let globalAgentsURL: URL

    public init(
        globalAgentsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/agents"),
        fileManager: FileManager = .default
    ) {
        self.globalAgentsURL = globalAgentsURL
        self.fileManager = fileManager
    }

    public func discover(projects: [LabProject]) throws -> AgentImportPlan {
        let registrationKeys = registeredAgentKeys()
        let globalBase = globalAgentsURL.path(percentEncoded: false).hasPrefix(
            fileManager.homeDirectoryForCurrentUser.path(percentEncoded: false) + "/"
        ) ? fileManager.homeDirectoryForCurrentUser : globalAgentsURL.deletingLastPathComponent()
        let roots = ([SearchRoot(url: globalAgentsURL, authorizedBaseURL: globalBase, scope: .global)] + projects.map {
            SearchRoot(
                url: $0.rootURL.appending(path: ".codex/agents"),
                authorizedBaseURL: $0.rootURL,
                scope: .project($0.id)
            )
        }).prefix(Self.maximumSearchRoots)
        var candidates: [AgentImportCandidate] = []
        var seen = Set<String>()

        for root in roots where candidates.count < Self.maximumTotalAgents {
            guard let canonicalRoot = safeCanonicalDirectory(root.url, authorizedBase: root.authorizedBaseURL) else {
                continue
            }
            let remaining = Self.maximumTotalAgents - candidates.count
            let files = boundedChildren(
                at: canonicalRoot,
                limit: min(Self.maximumFilesPerRoot, remaining)
            ).filter { $0.pathExtension.lowercased() == "toml" }
            for file in files {
                let canonicalFile = file.resolvingSymlinksInPath().standardizedFileURL
                let path = canonicalFile.path(percentEncoded: false)
                guard seen.insert(path).inserted,
                      normalizedPath(canonicalFile.deletingLastPathComponent()) == normalizedPath(canonicalRoot),
                      let source = boundedString(contentsOf: canonicalFile) else { continue }
                candidates.append(parse(
                    file: canonicalFile,
                    source: source,
                    scope: root.scope,
                    registrationKey: registrationKeys[normalizedPath(canonicalFile)]
                ))
            }
        }

        candidates.sort { $0.profile.name.localizedStandardCompare($1.profile.name) == .orderedAscending }
        return AgentImportPlan(
            candidates: candidates,
            suggestions: suggestions(for: candidates, projects: projects)
        )
    }

    private func safeCanonicalDirectory(_ url: URL, authorizedBase: URL) -> URL? {
        let lexicalBase = authorizedBase.standardizedFileURL
        let lexicalTarget = url.standardizedFileURL
        let basePath = normalizedPath(lexicalBase)
        let targetPath = normalizedPath(lexicalTarget)
        guard targetPath == basePath || targetPath.hasPrefix(basePath + "/") else { return nil }

        var current = lexicalBase
        let suffix = targetPath.dropFirst(basePath.count)
        for component in suffix.split(separator: "/") {
            current.append(path: String(component))
            guard (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                return nil
            }
        }
        guard fileManager.fileExists(atPath: targetPath) else { return nil }
        let canonicalBase = lexicalBase.resolvingSymlinksInPath().standardizedFileURL
        let canonicalTarget = lexicalTarget.resolvingSymlinksInPath().standardizedFileURL
        let canonicalBasePath = normalizedPath(canonicalBase)
        let canonicalTargetPath = normalizedPath(canonicalTarget)
        guard canonicalTargetPath == canonicalBasePath || canonicalTargetPath.hasPrefix(canonicalBasePath + "/") else {
            return nil
        }
        return canonicalTarget
    }

    private func boundedChildren(at url: URL, limit: Int) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
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

    private func boundedString(contentsOf url: URL) -> String? {
        boundedString(contentsOf: url, maximumBytes: Self.maximumTOMLBytes)
    }

    private func boundedString(contentsOf url: URL, maximumBytes: Int) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? maximumBytes + 1) <= maximumBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: maximumBytes + 1),
              bytes.count <= maximumBytes else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    private func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func parse(
        file: URL,
        source: String,
        scope: AgentScope,
        registrationKey: String?
    ) -> AgentImportCandidate {
        let name = TOMLStringParser.string(named: "name", in: source) ?? file.deletingPathExtension().lastPathComponent
        let summary = TOMLStringParser.string(named: "description", in: source) ?? "Imported Codex agent"
        let instructions = TOMLStringParser.string(named: "developer_instructions", in: source)
        let capabilities = classify("\(name) \(summary) \(source)".lowercased())
        let resolvedScope: AgentScope = scope == .global && source.contains("# Goby scope: union")
            ? .union
            : scope
        let toolPreset: AgentToolPreset? = source.contains("[mcp_servers.icon_composer]")
            && source.contains("icon-composer-mcp")
            ? .iconComposer
            : nil
        let profile = AgentProfile(
            id: CodexAgentIdentity.id(for: file),
            name: name,
            summary: summary,
            instructions: instructions,
            capabilities: capabilities.isEmpty ? [.routing] : capabilities,
            scope: resolvedScope,
            sourceURL: file,
            toolPreset: toolPreset,
            reviewedDefinitionDigest: DefinitionReviewDigest.sha256(source),
            codexRegistrationKey: registrationKey
        )
        let evidence = profile.capabilities.map { "Matched \($0.displayName) terminology" }.sorted()
        return AgentImportCandidate(profile: profile, configurationPreview: source, evidence: evidence)
    }

    private func registeredAgentKeys() -> [String: String] {
        let configurationURL = globalAgentsURL
            .deletingLastPathComponent()
            .appending(path: "config.toml")
            .standardizedFileURL
        guard let configuration = boundedString(
            contentsOf: configurationURL,
            maximumBytes: Self.maximumConfigurationBytes
        ) else { return [:] }

        var activeKey: String?
        var keysByPath: [String: [String]] = [:]
        for rawLine in configuration.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                activeKey = agentKey(fromTableHeader: trimmed)
                continue
            }
            guard let activeKey,
                  let configFile = TOMLStringParser.string(named: "config_file", in: line) else { continue }
            let target: URL
            if configFile.hasPrefix("/") {
                target = URL(fileURLWithPath: configFile).standardizedFileURL
            } else {
                target = configurationURL.deletingLastPathComponent()
                    .appending(path: configFile)
                    .standardizedFileURL
            }
            keysByPath[normalizedPath(target), default: []].append(activeKey)
        }

        return keysByPath.reduce(into: [:]) { result, entry in
            guard entry.value.count == 1, let key = entry.value.first else { return }
            result[entry.key] = key
        }
    }

    private func agentKey(fromTableHeader line: String) -> String? {
        guard line.hasPrefix("["), !line.hasPrefix("[["),
              let closing = line.firstIndex(of: "]") else { return nil }
        let suffix = line[line.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        guard suffix.isEmpty || suffix.hasPrefix("#") else { return nil }
        let header = line[line.index(after: line.startIndex)..<closing]
            .trimmingCharacters(in: .whitespaces)
        guard header.hasPrefix("agents."), header.count > "agents.".count else { return nil }
        let raw = String(header.dropFirst("agents.".count)).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") {
            return TOMLStringParser.string(named: "value", in: "value = \(raw)")
        }
        return raw
    }

    private func suggestions(
        for candidates: [AgentImportCandidate],
        projects: [LabProject]
    ) -> [AgentStructureSuggestion] {
        var result: [AgentStructureSuggestion] = []
        let grouped = Dictionary(grouping: candidates) { candidate in
            candidate.profile.capabilities.map(\.rawValue).sorted().joined(separator: "+")
        }
        for group in grouped.values where group.count > 1 {
            result.append(.init(
                kind: .consolidate,
                title: "Review \(group.count) agents with overlapping capabilities",
                detail: group.map(\.profile.name).sorted().joined(separator: ", "),
                affectedAgentIDs: group.map(\.id)
            ))
        }

        let projectScoped = candidates.compactMap { candidate -> (ProjectID, AgentImportCandidate)? in
            guard case let .project(projectID) = candidate.profile.scope else { return nil }
            return (projectID, candidate)
        }
        let promotionGroups = Dictionary(grouping: projectScoped) { entry in
            entry.1.profile.capabilities.map(\.rawValue).sorted().joined(separator: "+")
        }
        for group in promotionGroups.values where Set(group.map(\.0)).count > 1 {
            result.append(.init(
                kind: .promoteToShared,
                title: "Consider one shared \(capabilityLabel(for: group[0].1.profile)) agent",
                detail: "Equivalent capability coverage appears in \(Set(group.map(\.0)).count) projects. Promotion remains optional and does not change files automatically.",
                affectedAgentIDs: group.map { $0.1.id }
            ))
        }

        let genericNames = Set(["agent", "assistant", "default", "helper", "worker"])
        for candidate in candidates where genericNames.contains(candidate.profile.name.lowercased()) {
            result.append(.init(
                kind: .rename,
                title: "Give \(candidate.profile.name) a capability-specific name",
                detail: "A descriptive role such as \(capabilityLabel(for: candidate.profile)) Agent will make routing reviews easier to scan.",
                affectedAgentIDs: [candidate.id]
            ))
        }

        let globalCapabilities = candidates.reduce(into: Set<AgentCapability>()) { result, candidate in
            switch candidate.profile.scope {
            case .global, .union:
                result.formUnion(candidate.profile.capabilities)
            case .project:
                break
            }
        }
        for project in projects {
            let required = project.platforms.compactMap { platform -> AgentCapability? in
                switch platform {
                case .web: .web
                case .macOS: .macOS
                case .iOS: .iOS
                case .android: .android
                case .backend: .backend
                case .research: .research
                case .general: nil
                }
            }
            let scopedCapabilities = candidates.reduce(into: globalCapabilities) { result, candidate in
                if case let .project(projectID) = candidate.profile.scope, projectID == project.id {
                    result.formUnion(candidate.profile.capabilities)
                }
            }
            let missing = Set(required).subtracting(scopedCapabilities)
            if !missing.isEmpty {
                result.append(.init(
                    kind: .missingCoverage,
                    title: "\(project.name) has a capability gap",
                    detail: "No imported agent covers \(missing.map(\.displayName).sorted().joined(separator: ", "))."
                ))
            }
        }
        return result
    }

    private func capabilityLabel(for profile: AgentProfile) -> String {
        profile.capabilities.map(\.displayName).sorted().first ?? "General"
    }

    private func classify(_ text: String) -> Set<AgentCapability> {
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
        return matches.reduce(into: Set<AgentCapability>()) { result, match in
            if match.1.contains(where: text.contains) { result.insert(match.0) }
        }
    }

}
