import Foundation
import GobyDomain

public enum GADRunDeliveryKind: String, Codable, Sendable { case commit, push }

/// A one-use review of one finished run's exact working copy. No shell text.
public struct GADRunDeliveryPreview: Codable, Equatable, Sendable {
    public let id: String
    public let digest: String
    public let kind: GADRunDeliveryKind
    public let projectName: String
    public let branch: String
    public let remote: String?
    public let summary: String
    public let expiresAt: Date
    public init(id: String, digest: String, kind: GADRunDeliveryKind, projectName: String,
                branch: String, remote: String?, summary: String, expiresAt: Date) {
        self.id = id; self.digest = digest; self.kind = kind; self.projectName = projectName
        self.branch = branch; self.remote = remote; self.summary = summary; self.expiresAt = expiresAt
    }
}
