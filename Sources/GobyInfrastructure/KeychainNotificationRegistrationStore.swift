import Foundation
import GobyApplication
import Security

public enum GADNotificationRegistrationStoreError: LocalizedError, Equatable, Sendable {
    case keychain(OSStatus)
    case invalidStoredValue

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            "The system Keychain could not update the notification endpoint (\(status))."
        case .invalidStoredValue:
            "The notification endpoint stored in Keychain is unreadable. Re-enable notifications on the iPhone."
        }
    }
}

/// Host-owned APNs and FCM endpoints. Tokens are stored only in Keychain and never in
/// the dashboard catalog, coordinator projection, diagnostics or logs.
public actor KeychainNotificationRegistrationStore: GADNotificationRegistrationPersisting {
    private let service: String
    private let accessGroup: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        service: String = "com.goby.agentic-dashboard.notification-endpoints",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func registration(for deviceID: DeviceID) throws -> GADNotificationRegistration? {
        var query = baseQuery(for: deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw GADNotificationRegistrationStoreError.keychain(status)
        }
        guard let data = result as? Data,
              let registration = try? decoder.decode(GADNotificationRegistration.self, from: data),
              registration.isValid else {
            throw GADNotificationRegistrationStoreError.invalidStoredValue
        }
        return registration
    }

    public func save(
        _ registration: GADNotificationRegistration,
        for deviceID: DeviceID
    ) throws {
        guard registration.isValid else {
            throw GADNotificationRegistrationStoreError.invalidStoredValue
        }
        let data = try encoder.encode(registration)
        let query = baseQuery(for: deviceID)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw GADNotificationRegistrationStoreError.keychain(updateStatus)
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw GADNotificationRegistrationStoreError.keychain(insertStatus)
        }
    }

    public func remove(for deviceID: DeviceID) throws {
        let status = SecItemDelete(baseQuery(for: deviceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GADNotificationRegistrationStoreError.keychain(status)
        }
    }

    private func baseQuery(for deviceID: DeviceID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
