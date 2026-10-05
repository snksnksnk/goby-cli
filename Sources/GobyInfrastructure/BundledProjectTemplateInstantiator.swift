import CryptoKit
import Darwin
import Foundation
import GobyApplication
import GobyDomain

public actor BundledProjectTemplateInstantiator: ProjectTemplateInstantiating {
    private struct Manifest: Decodable {
        struct File: Decodable {
            let source: String
            let destination: String
        }

        let id: ProjectTemplateID
        let version: Int
        let testCommands: [String]
        let instructionRelativePaths: [String]
        let files: [File]
    }

    private struct RenderedFile {
        let relativePath: String
        let data: Data
        let digest: String
    }

    private struct RenderedTemplate {
        let plan: ProjectTemplatePlan
        let files: [RenderedFile]
    }

    private static let maximumManifestBytes = 256 * 1_024
    private static let maximumTemplateFileBytes = 2 * 1_024 * 1_024
    private static let maximumTemplateBytes = 16 * 1_024 * 1_024
    private let resourceRoot: URL

    public init(resourceRoot: URL? = nil) {
        if let resourceRoot {
            self.resourceRoot = resourceRoot.standardizedFileURL
        } else if let bundledRoot = Bundle.module.url(
            forResource: "ProjectTemplates",
            withExtension: nil
        ) {
            self.resourceRoot = bundledRoot.standardizedFileURL
        } else {
            self.resourceRoot = Bundle.module.resourceURL!
                .appending(path: "ProjectTemplates", directoryHint: .isDirectory)
                .standardizedFileURL
        }
    }

    public func preview(
        selection: ProjectTemplateSelection,
        projectName: String
    ) throws -> ProjectTemplatePlan {
        try render(selection: selection, projectName: projectName).plan
    }

    public func instantiate(
        selection: ProjectTemplateSelection,
        projectName: String,
        directoryName: String,
        in parentURL: URL,
        expectedParentIdentity: GADFileSystemIdentity
    ) throws -> ProjectTemplateInstantiationReceipt {
        let rendered = try render(selection: selection, projectName: projectName)
        let cleanName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafePathComponent(cleanName) else {
            throw GobyApplicationError.invalidProjectDirectoryName
        }

        let parentURL = parentURL.standardizedFileURL
        let parent = try AnchoredDirectory.openAbsolute(parentURL)
        guard Self.matches(expectedParentIdentity, descriptor: parent.descriptor),
              expectedParentIdentity.matchesCurrentObject(at: parentURL) else {
            throw GobyApplicationError.projectParentAuthorizationChanged
        }
        guard try !parent.contains(cleanName) else {
            throw GobyApplicationError.projectDirectoryAlreadyExists(cleanName)
        }

        let stagingParentURL = FileManager.default.temporaryDirectory
            .appending(path: "goby-project-template-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: stagingParentURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: stagingParentURL) }
        let stagedRootURL = stagingParentURL.appending(path: cleanName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: stagedRootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        for file in rendered.files {
            let destination = stagedRootURL.appending(path: file.relativePath).standardizedFileURL
            guard Self.isDescendant(destination, of: stagedRootURL) else {
                throw GobyApplicationError.invalidProjectTemplateParameters("a generated path escaped the project folder")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try file.data.write(to: destination, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }

        let stagedParent = try AnchoredDirectory.openAbsolute(stagingParentURL)
        guard Self.matches(expectedParentIdentity, descriptor: parent.descriptor),
              expectedParentIdentity.matchesCurrentObject(at: parentURL) else {
            throw GobyApplicationError.projectParentAuthorizationChanged
        }
        guard renameatx_np(
            stagedParent.descriptor,
            cleanName,
            parent.descriptor,
            cleanName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST {
                throw GobyApplicationError.projectDirectoryAlreadyExists(cleanName)
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let child = openat(parent.descriptor, cleanName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0,
              let identity = GADFileSystemIdentity.capture(fileDescriptor: child),
              identity.kind == .directory else {
            if child >= 0 { close(child) }
            throw GobyApplicationError.projectTemplateRecoveryRequired(
                rendered.plan.artifacts.map(\.relativePath)
            )
        }
        close(child)
        let placement = ProjectDirectoryPlacement(
            rootURL: parentURL.appending(path: cleanName, directoryHint: .isDirectory),
            fileSystemIdentity: identity
        )
        let receipt = ProjectTemplateInstantiationReceipt(placement: placement, plan: rendered.plan)
        guard placement.matchesCurrentObject(),
              expectedParentIdentity.matchesCurrentObject(at: parentURL) else {
            _ = try? rollback(receipt)
            throw GobyApplicationError.projectDirectoryAuthorizationChanged
        }
        return receipt
    }

    public func rollback(
        _ receipt: ProjectTemplateInstantiationReceipt
    ) throws -> ProjectTemplateRollbackResult {
        guard receipt.placement.matchesCurrentObject() else {
            return .preservedChanges(relativePaths: receipt.plan.artifacts.map(\.relativePath))
        }
        let root = try AnchoredDirectory.openAbsolute(receipt.placement.rootURL)
        guard Self.matches(receipt.placement.fileSystemIdentity, descriptor: root.descriptor) else {
            return .preservedChanges(relativePaths: receipt.plan.artifacts.map(\.relativePath))
        }

        var preserved: [String] = []
        for artifact in receipt.plan.artifacts.sorted(by: {
            $0.relativePath.split(separator: "/").count > $1.relativePath.split(separator: "/").count
        }) where !artifact.isDirectory {
            let components = artifact.relativePath.split(separator: "/").map(String.init)
            guard let name = components.last else { continue }
            do {
                let parent = try root.descendant(Array(components.dropLast()), create: false)
                let data = try parent.read(name, maximumBytes: Self.maximumTemplateFileBytes)
                guard Self.digest(data) == artifact.digest else {
                    preserved.append(artifact.relativePath)
                    continue
                }
                try parent.remove(name, expectedContents: data, maximumBytes: Self.maximumTemplateFileBytes)
            } catch AnchoredFileMutationError.missingFile {
                continue
            } catch {
                preserved.append(artifact.relativePath)
            }
        }

        let directoryPaths = Set(receipt.plan.artifacts.flatMap { artifact -> [String] in
            let components = artifact.relativePath.split(separator: "/").map(String.init)
            guard components.count > 1 else { return [] }
            return (1..<components.count).map { components.prefix($0).joined(separator: "/") }
        })
        for path in directoryPaths.sorted(by: {
            $0.split(separator: "/").count > $1.split(separator: "/").count
        }) {
            let components = path.split(separator: "/").map(String.init)
            guard let name = components.last,
                  let parent = try? root.descendant(Array(components.dropLast()), create: false) else { continue }
            _ = unlinkat(parent.descriptor, name, AT_REMOVEDIR)
        }

        preserved.append(contentsOf: Self.remainingUserPaths(at: receipt.placement.rootURL))
        let unique = Array(Set(preserved)).sorted()
        return unique.isEmpty ? .removed : .preservedChanges(relativePaths: unique)
    }

    private func render(
        selection: ProjectTemplateSelection,
        projectName: String
    ) throws -> RenderedTemplate {
        guard let descriptor = ProjectTemplateCatalog.builtIn.first(where: { $0.id == selection.id }) else {
            throw GobyApplicationError.unknownProjectTemplate(selection.id)
        }
        guard descriptor.version == selection.version else {
            throw GobyApplicationError.incompatibleProjectTemplateVersion(selection.id, selection.version)
        }
        let normalizedSelection = try normalized(selection, descriptor: descriptor)
        let manifest = try loadManifest(for: descriptor)
        let tokens = tokenValues(
            selection: normalizedSelection,
            projectName: projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            descriptor: descriptor
        )

        var files: [RenderedFile] = []
        var seenPaths = Set<String>()
        var totalBytes = 0
        for entry in manifest.files {
            let sourceURL = try sourceURL(entry.source, templateID: descriptor.id)
            let data = try boundedData(at: sourceURL, maximumBytes: Self.maximumTemplateFileBytes)
            guard let text = String(data: data, encoding: .utf8) else {
                throw GobyApplicationError.invalidProjectTemplateParameters("a bundled template file is not UTF-8 text")
            }
            let path = Self.replacingTokens(in: entry.destination, values: tokens)
            guard Self.isSafeRelativePath(path), seenPaths.insert(path).inserted else {
                throw GobyApplicationError.invalidProjectTemplateParameters("the bundled template contains an unsafe or duplicate path")
            }
            let renderedData = Data(Self.replacingTokens(in: text, values: tokens).utf8)
            totalBytes += renderedData.count
            guard totalBytes <= Self.maximumTemplateBytes else {
                throw GobyApplicationError.invalidProjectTemplateParameters("the bundled template exceeds the scaffold size limit")
            }
            files.append(RenderedFile(
                relativePath: path,
                data: renderedData,
                digest: Self.digest(renderedData)
            ))
        }

        let artifacts = files.map {
            ProjectTemplateArtifact(relativePath: $0.relativePath, digest: $0.digest)
        }.sorted { $0.relativePath < $1.relativePath }
        let plan = ProjectTemplatePlan(
            descriptor: descriptor,
            selection: normalizedSelection,
            artifacts: artifacts,
            frameworks: descriptor.frameworks,
            testCommands: manifest.testCommands.map { Self.replacingTokens(in: $0, values: tokens) },
            instructionRelativePaths: manifest.instructionRelativePaths.map {
                Self.replacingTokens(in: $0, values: tokens)
            }
        )
        return RenderedTemplate(plan: plan, files: files)
    }

    private func normalized(
        _ selection: ProjectTemplateSelection,
        descriptor: ProjectTemplateDescriptor
    ) throws -> ProjectTemplateSelection {
        let expected = Set(descriptor.parameters.map(\.id))
        guard Set(selection.parameters.keys) == expected else {
            throw GobyApplicationError.invalidProjectTemplateParameters("complete only the options shown for this template")
        }
        var values: [ProjectTemplateParameterID: String] = [:]
        for parameter in descriptor.parameters {
            let rawValue = selection.parameters[parameter.id] ?? ""
            guard let value = ProjectTemplateCatalog.normalizedParameterValue(
                rawValue,
                kind: parameter.kind
            ) else {
                let guidance = parameter.kind == .swiftIdentifier
                    ? "enter a Swift module name using letters and numbers"
                    : "enter a valid reverse-DNS bundle identifier"
                throw GobyApplicationError.invalidProjectTemplateParameters(guidance)
            }
            values[parameter.id] = value
        }
        return ProjectTemplateSelection(id: selection.id, version: selection.version, parameters: values)
    }

    private func loadManifest(for descriptor: ProjectTemplateDescriptor) throws -> Manifest {
        let url = resourceRoot
            .appending(path: descriptor.id.rawValue, directoryHint: .isDirectory)
            .appending(path: "manifest.json")
        let data = try boundedData(at: url, maximumBytes: Self.maximumManifestBytes)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.id == descriptor.id else {
            throw GobyApplicationError.unknownProjectTemplate(descriptor.id)
        }
        guard manifest.version == descriptor.version else {
            throw GobyApplicationError.incompatibleProjectTemplateVersion(manifest.id, manifest.version)
        }
        guard !manifest.files.isEmpty, manifest.files.count <= 256 else {
            throw GobyApplicationError.invalidProjectTemplateParameters("the bundled template manifest is empty or too large")
        }
        return manifest
    }

    private func sourceURL(_ source: String, templateID: ProjectTemplateID) throws -> URL {
        let base: URL
        let relative: String
        if source.contains("/") {
            base = resourceRoot
            relative = source
        } else {
            base = resourceRoot.appending(path: templateID.rawValue, directoryHint: .isDirectory)
            relative = source
        }
        guard Self.isSafeRelativePath(relative) else {
            throw GobyApplicationError.invalidProjectTemplateParameters("the bundled template references an unsafe resource")
        }
        let result = base.appending(path: relative).standardizedFileURL
        guard Self.isDescendant(result, of: base) else {
            throw GobyApplicationError.invalidProjectTemplateParameters("the bundled template resource escaped its signed catalog")
        }
        return result
    }

    private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= maximumBytes else {
            throw GobyApplicationError.invalidProjectTemplateParameters("a bundled template resource is missing or exceeds its size limit")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumBytes else {
            throw GobyApplicationError.invalidProjectTemplateParameters("a bundled template resource exceeds its size limit")
        }
        return data
    }

    private func tokenValues(
        selection: ProjectTemplateSelection,
        projectName: String,
        descriptor: ProjectTemplateDescriptor
    ) -> [String: String] {
        let bundleIdentifier = selection.parameters[.bundleIdentifier] ?? ""
        let debugBuildSettings: String
        let releaseBuildSettings: String
        let uiTestDebugBuildSettings: String
        let uiTestReleaseBuildSettings: String
        let moduleName = selection.parameters[.moduleName] ?? ""
        switch descriptor.kind {
        case .iOSApp:
            debugBuildSettings = "CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; IPHONEOS_DEPLOYMENT_TARGET = 26.0; MARKETING_VERSION = 1.0; PRODUCT_BUNDLE_IDENTIFIER = \(bundleIdentifier); PRODUCT_NAME = \"$(TARGET_NAME)\"; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\"; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; TARGETED_DEVICE_FAMILY = \"1,2\";"
            releaseBuildSettings = debugBuildSettings + " VALIDATE_PRODUCT = YES;"
            uiTestDebugBuildSettings = "CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 26.0; PRODUCT_BUNDLE_IDENTIFIER = \(bundleIdentifier).UITests; PRODUCT_NAME = \"$(TARGET_NAME)\"; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\"; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; TARGETED_DEVICE_FAMILY = \"1,2\"; TEST_TARGET_NAME = \(moduleName);"
            uiTestReleaseBuildSettings = uiTestDebugBuildSettings
        case .macOSApp:
            debugBuildSettings = "CODE_SIGN_STYLE = Automatic; COMBINE_HIDPI_IMAGES = YES; CURRENT_PROJECT_VERSION = 1; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_LSApplicationCategoryType = \"public.app-category.productivity\"; MACOSX_DEPLOYMENT_TARGET = 26.0; MARKETING_VERSION = 1.0; PRODUCT_BUNDLE_IDENTIFIER = \(bundleIdentifier); PRODUCT_NAME = \"$(TARGET_NAME)\"; SDKROOT = macosx; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0;"
            releaseBuildSettings = debugBuildSettings + " VALIDATE_PRODUCT = YES;"
            uiTestDebugBuildSettings = "CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = YES; MACOSX_DEPLOYMENT_TARGET = 26.0; PRODUCT_BUNDLE_IDENTIFIER = \(bundleIdentifier).UITests; PRODUCT_NAME = \"$(TARGET_NAME)\"; SDKROOT = macosx; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; TEST_TARGET_NAME = \(moduleName);"
            uiTestReleaseBuildSettings = uiTestDebugBuildSettings
        case .swiftPackage:
            debugBuildSettings = ""
            releaseBuildSettings = ""
            uiTestDebugBuildSettings = ""
            uiTestReleaseBuildSettings = ""
        }
        return [
            "__MODULE_NAME__": moduleName,
            "__BUNDLE_IDENTIFIER__": bundleIdentifier,
            "__PROJECT_NAME__": projectName,
            "__APP_DEBUG_BUILD_SETTINGS__": debugBuildSettings,
            "__APP_RELEASE_BUILD_SETTINGS__": releaseBuildSettings,
            "__UI_TEST_DEBUG_BUILD_SETTINGS__": uiTestDebugBuildSettings,
            "__UI_TEST_RELEASE_BUILD_SETTINGS__": uiTestReleaseBuildSettings,
        ]
    }

    private static func replacingTokens(in value: String, values: [String: String]) -> String {
        values.reduce(value) { result, pair in
            result.replacingOccurrences(of: pair.key, with: pair.value)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains(":") && !value.contains("\0")
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains(":") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            isSafePathComponent(String($0))
        }
    }

    private static func isDescendant(_ child: URL, of root: URL) -> Bool {
        let rawRootPath = root.standardizedFileURL.path(percentEncoded: false)
        let rootPath = rawRootPath.count > 1 && rawRootPath.hasSuffix("/")
            ? String(rawRootPath.dropLast())
            : rawRootPath
        let childPath = child.standardizedFileURL.path(percentEncoded: false)
        return childPath.hasPrefix(rootPath + "/")
    }

    private static func matches(_ identity: GADFileSystemIdentity, descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0
            && info.st_mode & S_IFMT == S_IFDIR
            && UInt64(info.st_dev) == identity.device
            && UInt64(info.st_ino) == identity.inode
            && identity.kind == .directory
    }

    private static func remainingUserPaths(at root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        let rootPath = root.path(percentEncoded: false)
        var paths: [String] = []
        for case let url as URL in enumerator {
            let path = url.path(percentEncoded: false)
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            guard relative != ".codex", !relative.hasPrefix(".codex/") else { continue }
            paths.append(relative)
        }
        return paths
    }
}
