import CryptoKit
import Foundation
import GobyApplication
@testable import GobyInfrastructure
import Security
import Testing

@Suite("Background host authority marker")
struct HostAuthorityMarkerTests {
    @Test("Signed host authority and transfer proofs use the entitlement-enforced shared Keychain", arguments: [
        "com.goby.agentic-dashboard.host-authority",
        "com.goby.agentic-dashboard.host-transfer-ticket",
    ])
    func sharedAuthorityUsesDataProtection(service: String) {
        let group = "TEAM123.com.demetrisgeorgiou.GobyShared"
        let query = KeychainHostAuthorityAuthenticator.keychainQuery(
            service: service, account: "background-host-authority", accessGroup: group
        )
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrAccessGroup as String] as? String == group)
        #expect(query[kSecAttrService as String] as? String == service)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecReturnData as String] == nil)
    }

    @Test("Unentitled local compositions do not claim a shared Keychain group")
    func localAuthorityDoesNotClaimEntitlements() {
        let query = KeychainHostAuthorityAuthenticator.keychainQuery(
            service: "isolated-test", account: "background-host-authority", accessGroup: nil
        )
        #expect(query[kSecAttrAccessGroup as String] == nil)
        #expect(query[kSecUseDataProtectionKeychain as String] == nil)
    }

    @Test("Owner-only restart authority round-trips and can be revoked")
    func roundTripAndRevoke() async throws {
        let directory = temporaryDirectory("round-trip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticator = TestHostAuthorityAuthenticator()
        let store = GADHostAuthorityMarkerStore(
            directoryURL: directory,
            authenticator: authenticator
        )
        let marker = makeMarker(directory: directory)

        let sealed = try await store.save(marker)
        #expect(sealed.generation == 1)
        #expect(!sealed.authenticationTag.isEmpty)
        #expect(try await store.load() == sealed)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appending(path: GADHostAuthorityMarkerStore.fileName)
                .path(percentEncoded: false)
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try await store.revoke()
        await #expect(throws: GADHostAuthorityMarkerError.missing) {
            _ = try await store.load()
        }
    }

    @Test("Missing restart authority fails closed")
    func missingMarkerRejected() async {
        let directory = temporaryDirectory("missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GADHostAuthorityMarkerStore(
            directoryURL: directory,
            authenticator: TestHostAuthorityAuthenticator()
        )

        await #expect(throws: GADHostAuthorityMarkerError.missing) {
            _ = try await store.load()
        }
    }

    @Test("A symbolic-link authority record is rejected")
    func symbolicLinkRejected() async throws {
        let parent = temporaryDirectory("symlink")
        let directory = parent.appending(path: "Transfer", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let outside = parent.appending(path: "outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: GADHostAuthorityMarkerStore.fileName),
            withDestinationURL: outside
        )
        let store = GADHostAuthorityMarkerStore(
            directoryURL: directory,
            authenticator: TestHostAuthorityAuthenticator()
        )

        await #expect(throws: GADHostAuthorityMarkerError.unsafeLocation) {
            _ = try await store.load()
        }
    }

    @Test("A marker restored after revocation cannot regain helper authority")
    func replayAfterRevocationRejected() async throws {
        let directory = temporaryDirectory("replay")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticator = TestHostAuthorityAuthenticator()
        let store = GADHostAuthorityMarkerStore(
            directoryURL: directory,
            authenticator: authenticator
        )
        _ = try await store.save(makeMarker(directory: directory))
        let markerURL = directory.appending(path: GADHostAuthorityMarkerStore.fileName)
        let replay = try Data(contentsOf: markerURL)

        try await store.revoke()
        try replay.write(to: markerURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerURL.path(percentEncoded: false)
        )

        await #expect(throws: GADHostAuthorityMarkerError.authenticationFailed) {
            _ = try await store.load()
        }
    }

    private func makeMarker(directory: URL) -> GADHostAuthorityMarker {
        GADHostAuthorityMarker(
            id: "authority-1",
            hostID: HostID(rawValue: "host"),
            hostVersion: "1",
            activatedAt: Date(timeIntervalSince1970: 20),
            preHostBackup: GADPreHostBackupReceipt(
                id: "backup-1",
                createdAt: Date(timeIntervalSince1970: 10),
                backupURL: directory.appending(path: "backup", directoryHint: .isDirectory),
                files: []
            )
        )
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "goby-host-authority-\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }
}

private actor TestHostAuthorityAuthenticator: GADHostAuthorityAuthenticating {
    private let secret = Data(repeating: 0x5a, count: 32)
    private var currentGeneration: UInt64 = 0
    private var revokedThrough: UInt64 = 0

    func issue(for payload: Data) async throws -> GADHostAuthorityAuthentication {
        currentGeneration = max(currentGeneration, revokedThrough) + 1
        return GADHostAuthorityAuthentication(
            generation: currentGeneration,
            tag: tag(payload: payload, generation: currentGeneration)
        )
    }

    func verify(
        _ authentication: GADHostAuthorityAuthentication,
        payload: Data
    ) async throws {
        guard authentication.generation == currentGeneration,
              authentication.generation > revokedThrough,
              authentication.tag == tag(payload: payload, generation: authentication.generation) else {
            throw GADHostAuthorityMarkerError.authenticationFailed
        }
    }

    func revokeCurrentAuthority() async throws {
        revokedThrough = max(revokedThrough, currentGeneration)
    }

    private func tag(payload: Data, generation: UInt64) -> Data {
        var data = secret
        var value = generation.bigEndian
        data.append(Data(bytes: &value, count: MemoryLayout<UInt64>.size))
        data.append(payload)
        return Data(SHA256.hash(data: data))
    }
}
