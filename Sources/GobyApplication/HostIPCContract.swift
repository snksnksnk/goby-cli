import Foundation
import GobyDomain

/// Local UI-to-host protocol. This is intentionally narrower than the remote
/// continuity wire format and never exposes repository, shell, Git or provider
/// JSON-RPC operations.
public enum GADHostIPCOperation: Codable, Equatable, Sendable {
    case ping
    case connect(DeviceID)
    case snapshot(DeviceID)
    case send(GADCommand)
    case events(GADHostIPCEventRequest)
    case disconnect(DeviceID)
    case remoteAccessSnapshot
    case remoteAccessCommand(GADHostRemoteAccessCommand)
    case localAdministration(GADHostLocalCommand)
}

public enum GADHostRemoteAccessPhase: String, Codable, Equatable, Sendable {
    case disabled
    case starting
    case waitingForDevice
    case confirmingDevice
    case listening
    case failed
}

public struct GADHostPairedDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public let isConnected: Bool
    public let requiresRepair: Bool

    public init(
        id: String,
        name: String,
        createdAt: Date,
        isConnected: Bool,
        requiresRepair: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.isConnected = isConnected
        self.requiresRepair = requiresRepair
    }
}

public struct GADHostRemoteAccessSnapshot: Codable, Equatable, Sendable {
    public let relayURLText: String
    public let phase: GADHostRemoteAccessPhase
    public let failureMessage: String?
    public let pairingLink: String?
    public let pairingExpiresAt: Date?
    public let pairedDeviceName: String?
    public let pairedDevices: [GADHostPairedDevice]
    public let pairingConfirmationCode: String?
    public let pendingPairingDeviceName: String?
    public let hasRelayAdmissionCredential: Bool
    public let relayAdmissionExpiresAt: Date?

    public init(
        relayURLText: String,
        phase: GADHostRemoteAccessPhase,
        failureMessage: String? = nil,
        pairingLink: String? = nil,
        pairingExpiresAt: Date? = nil,
        pairedDeviceName: String? = nil,
        pairedDevices: [GADHostPairedDevice] = [],
        pairingConfirmationCode: String? = nil,
        pendingPairingDeviceName: String? = nil,
        hasRelayAdmissionCredential: Bool = false,
        relayAdmissionExpiresAt: Date? = nil
    ) {
        self.relayURLText = relayURLText
        self.phase = phase
        self.failureMessage = failureMessage
        self.pairingLink = pairingLink
        self.pairingExpiresAt = pairingExpiresAt
        self.pairedDeviceName = pairedDeviceName
        self.pairedDevices = pairedDevices
        self.pairingConfirmationCode = pairingConfirmationCode
        self.pendingPairingDeviceName = pendingPairingDeviceName
        self.hasRelayAdmissionCredential = hasRelayAdmissionCredential
        self.relayAdmissionExpiresAt = relayAdmissionExpiresAt
    }
}

public enum GADHostRemoteAccessCommand: Codable, Equatable, Sendable {
    case enable(relayURLText: String)
    case disable
    case generatePairingCode(relayURLText: String)
    case renameDevice(id: String, name: String)
    case revokeDevice(id: String)
    case revokeAllDevices
    case resolvePairingConfirmation(accepted: Bool)
}

public struct GADHostLocalProjectCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: ProjectID
    public let name: String
    public let rootURL: URL?
    public let platforms: [ProjectPlatform]
    public let frameworks: [String]
    public let isGitRepository: Bool
    public let evidence: [String]

    public init(
        id: ProjectID,
        name: String,
        rootURL: URL? = nil,
        platforms: [ProjectPlatform],
        frameworks: [String],
        isGitRepository: Bool,
        evidence: [String]
    ) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.platforms = platforms
        self.frameworks = frameworks
        self.isGitRepository = isGitRepository
        self.evidence = evidence
    }
}

public struct GADHostLocalNewProjectRequest: Codable, Equatable, Sendable {
    public let parentBookmark: Data
    public let source: GADNewProjectSourceIntent?
    public let name: String
    public let directoryName: String
    public let platforms: [ProjectPlatform]
    public let providerIDs: [AgentProviderID]
    public let agents: [GADNewProjectAgentIntent]
    public let link: GADNewProjectLinkIntent?
    public let collaborateAcrossProviders: Bool
    public let handoffLinks: [GADNewProjectHandoffIntent]
    public let template: ProjectTemplateSelection?

    public init(
        parentBookmark: Data,
        source: GADNewProjectSourceIntent? = nil,
        name: String,
        directoryName: String,
        platforms: [ProjectPlatform],
        providerIDs: [AgentProviderID],
        agents: [GADNewProjectAgentIntent],
        link: GADNewProjectLinkIntent?,
        collaborateAcrossProviders: Bool,
        handoffLinks: [GADNewProjectHandoffIntent],
        template: ProjectTemplateSelection? = nil
    ) {
        self.parentBookmark = parentBookmark
        self.source = source
        self.name = name
        self.directoryName = directoryName
        self.platforms = platforms
        self.providerIDs = providerIDs
        self.agents = agents
        self.link = link
        self.collaborateAcrossProviders = collaborateAcrossProviders
        self.handoffLinks = handoffLinks
        self.template = template
    }
}

/// Exact, same-user catalog and shared-resource metadata used only by the signed macOS client.
/// Paired devices continue to receive the path-free `DashboardProjection`.
/// Typed project/agent IDs use that dashboard's opaque namespace so the desktop
/// can attach these authorized local paths and native labels to the same rows.
public struct GADHostLocalCatalogSnapshot: Codable, Equatable, Sendable {
    public let projects: [LabProject]
    public let agents: [AgentProfile]
    public let resources: [SharedResource]
    /// Presentation only; the archive and restore authority remain on the host.
    public let lastDeletedAgentName: String?

    public init(
        projects: [LabProject],
        agents: [AgentProfile],
        resources: [SharedResource] = [],
        lastDeletedAgentName: String? = nil
    ) {
        self.projects = projects
        self.agents = agents
        self.resources = resources
        self.lastDeletedAgentName = lastDeletedAgentName
    }
}

public enum GADHostLocalCommand: Codable, Equatable, Sendable {
    case inspectLocalCatalog
    case inspectLocalRun(RunID)
    /// Bounded, host-read workspace changes for the same-user CLI.
    case inspectLocalRunDiff(RunID)
    case previewRunDelivery(runID: RunID, kind: GADRunDeliveryKind)
    case executeRunDelivery(previewID: String, digest: String)
    case inspectProjectBookmarks([Data])
    case registerProjectBookmarks(bookmarks: [Data], selectedProjectIDs: [ProjectID])
    case registerResourceBookmarks([Data])
    case createProject(GADHostLocalNewProjectRequest)
    case inspectProjectGitBranches(ProjectID)
    case switchProjectGitBranch(ProjectGitBranchSwitchApproval)
    /// Tells the authoritative host to re-read an already changed shared
    /// Keychain item. Credential bytes are deliberately absent from IPC.
    case providerCredentialChanged(providerID: AgentProviderID)
    /// Checkpoints and quiesces the permanent writer before a signed update or
    /// removal unregisters its launch agent. The foreground UI never receives
    /// persistence ownership and this exposes no generic process control.
    case preparePermanentHostShutdown
}

@MainActor
public protocol GADHostLocalAdministrationHandling: Sendable {
    func remoteAccessSnapshot() async -> GADHostRemoteAccessSnapshot
    func applyRemoteAccessCommand(
        _ command: GADHostRemoteAccessCommand
    ) async -> GADHostRemoteAccessSnapshot
    func applyLocalCommand(_ command: GADHostLocalCommand) async throws -> GADHostIPCArtifact
}

public struct GADHostIPCEventRequest: Codable, Equatable, Sendable {
    public static let maximumEventCount = 500

    public let deviceID: DeviceID
    public let afterRevision: StateRevision
    public let maximumCount: Int

    public init(deviceID: DeviceID, afterRevision: StateRevision, maximumCount: Int = 200) {
        self.deviceID = deviceID
        self.afterRevision = afterRevision
        self.maximumCount = min(max(maximumCount, 1), Self.maximumEventCount)
    }
}

public struct GADHostIPCRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion: UInt16 = 13

    public let protocolVersion: UInt16
    public let requestID: UUID
    public let issuedAt: Date
    public let operation: GADHostIPCOperation

    public init(
        protocolVersion: UInt16 = Self.currentProtocolVersion,
        requestID: UUID = UUID(),
        issuedAt: Date = Date(),
        operation: GADHostIPCOperation
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.issuedAt = issuedAt
        self.operation = operation
    }
}

public struct GADHostIPCResponse: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let requestID: UUID
    public let hostVersion: String
    public let generatedAt: Date
    public let isReadOnly: Bool
    public let artifact: GADHostIPCArtifact?
    public let failureDisposition: GADCommandDisposition?
    public let error: String?

    public init(
        protocolVersion: UInt16 = GADHostIPCRequest.currentProtocolVersion,
        requestID: UUID,
        hostVersion: String,
        generatedAt: Date,
        isReadOnly: Bool,
        artifact: GADHostIPCArtifact? = nil,
        failureDisposition: GADCommandDisposition? = nil,
        error: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.hostVersion = hostVersion
        self.generatedAt = generatedAt
        self.isReadOnly = isReadOnly
        self.artifact = artifact
        self.failureDisposition = failureDisposition
        self.error = error
    }
}

/// The app and bundled host are released as one signed unit. Matching the
/// semantic IPC schema is necessary but not sufficient: an older helper with
/// different coordinator behavior must be replaced during an app update.
public enum GADHostIPCVersionPolicy {
    public static func accepts(hostVersion: String, applicationVersion: String) -> Bool {
        let host = hostVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let application = applicationVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return !host.isEmpty && host == application
    }

    /// True when `candidate` is a different debug build of the same marketing
    /// version as `prior`. Release versions never qualify. A rebuilt debug
    /// helper may then restart from the prior helper's retained authority and
    /// checkpoint instead of routing persistence back through the foreground
    /// app for a full one-time transfer.
    public static func isDebugRebuild(_ candidate: String, of prior: String) -> Bool {
        guard candidate != prior,
              let candidateMarketing = debugMarketingVersion(candidate),
              let priorMarketing = debugMarketingVersion(prior) else { return false }
        return candidateMarketing == priorMarketing
    }

    /// True when `candidate` is a strictly newer release than `prior`, using
    /// semantic-version order (a pre-release sorts before its release). The
    /// new helper may then inherit restart authority, but only after taking
    /// a fresh backup and passing the usual checkpoint comparison. Debug
    /// builds and downgrades never qualify.
    public static func isReleaseUpgrade(_ candidate: String, from prior: String) -> Bool {
        guard candidate.range(of: "-debug-") == nil, prior.range(of: "-debug-") == nil,
              let new = SemanticVersion(candidate), let old = SemanticVersion(prior) else { return false }
        return old < new
    }

    private static func debugMarketingVersion(_ version: String) -> String? {
        guard let range = version.range(of: "-debug-") else { return nil }
        let marketing = version[..<range.lowerBound]
        return marketing.isEmpty ? nil : String(marketing)
    }

    /// Debug builds can replace the embedded helper without changing the
    /// marketing or bundle version. Bind compatibility to the exact helper
    /// executable so an already-running pre-build process is restarted before
    /// it can accept commands implemented by older code.
    public static func debugBuildVersion(
        marketingVersion: String,
        executableURL: URL
    ) -> String? {
        let normalized = marketingVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: executableURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
              let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date else { return nil }
        return debugBuildVersion(
            marketingVersion: normalized,
            fileSize: fileSize,
            fileIdentifier: fileIdentifier,
            modificationDate: modificationDate
        )
    }

    public static func debugBuildVersion(
        marketingVersion: String,
        fileSize: UInt64,
        fileIdentifier: UInt64,
        modificationDate: Date
    ) -> String? {
        let normalized = marketingVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, fileSize > 0, fileIdentifier > 0 else { return nil }
        let timestamp = modificationDate.timeIntervalSinceReferenceDate.bitPattern
        return [
            normalized,
            "debug",
            String(fileSize, radix: 16),
            String(fileIdentifier, radix: 16),
            String(timestamp, radix: 16),
        ].joined(separator: "-")
    }
}

public enum GADHostIPCArtifact: Codable, Equatable, Sendable {
    case session(ClientSession)
    case snapshot(DashboardProjection)
    case acknowledgement(GADCommandAcknowledgement)
    case deltas([GADStateDelta])
    case remoteAccess(GADHostRemoteAccessSnapshot)
    case localReceipt(GADOperationReceipt)
    case localProjectCandidates([GADHostLocalProjectCandidate])
    case localCatalog(GADHostLocalCatalogSnapshot)
    case localRun(RunRecord)
    case localRunDiff(String)
    case runDeliveryPreview(GADRunDeliveryPreview)
    case projectGitBranches(ProjectGitBranchSnapshot)
}

public enum GADHostIPCCodecError: Error, Equatable, Sendable {
    case oversized
    case malformed
}

public enum GADHostIPCCodec {
    public static let maximumRequestBytes = 128 * 1_024
    public static let maximumResponseBytes = 2 * 1_024 * 1_024
    /// Compatibility alias for callers that encode request-shaped messages.
    public static let maximumMessageBytes = maximumRequestBytes

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encode(value, maximumBytes: maximumRequestBytes)
    }

    public static func encodeResponse<T: Encodable>(_ value: T) throws -> Data {
        try encode(value, maximumBytes: maximumResponseBytes)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decode(type, from: data, maximumBytes: maximumRequestBytes)
    }

    public static func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decode(type, from: data, maximumBytes: maximumResponseBytes)
    }

    private static func encode<T: Encodable>(_ value: T, maximumBytes: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw GADHostIPCCodecError.oversized }
        return data
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        maximumBytes: Int
    ) throws -> T {
        guard data.count <= maximumBytes else { throw GADHostIPCCodecError.oversized }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GADHostIPCCodecError.malformed
        }
    }
}


/// A `MAJOR.MINOR.PATCH[-pre.release]` version, ordered by semantic-version
/// rules: numeric parts first, then a pre-release before its release, then
/// pre-release identifiers (numeric below alphanumeric).
struct SemanticVersion: Comparable {
    let core: [Int]
    let preRelease: [String]

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutBuild = trimmed.split(separator: "+", maxSplits: 1).first.map(String.init) ?? trimmed
        let parts = withoutBuild.split(separator: "-", maxSplits: 1).map(String.init)
        guard let corePart = parts.first else { return nil }
        let numbers = corePart.split(separator: ".").map { Int($0) }
        guard (1...3).contains(numbers.count), numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        core = numbers.map { $0! } + Array(repeating: 0, count: 3 - numbers.count)
        preRelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        guard preRelease.allSatisfy({ !$0.isEmpty }) else { return nil }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        switch (lhs.preRelease.isEmpty, rhs.preRelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.preRelease, rhs.preRelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.preRelease.count < rhs.preRelease.count
    }
}
