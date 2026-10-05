import CryptoKit
import Foundation
import GobyApplication
import GobyRemoteContract
import Security

public actor GADEncryptedProjectionCache: GADProjectionCaching, GADLocalDraftCaching {
    private struct LocalDraftRecord: Codable, Sendable {
        let version: UInt16
        let text: String
    }

    private let profile: GADPairingProfile
    private let fileURL: URL
    private let localDraftURL: URL
    private let service: String
    private let codec = GADWireCodec()

    public init(
        profile: GADPairingProfile,
        directoryURL: URL,
        service: String = "com.demetrisgeorgiou.Goby.snapshot-cache"
    ) {
        self.profile = profile
        self.fileURL = directoryURL.appending(path: "dashboard.snapshot", directoryHint: .notDirectory)
        self.localDraftURL = directoryURL.appending(path: "dashboard.draft", directoryHint: .notDirectory)
        self.service = service
    }

    public func load() throws -> DashboardProjection? {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        let key = SymmetricKey(data: try cacheKey(createIfMissing: false))
        let sealedData = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let box = try ChaChaPoly.SealedBox(combined: sealedData)
        let plaintext = try ChaChaPoly.open(box, using: key, authenticating: associatedData)
        return try codec.decode(DashboardProjection.self, from: plaintext)
    }

    public func save(_ projection: DashboardProjection) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if os(iOS)
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(directoryValues)
#endif
        let key = SymmetricKey(data: try cacheKey(createIfMissing: true))
        let plaintext = try codec.encode(projection)
        let sealed = try ChaChaPoly.seal(plaintext, using: key, authenticating: associatedData)
        let combined = sealed.combined
#if os(iOS)
        try combined.write(to: fileURL, options: [.atomic, .completeFileProtection])
        var fileValues = URLResourceValues()
        fileValues.isExcludedFromBackup = true
        var protectedFile = fileURL
        try protectedFile.setResourceValues(fileValues)
#else
        try combined.write(to: fileURL, options: .atomic)
#endif
    }

    public func loadLocalDraft() throws -> String? {
        guard FileManager.default.fileExists(
            atPath: localDraftURL.path(percentEncoded: false)
        ) else { return nil }
        let key = SymmetricKey(data: try cacheKey(createIfMissing: false))
        let sealedData = try Data(contentsOf: localDraftURL, options: [.mappedIfSafe])
        let box = try ChaChaPoly.SealedBox(combined: sealedData)
        let plaintext = try ChaChaPoly.open(
            box,
            using: key,
            authenticating: localDraftAssociatedData
        )
        let record = try codec.decode(LocalDraftRecord.self, from: plaintext)
        guard record.version == 1, record.text.count <= 32_000 else {
            throw GADProjectionCacheError.encryptionFailed
        }
        return record.text
    }

    public func saveLocalDraft(_ text: String?) throws {
        guard let text else {
            if FileManager.default.fileExists(atPath: localDraftURL.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: localDraftURL)
            }
            return
        }
        let directory = localDraftURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if os(iOS)
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(directoryValues)
#endif
        let key = SymmetricKey(data: try cacheKey(createIfMissing: true))
        let plaintext = try codec.encode(LocalDraftRecord(
            version: 1,
            text: String(text.prefix(32_000))
        ))
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: key,
            authenticating: localDraftAssociatedData
        )
#if os(iOS)
        try sealed.combined.write(to: localDraftURL, options: [.atomic, .completeFileProtection])
        var fileValues = URLResourceValues()
        fileValues.isExcludedFromBackup = true
        var protectedFile = localDraftURL
        try protectedFile.setResourceValues(fileValues)
#else
        try sealed.combined.write(to: localDraftURL, options: .atomic)
#endif
    }

    public func clear() throws {
        try Self.clearPersistedArtifacts(
            directoryURL: fileURL.deletingLastPathComponent(),
            cacheAccount: "\(profile.hostID.rawValue).\(profile.deviceID.rawValue)",
            service: service
        )
    }

    public static func clearPersistedArtifacts(
        directoryURL: URL,
        cacheAccount: String,
        service: String = "com.demetrisgeorgiou.Goby.snapshot-cache"
    ) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: cacheAccount
        ]
        let status = SecItemDelete(identity as CFDictionary)
        let fileURL = directoryURL.appending(path: "dashboard.snapshot", directoryHint: .notDirectory)
        let localDraftURL = directoryURL.appending(path: "dashboard.draft", directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: fileURL)
        }
        if FileManager.default.fileExists(atPath: localDraftURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: localDraftURL)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GADProjectionCacheError.keychain(status)
        }
    }

    private var associatedData: Data {
        Data("\(profile.hostID.rawValue):\(profile.deviceID.rawValue):goby-dashboard-v1".utf8)
    }

    private var localDraftAssociatedData: Data {
        Data("\(profile.hostID.rawValue):\(profile.deviceID.rawValue):goby-local-draft-v1".utf8)
    }

    private var keychainIdentity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(profile.hostID.rawValue).\(profile.deviceID.rawValue)"
        ]
    }

    private func cacheKey(createIfMissing: Bool) throws -> Data {
        var query = keychainIdentity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound, createIfMissing else {
            throw GADProjectionCacheError.keychain(status)
        }

        var keyData = Data(repeating: 0, count: 32)
        let randomStatus = keyData.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw GADProjectionCacheError.randomnessUnavailable }
        var item = keychainIdentity
        item[kSecValueData as String] = keyData
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw GADProjectionCacheError.keychain(addStatus) }
        return keyData
    }
}

public enum GADProjectionCacheError: LocalizedError, Sendable {
    case encryptionFailed
    case randomnessUnavailable
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encryptionFailed: "Goby could not encrypt the offline snapshot."
        case .randomnessUnavailable: "Goby could not create the offline-cache key."
        case let .keychain(status): "Goby could not access the offline-cache key (\(status))."
        }
    }
}
