import Foundation

public enum SharedResourceAccess: String, Codable, CaseIterable, Sendable {
    case readOnly
    case readWrite

    public var displayName: String {
        switch self {
        case .readOnly: "Read only"
        case .readWrite: "Read and write"
        }
    }
}

public struct SharedResource: Codable, Hashable, Identifiable, Sendable {
    public let id: SharedResourceID
    public let name: String
    public let url: URL
    public let access: SharedResourceAccess
    public let isEnabled: Bool
    public let registeredAt: Date
    public let fileSystemIdentity: GADFileSystemIdentity?

    public init(
        id: SharedResourceID = .make(),
        name: String,
        url: URL,
        access: SharedResourceAccess = .readOnly,
        isEnabled: Bool = true,
        registeredAt: Date = .now,
        fileSystemIdentity: GADFileSystemIdentity? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.access = access
        self.isEnabled = isEnabled
        self.registeredAt = registeredAt
        self.fileSystemIdentity = fileSystemIdentity ?? GADFileSystemIdentity.capture(url)
    }
}
