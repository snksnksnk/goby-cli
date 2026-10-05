import Foundation

public enum PromptAttachmentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case file
    case image
    case snippet
}

public enum PromptAttachmentSource: Codable, Hashable, Sendable {
    case localFile(URL)
    case text(String)
}

/// User-selected context that travels with one composed request.
///
/// A missing source represents a redacted reference received from a remote
/// projection. The authoritative Mac host retains the source for matching IDs.
public struct PromptAttachment: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let kind: PromptAttachmentKind
    public let displayName: String
    public let source: PromptAttachmentSource?
    public let byteCount: Int?
    public let typeHint: String?
    public let fileSystemIdentity: GADFileSystemIdentity?
    public let contentSHA256: String?

    public init(
        id: UUID = UUID(),
        kind: PromptAttachmentKind,
        displayName: String,
        source: PromptAttachmentSource?,
        byteCount: Int? = nil,
        typeHint: String? = nil,
        fileSystemIdentity: GADFileSystemIdentity? = nil,
        contentSHA256: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = String(displayName.prefix(240))
        self.source = source
        self.byteCount = byteCount.map { max(0, $0) }
        self.typeHint = typeHint.map { String($0.prefix(80)) }
        if case let .localFile(url) = source {
            self.fileSystemIdentity = fileSystemIdentity ?? GADFileSystemIdentity.capture(url)
            self.contentSHA256 = contentSHA256 ?? GADFileSystemIdentity.contentSHA256(at: url)
        } else {
            self.fileSystemIdentity = nil
            self.contentSHA256 = nil
        }
    }

    public func redactedReference() -> PromptAttachment {
        PromptAttachment(
            id: id,
            kind: kind,
            displayName: displayName,
            source: nil,
            byteCount: byteCount,
            typeHint: typeHint,
            fileSystemIdentity: fileSystemIdentity,
            contentSHA256: contentSHA256
        )
    }
}
