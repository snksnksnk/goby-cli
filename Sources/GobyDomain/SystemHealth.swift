import Foundation

public enum HealthCheckStatus: String, Codable, Sendable {
    case passed
    case warning
    case failed
}

public enum HealthCheckKind: String, Codable, CaseIterable, Sendable {
    case operatingSystem
    case codex
    case appServerProtocol
    case authentication
    case git
    case xcode
    case storage
    case projectRoots

    public var displayName: String {
        switch self {
        case .operatingSystem: "macOS"
        case .codex: "Codex"
        case .appServerProtocol: "App Server protocol"
        case .authentication: "Authentication"
        case .git: "Git"
        case .xcode: "Xcode"
        case .storage: "Local storage"
        case .projectRoots: "Project roots"
        }
    }
}

public struct HealthCheck: Codable, Hashable, Identifiable, Sendable {
    public let kind: HealthCheckKind
    public let status: HealthCheckStatus
    public let summary: String
    public let detail: String?
    public var id: HealthCheckKind { kind }

    public init(kind: HealthCheckKind, status: HealthCheckStatus, summary: String, detail: String? = nil) {
        self.kind = kind
        self.status = status
        self.summary = summary
        self.detail = detail
    }
}

public struct SystemHealthSnapshot: Codable, Equatable, Sendable {
    public let checks: [HealthCheck]
    public let checkedAt: Date

    public init(checks: [HealthCheck], checkedAt: Date = .now) {
        self.checks = checks
        self.checkedAt = checkedAt
    }

    public var hasFailures: Bool { checks.contains { $0.status == .failed } }
}
