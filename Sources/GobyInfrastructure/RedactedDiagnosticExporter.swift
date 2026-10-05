import Foundation
import GobyApplication
import GobyDomain

public actor RedactedDiagnosticExporter: DiagnosticExporting {
    private struct Report: Codable {
        let schemaVersion: Int
        let generatedAt: Date
        let application: String
        let operatingSystem: String
        let projects: [Project]
        let agents: [Agent]
        let runs: [Run]
        let health: [Health]
    }

    private struct Project: Codable {
        let id: String
        let platforms: [String]
        let isGitRepository: Bool
    }

    private struct Agent: Codable {
        let id: String
        let capabilities: [String]
        let enabled: Bool
    }

    private struct Run: Codable {
        let id: String
        let status: String
        let assignmentCount: Int
        let hasOutcome: Bool
        let updatedAt: Date
    }

    private struct Health: Codable {
        let kind: String
        let status: String
    }

    private let encoder: JSONEncoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public func report(lab: LabSnapshot, runs: [RunRecord], health: SystemHealthSnapshot) throws -> String {
        let report = Report(
            schemaVersion: 1,
            generatedAt: .now,
            application: "Goby Agentic Dashboard 0.2.0-beta.1",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            projects: lab.projects.map {
                Project(
                    id: $0.id.rawValue,
                    platforms: $0.platforms.map(\.rawValue).sorted(),
                    isGitRepository: $0.isGitRepository
                )
            },
            agents: lab.agents.map {
                Agent(
                    id: $0.id.rawValue,
                    capabilities: $0.capabilities.map(\.rawValue).sorted(),
                    enabled: $0.isEnabled
                )
            },
            runs: runs.prefix(50).map {
                Run(
                    id: $0.id.rawValue,
                    status: $0.status.rawValue,
                    assignmentCount: $0.assignments.count,
                    hasOutcome: $0.outcome != nil,
                    updatedAt: $0.updatedAt
                )
            },
            health: health.checks.map {
                Health(
                    kind: $0.kind.rawValue,
                    status: $0.status.rawValue
                )
            }
        )
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

}
