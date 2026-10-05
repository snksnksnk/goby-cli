import CryptoKit
import Foundation

public actor GADHostAdminPreviewVault {
    private struct HashMaterial: Codable, Sendable {
        let id: String
        let request: GADHostAdminRequest
        let deviceID: DeviceID
        let baseRevision: StateRevision
        let reviewStateDigest: String?
        let expiresAt: Date
        let requiresLocalAuthentication: Bool
        let effects: [GADHostAdminEffect]
    }

    private struct Record: Sendable {
        let request: GADHostAdminRequest
        let deviceID: DeviceID
        let operationClass: String
        let encodedBytes: Int
        let baseRevision: StateRevision
        let reviewStateDigest: String?
        let preview: GADHostAdminPreview
    }

    private static let maximumRequestBytes = 256 * 1_024
    private static let maximumRecordsPerDevice = 4
    private static let maximumRecords = 32
    private static let maximumRetainedBytes = 4 * 1_024 * 1_024

    private let now: @Sendable () -> Date
    private var records: [String: Record] = [:]

    public init(now: @escaping @Sendable () -> Date = { .now }) {
        self.now = now
    }

    public func issue(
        request: GADHostAdminRequest,
        deviceID: DeviceID,
        baseRevision: StateRevision,
        effects: [GADHostAdminEffect],
        requiresLocalAuthentication: Bool,
        reviewStateDigest: String? = nil,
        lifetime: TimeInterval = 120
    ) throws -> GADHostAdminPreview {
        discardExpired()
        let requestBytes = try Self.encodedSize(of: request)
        guard requestBytes <= Self.maximumRequestBytes else {
            throw GADCommandFailure(.rejectedPolicy, "This administration request is too large to review safely.")
        }
        let operationClass = Self.operationClass(for: request)
        records = records.filter {
            !($0.value.deviceID == deviceID && $0.value.operationClass == operationClass)
        }
        guard records.values.filter({ $0.deviceID == deviceID }).count < Self.maximumRecordsPerDevice,
              records.count < Self.maximumRecords,
              records.values.reduce(0, { $0 + $1.encodedBytes }) + requestBytes <= Self.maximumRetainedBytes else {
            throw GADCommandFailure(.failedRecoverable, "Too many administration previews are active. Finish or wait for an earlier review, then try again.")
        }
        let id = UUID().uuidString.lowercased()
        let expiresAt = now().addingTimeInterval(max(10, min(lifetime, 300)))
        let material = HashMaterial(
            id: id,
            request: request,
            deviceID: deviceID,
            baseRevision: baseRevision,
            reviewStateDigest: reviewStateDigest,
            expiresAt: expiresAt,
            requiresLocalAuthentication: requiresLocalAuthentication,
            effects: effects
        )
        let preview = GADHostAdminPreview(
            id: id,
            hash: try Self.hash(material),
            expiresAt: expiresAt,
            requiresLocalAuthentication: requiresLocalAuthentication,
            effects: effects
        )
        records[id] = Record(
            request: request,
            deviceID: deviceID,
            operationClass: operationClass,
            encodedBytes: requestBytes,
            baseRevision: baseRevision,
            reviewStateDigest: reviewStateDigest,
            preview: preview
        )
        return preview
    }

    public func consume(
        _ commit: GADHostAdminCommit,
        deviceID: DeviceID,
        currentRevision: StateRevision,
        currentReviewStateDigest: String? = nil
    ) throws -> GADHostAdminRequest {
        guard let record = records[commit.previewID] else {
            throw GADCommandFailure(.rejectedExpired, "This administration preview expired or was already used.")
        }
        guard record.preview.expiresAt >= now() else {
            records.removeValue(forKey: commit.previewID)
            throw GADCommandFailure(.rejectedExpired, "This administration preview expired. Review the operation again.")
        }
        guard record.preview.hash == commit.previewHash else {
            records.removeValue(forKey: commit.previewID)
            throw GADCommandFailure(.rejectedPolicy, "The administration preview did not match the reviewed operation.")
        }
        guard record.deviceID == deviceID else {
            records.removeValue(forKey: commit.previewID)
            throw GADCommandFailure(.rejectedPolicy, "This administration preview belongs to another paired device.")
        }
        let reviewStateMatches = if let reviewStateDigest = record.reviewStateDigest {
            reviewStateDigest == currentReviewStateDigest
        } else {
            record.baseRevision == currentRevision
        }
        guard reviewStateMatches else {
            records.removeValue(forKey: commit.previewID)
            throw GADCommandFailure(.rejectedStale, "Goby changed after this preview. Review the refreshed effects.")
        }
        if record.preview.requiresLocalAuthentication,
           commit.authorizationAssertion?.isEmpty != false {
            throw GADCommandFailure(.rejectedPolicy, "Device-owner authentication is required for this operation.")
        }
        records.removeValue(forKey: commit.previewID)
        return record.request
    }

    private func discardExpired() {
        let timestamp = now()
        records = records.filter { $0.value.preview.expiresAt >= timestamp }
    }

    private static func hash(_ material: HashMaterial) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let digest = SHA256.hash(data: try encoder.encode(material))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func encodedSize(of request: GADHostAdminRequest) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request).count
    }

    private static func operationClass(for request: GADHostAdminRequest) -> String {
        switch request {
        case .createProject: "create-project"
        case .removeProject: "remove-project"
        case .syncCodexCatalog: "sync-codex-catalog"
        case .importAgents: "import-agents"
        case .saveAgent: "save-agent"
        case .createTemporaryAgent: "create-temporary-agent"
        case .retireTemporaryAgent: "retire-temporary-agent"
        case .addMissingAutomationAgents: "add-missing-automation-agents"
        case .setAgentEnabled: "set-agent-enabled"
        case .publishAgent: "publish-agent"
        case .deleteAgent: "delete-agent"
        case .restoreLastDeletedAgent: "restore-agent"
        case .restructureAgents: "restructure-agents"
        case .undoLastAgentRestructure: "undo-agent-restructure"
        case .setResourceAccess: "resource-access"
        case .switchProjectBranch: "switch-project-branch"
        case .exportRedactedDiagnostics: "export-diagnostics"
        }
    }
}
