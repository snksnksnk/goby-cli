import Foundation
import Testing
@testable import GobyApplication

@Suite("Notification registration")
struct NotificationRegistrationTests {
    @Test("A bounded endpoint is stored for exactly one opaque device identity")
    func storesBoundedRegistration() async throws {
        let repository = NotificationRegistrationSpy()
        let useCase = UpdateNotificationRegistrationUseCase(repository: repository)
        let deviceID = DeviceID(rawValue: "device-1")
        let registration = GADNotificationRegistration(
            token: Data(repeating: 0x2a, count: 32),
            environment: .sandbox,
            categories: [.needsAttention, .runFinished]
        )

        try await useCase(registration, for: deviceID)

        #expect(await repository.registration(for: deviceID) == registration)
    }

    @Test("A bounded UTF-8 FCM endpoint is stored without changing legacy APNs decoding")
    func storesFCMAndDecodesLegacyAPNs() async throws {
        let repository = NotificationRegistrationSpy()
        let useCase = UpdateNotificationRegistrationUseCase(repository: repository)
        let deviceID = DeviceID(rawValue: "android-1")
        let registration = GADNotificationRegistration(
            token: Data("fcm-token:abc_123-def".utf8),
            environment: .production,
            categories: GADNotificationCategory.allCases,
            transport: .fcm
        )

        try await useCase(registration, for: deviceID)
        #expect(await repository.registration(for: deviceID) == registration)

        let legacy = Data(#"{"token":"KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKio=","environment":"sandbox","categories":["needsAttention"]}"#.utf8)
        let decoded = try JSONDecoder().decode(GADNotificationRegistration.self, from: legacy)
        #expect(decoded.transport == .apns)
        #expect(decoded.isValid)
    }

    @Test("Removing notifications retains no endpoint")
    func removesRegistration() async throws {
        let repository = NotificationRegistrationSpy()
        let useCase = UpdateNotificationRegistrationUseCase(repository: repository)
        let deviceID = DeviceID(rawValue: "device-1")
        await repository.save(.init(
            token: Data(repeating: 0x2a, count: 32),
            environment: .production,
            categories: [.needsAttention]
        ), for: deviceID)

        try await useCase(nil, for: deviceID)

        #expect(await repository.registration(for: deviceID) == nil)
    }

    @Test("Empty, oversized and duplicate-category registrations fail closed")
    func rejectsInvalidRegistrations() async {
        let repository = NotificationRegistrationSpy()
        let useCase = UpdateNotificationRegistrationUseCase(repository: repository)
        let deviceID = DeviceID(rawValue: "device-1")
        let invalid: [GADNotificationRegistration] = [
            .init(token: Data(), environment: .sandbox, categories: [.needsAttention]),
            .init(
                token: Data(repeating: 0x2a, count: GADNotificationRegistration.maximumTokenBytes + 1),
                environment: .sandbox,
                categories: [.needsAttention]
            ),
            .init(
                token: Data(repeating: 0x2a, count: 32),
                environment: .sandbox,
                categories: [.needsAttention, .needsAttention]
            ),
            .init(
                token: Data("fcm token with spaces".utf8),
                environment: .production,
                categories: [.needsAttention],
                transport: .fcm
            ),
            .init(
                token: Data(repeating: 0x2a, count: GADNotificationRegistration.maximumFCMTokenBytes + 1),
                environment: .production,
                categories: [.needsAttention],
                transport: .fcm
            ),
        ]

        for registration in invalid {
            await #expect(throws: GADCommandFailure.self) {
                try await useCase(registration, for: deviceID)
            }
        }
        #expect(await repository.registration(for: deviceID) == nil)
    }
}

private actor NotificationRegistrationSpy: GADNotificationRegistrationPersisting {
    private var registrations: [DeviceID: GADNotificationRegistration] = [:]

    func registration(for deviceID: DeviceID) -> GADNotificationRegistration? {
        registrations[deviceID]
    }

    func save(_ registration: GADNotificationRegistration, for deviceID: DeviceID) {
        registrations[deviceID] = registration
    }

    func remove(for deviceID: DeviceID) {
        registrations.removeValue(forKey: deviceID)
    }
}
