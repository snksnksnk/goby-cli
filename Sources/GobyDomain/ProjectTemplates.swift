import Foundation

public enum ProjectTemplateKind: String, Codable, CaseIterable, Hashable, Sendable {
    case iOSApp
    case macOSApp
    case swiftPackage

    public var displayName: String {
        switch self {
        case .iOSApp: "iOS App"
        case .macOSApp: "macOS App"
        case .swiftPackage: "Swift Package"
        }
    }
}

public enum ProjectTemplateParameterID: String, Codable, CaseIterable, Hashable, Sendable {
    case moduleName
    case bundleIdentifier
}

public enum ProjectTemplateParameterKind: String, Codable, Hashable, Sendable {
    case swiftIdentifier
    case bundleIdentifier
}

public struct ProjectTemplateParameterDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: ProjectTemplateParameterID
    public let label: String
    public let help: String
    public let kind: ProjectTemplateParameterKind

    public init(
        id: ProjectTemplateParameterID,
        label: String,
        help: String,
        kind: ProjectTemplateParameterKind
    ) {
        self.id = id
        self.label = label
        self.help = help
        self.kind = kind
    }
}

public struct ProjectTemplateAgentSuggestion: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let instructions: String
    public let capabilities: Set<AgentCapability>

    public init(
        id: String,
        name: String,
        summary: String,
        instructions: String,
        capabilities: Set<AgentCapability>
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.capabilities = capabilities
    }
}

public struct ProjectTemplateDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: ProjectTemplateID
    public let version: Int
    public let kind: ProjectTemplateKind
    public let name: String
    public let summary: String
    public let platforms: Set<ProjectPlatform>
    public let frameworks: [String]
    public let artifactCount: Int
    public let parameters: [ProjectTemplateParameterDescriptor]
    public let suggestedAgents: [ProjectTemplateAgentSuggestion]

    public init(
        id: ProjectTemplateID,
        version: Int,
        kind: ProjectTemplateKind,
        name: String,
        summary: String,
        platforms: Set<ProjectPlatform>,
        frameworks: [String],
        artifactCount: Int,
        parameters: [ProjectTemplateParameterDescriptor],
        suggestedAgents: [ProjectTemplateAgentSuggestion] = []
    ) {
        self.id = id
        self.version = version
        self.kind = kind
        self.name = name
        self.summary = summary
        self.platforms = platforms
        self.frameworks = frameworks
        self.artifactCount = artifactCount
        self.parameters = parameters
        self.suggestedAgents = suggestedAgents
    }
}

public struct ProjectTemplateSelection: Codable, Equatable, Hashable, Sendable {
    public let id: ProjectTemplateID
    public let version: Int
    public let parameters: [ProjectTemplateParameterID: String]

    public init(
        id: ProjectTemplateID,
        version: Int,
        parameters: [ProjectTemplateParameterID: String]
    ) {
        self.id = id
        self.version = version
        self.parameters = parameters
    }
}

public struct ProjectTemplateReference: Codable, Equatable, Hashable, Sendable {
    public let id: ProjectTemplateID
    public let version: Int

    public init(id: ProjectTemplateID, version: Int) {
        self.id = id
        self.version = version
    }
}

public enum ProjectTemplateCatalog {
    private static let reservedSwiftIdentifiers: Set<String> = [
        "Any", "Self", "actor", "any", "as", "associatedtype", "async", "await",
        "borrowing", "break", "case", "catch", "class", "consuming", "continue",
        "default", "defer", "deinit", "distributed", "do", "each", "else", "enum",
        "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard",
        "if", "import", "in", "init", "inout", "internal", "is", "isolated", "let",
        "macro", "nil", "nonisolated", "open", "operator", "package", "private",
        "protocol", "public", "repeat", "rethrows", "return", "self", "sending",
        "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
        "true", "try", "typealias", "var", "where", "while",
    ]

    public static let moduleNameParameter = ProjectTemplateParameterDescriptor(
        id: .moduleName,
        label: "Module name",
        help: "A Swift identifier used for targets, modules, and generated type names.",
        kind: .swiftIdentifier
    )

    public static let bundleIdentifierParameter = ProjectTemplateParameterDescriptor(
        id: .bundleIdentifier,
        label: "Bundle identifier",
        help: "A reverse-DNS identifier such as com.example.MyApp.",
        kind: .bundleIdentifier
    )

    public static let builtIn: [ProjectTemplateDescriptor] = [
        ProjectTemplateDescriptor(
            id: "ios-swiftui-clean",
            version: 1,
            kind: .iOSApp,
            name: "iOS App",
            summary: "SwiftUI app with strict Swift 6 concurrency and Clean Architecture modules.",
            platforms: [.iOS],
            frameworks: ["SwiftUI", "Swift Package", "Xcode"],
            artifactCount: 15,
            parameters: [moduleNameParameter, bundleIdentifierParameter],
            suggestedAgents: [
                ProjectTemplateAgentSuggestion(
                    id: "ios-engineer",
                    name: "iOS Engineer",
                    summary: "Builds the SwiftUI application while preserving the inward architecture boundaries.",
                    instructions: "Use Swift 6 strict concurrency, @Observable @MainActor presentation state, immutable Sendable domain models, actors for shared mutable state, Swift Testing for unit tests, and XCTest only for UI automation.",
                    capabilities: [.iOS, .testing, .design]
                )
            ]
        ),
        ProjectTemplateDescriptor(
            id: "macos-swiftui-clean",
            version: 1,
            kind: .macOSApp,
            name: "macOS App",
            summary: "Native SwiftUI macOS app with strict Swift 6 concurrency and Clean Architecture modules.",
            platforms: [.macOS],
            frameworks: ["SwiftUI", "Swift Package", "Xcode"],
            artifactCount: 15,
            parameters: [moduleNameParameter, bundleIdentifierParameter],
            suggestedAgents: [
                ProjectTemplateAgentSuggestion(
                    id: "macos-engineer",
                    name: "macOS Engineer",
                    summary: "Builds the native macOS app and its accessible desktop workflows.",
                    instructions: "Use native SwiftUI, Swift 6 strict concurrency, @Observable @MainActor presentation state, actors for shared mutable state, and preserve keyboard and accessibility behavior.",
                    capabilities: [.macOS, .testing, .design]
                )
            ]
        ),
        ProjectTemplateDescriptor(
            id: "swift-package-clean",
            version: 1,
            kind: .swiftPackage,
            name: "Swift Package",
            summary: "Portable Swift package split into Domain, Application, and Infrastructure libraries.",
            platforms: [.general],
            frameworks: ["Swift Package"],
            artifactCount: 9,
            parameters: [moduleNameParameter],
            suggestedAgents: [
                ProjectTemplateAgentSuggestion(
                    id: "swift-engineer",
                    name: "Swift Engineer",
                    summary: "Builds and tests the package while preserving its module boundaries.",
                    instructions: "Use Swift 6 strict concurrency, immutable Sendable domain models, actor-isolated infrastructure, explicit dependency injection, and Swift Testing.",
                    capabilities: [.backend, .testing, .documentation]
                )
            ]
        )
    ]

    public static func descriptor(for id: ProjectTemplateID, version: Int) -> ProjectTemplateDescriptor? {
        builtIn.first { $0.id == id && $0.version == version }
    }

    /// Returns the canonical value stored in project metadata, or `nil` when
    /// the value cannot be substituted safely into a bundled template.
    public static func normalizedParameterValue(
        _ value: String,
        kind: ProjectTemplateParameterKind
    ) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .swiftIdentifier:
            guard (1...64).contains(normalized.utf8.count),
                  !reservedSwiftIdentifiers.contains(normalized),
                  let first = normalized.utf8.first,
                  first == 95 || (65...90).contains(first) || (97...122).contains(first),
                  normalized.utf8.dropFirst().allSatisfy({
                      $0 == 95 || (48...57).contains($0)
                          || (65...90).contains($0) || (97...122).contains($0)
                  }) else { return nil }
        case .bundleIdentifier:
            let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
            guard normalized.utf8.count <= 255, components.count >= 2,
                  components.allSatisfy({ component in
                      guard !component.isEmpty,
                            let first = component.utf8.first,
                            let last = component.utf8.last,
                            first != 45, last != 45 else { return false }
                      return component.utf8.allSatisfy {
                          $0 == 45 || (48...57).contains($0)
                              || (65...90).contains($0) || (97...122).contains($0)
                      }
                  }) else { return nil }
        }
        return normalized
    }
}
