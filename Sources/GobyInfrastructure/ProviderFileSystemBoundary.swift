import Foundation
import GobyDomain

enum ProviderBridgeProtocol {
    static let current = "1.1"

    static func accepts(_ version: String) -> Bool {
        version == current
    }
}

/// Exact integer representation used across the Swift/JavaScript provider boundary.
/// Device and inode are strings because JavaScript numbers cannot represent every UInt64.
struct ProviderFileSystemIdentityPayload: Codable, Equatable, Sendable {
    let device: String
    let inode: String
    let kind: String

    init(_ identity: GADFileSystemIdentity) {
        device = String(identity.device)
        inode = String(identity.inode)
        kind = identity.kind.rawValue
    }
}

struct ProviderLocalAttachmentPayload: Codable, Equatable, Sendable {
    let id: String
    let path: String
    let displayName: String
    let kind: String
    let identity: ProviderFileSystemIdentityPayload
    let contentSHA256: String

    init?(_ attachment: PromptAttachment) {
        guard case let .localFile(url) = attachment.source,
              let fileSystemIdentity = attachment.fileSystemIdentity,
              fileSystemIdentity.kind == .regularFile,
              let contentSHA256 = attachment.contentSHA256 else {
            return nil
        }
        id = attachment.id.uuidString.lowercased()
        path = url.path(percentEncoded: false)
        displayName = attachment.displayName
        kind = attachment.kind.rawValue
        identity = ProviderFileSystemIdentityPayload(fileSystemIdentity)
        self.contentSHA256 = contentSHA256
    }
}

enum ProviderFileSystemBoundaryError: LocalizedError, Equatable, Sendable {
    case missingDirectoryIdentity(String)
    case missingAttachmentIdentity(String)

    var errorDescription: String? {
        switch self {
        case let .missingDirectoryIdentity(label):
            "The reviewed file-system identity for \(label) is missing or is not a directory. Reauthorize it before provider use."
        case let .missingAttachmentIdentity(label):
            "The reviewed identity or content digest for attachment \(label) is missing. Add it again before provider use."
        }
    }
}

enum ProviderFileSystemBoundary {
    static func directoryIdentity(
        _ identity: GADFileSystemIdentity?,
        label: String
    ) throws -> ProviderFileSystemIdentityPayload {
        guard let identity, identity.kind == .directory else {
            throw ProviderFileSystemBoundaryError.missingDirectoryIdentity(label)
        }
        return ProviderFileSystemIdentityPayload(identity)
    }

    static func localAttachments(
        _ attachments: [PromptAttachment]
    ) throws -> [ProviderLocalAttachmentPayload] {
        try attachments.compactMap { attachment in
            guard case .localFile = attachment.source else { return nil }
            guard let payload = ProviderLocalAttachmentPayload(attachment) else {
                throw ProviderFileSystemBoundaryError.missingAttachmentIdentity(attachment.displayName)
            }
            return payload
        }
    }
}
