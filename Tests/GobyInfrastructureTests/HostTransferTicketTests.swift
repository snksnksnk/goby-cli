import Foundation
import GobyApplication
import GobyInfrastructure
import Testing

@Suite("Background host transfer ticket")
struct HostTransferTicketTests {
    @Test("An exact owner-only ticket round-trips and clears by identity")
    func roundTripAndClear() async throws {
        let directory = temporaryDirectory("round-trip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GADHostTransferTicketStore(
            directoryURL: directory,
            authenticator: TestTransferTicketAuthenticator()
        )
        let ticket = makeTicket(expiresAt: Date(timeIntervalSince1970: 200))

        try await store.save(ticket)
        let loaded = try await store.load(now: Date(timeIntervalSince1970: 100))
        #expect(loaded.id == ticket.id)
        #expect(loaded.expectedProjection == ticket.expectedProjection)
        #expect(loaded.authenticationGeneration > 0)
        #expect(!loaded.authenticationTag.isEmpty)

        try await store.clear(expectedID: "different")
        #expect(try await store.load(now: Date(timeIntervalSince1970: 100)).id == ticket.id)
        try await store.clear(expectedID: ticket.id)
        await #expect(throws: GADHostTransferTicketError.missing) {
            _ = try await store.load(now: Date(timeIntervalSince1970: 100))
        }
    }

    @Test("Expired tickets fail closed")
    func expiredTicketRejected() async throws {
        let directory = temporaryDirectory("expired")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GADHostTransferTicketStore(
            directoryURL: directory,
            authenticator: TestTransferTicketAuthenticator()
        )
        try await store.save(makeTicket(expiresAt: Date(timeIntervalSince1970: 50)))

        await #expect(throws: GADHostTransferTicketError.expired) {
            _ = try await store.load(now: Date(timeIntervalSince1970: 100))
        }
    }

    @Test("A symbolic-link ticket is rejected")
    func symbolicLinkRejected() async throws {
        let parent = temporaryDirectory("symlink")
        let directory = parent.appending(path: "Tickets", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let outside = parent.appending(path: "outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: GADHostTransferTicketStore.fileName),
            withDestinationURL: outside
        )
        let store = GADHostTransferTicketStore(
            directoryURL: directory,
            authenticator: TestTransferTicketAuthenticator()
        )

        await #expect(throws: GADHostTransferTicketError.unsafeLocation) {
            _ = try await store.load(now: Date(timeIntervalSince1970: 100))
        }
    }

    @Test("Owner-only permissions do not make a forged ticket valid")
    func forgedTicketRejected() async throws {
        let directory = temporaryDirectory("forged")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticator = TestTransferTicketAuthenticator()
        let store = GADHostTransferTicketStore(
            directoryURL: directory,
            authenticator: authenticator
        )
        try await store.save(makeTicket(expiresAt: Date(timeIntervalSince1970: 200)))

        let file = directory.appending(path: GADHostTransferTicketStore.fileName)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        object["sourceProcessIdentifier"] = 9_999
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path())

        await #expect(throws: GADHostTransferTicketError.authenticationFailed) {
            _ = try await store.load(now: Date(timeIntervalSince1970: 100))
        }
    }

    private func makeTicket(expiresAt: Date) -> GADHostTransferTicket {
        GADHostTransferTicket(
            id: "ticket-1",
            issuedAt: Date(timeIntervalSince1970: 10),
            expiresAt: expiresAt,
            sourceProcessIdentifier: 42,
            expectedProjection: DashboardProjection(
                generatedAt: Date(timeIntervalSince1970: 10),
                host: .init(
                    id: HostID(rawValue: "host"),
                    displayName: "Test Mac",
                    reachability: .online,
                    lastUpdatedAt: Date(timeIntervalSince1970: 10)
                ),
                draft: .init(text: "Continue this work")
            )
        )
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "goby-host-ticket-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

private actor TestTransferTicketAuthenticator: GADHostAuthorityAuthenticating {
    private var generation: UInt64 = 0
    private var tags: [UInt64: Data] = [:]

    func issue(for payload: Data) -> GADHostAuthorityAuthentication {
        generation += 1
        let tag = Data((payload + Data(String(generation).utf8)).reversed())
        tags[generation] = tag
        return GADHostAuthorityAuthentication(generation: generation, tag: tag)
    }

    func verify(_ authentication: GADHostAuthorityAuthentication, payload: Data) throws {
        let expected = Data((payload + Data(String(authentication.generation).utf8)).reversed())
        guard authentication.generation == generation,
              tags[authentication.generation] == expected,
              authentication.tag == expected else {
            throw GADHostAuthorityMarkerError.authenticationFailed
        }
    }

    func revokeCurrentAuthority() {
        tags.removeAll()
    }
}
