import Darwin
import Foundation
import GobyApplication

public struct GADHostTransferTicket: Codable, Equatable, Sendable {
    public let id: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let sourceProcessIdentifier: Int32
    public let expectedProjection: DashboardProjection
    public let authenticationGeneration: UInt64
    public let authenticationTag: Data

    public init(
        id: String = UUID().uuidString.lowercased(),
        issuedAt: Date = .now,
        expiresAt: Date,
        sourceProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        expectedProjection: DashboardProjection,
        authenticationGeneration: UInt64 = 0,
        authenticationTag: Data = Data()
    ) {
        self.id = id
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.sourceProcessIdentifier = sourceProcessIdentifier
        self.expectedProjection = expectedProjection
        self.authenticationGeneration = authenticationGeneration
        self.authenticationTag = authenticationTag
    }

    fileprivate func authenticatedPayload(using encoder: JSONEncoder) throws -> Data {
        try encoder.encode(AuthenticatedPayload(
            id: id,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            sourceProcessIdentifier: sourceProcessIdentifier,
            expectedProjection: expectedProjection
        ))
    }

    fileprivate func sealed(generation: UInt64, tag: Data) -> Self {
        Self(
            id: id,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            sourceProcessIdentifier: sourceProcessIdentifier,
            expectedProjection: expectedProjection,
            authenticationGeneration: generation,
            authenticationTag: tag
        )
    }

    private struct AuthenticatedPayload: Codable {
        let id: String
        let issuedAt: Date
        let expiresAt: Date
        let sourceProcessIdentifier: Int32
        let expectedProjection: DashboardProjection
    }
}

public enum GADHostTransferTicketError: LocalizedError, Equatable, Sendable {
    case missing
    case expired
    case oversized
    case unsafeLocation
    case malformed
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .missing:
            "The background host has no pending ownership handoff from the Mac app."
        case .expired:
            "The pending background-host handoff expired. Reopen Goby and prepare Remote Access again."
        case .oversized:
            "The background-host handoff exceeded its safe size limit."
        case .unsafeLocation:
            "The background-host handoff is not an owner-only regular file in its expected directory."
        case .malformed:
            "The background-host handoff could not be decoded safely."
        case .authenticationFailed:
            "The pending background-host handoff failed authentication. Reopen Goby and prepare Remote Access again."
        }
    }
}

/// Stores the last legacy-UI projection needed to validate one ownership
/// transfer. The ticket is recovery metadata outside the live store, never an
/// alternate source of canonical state.
public actor GADHostTransferTicketStore {
    public static let fileName = "transfer-ticket.json"
    public static let maximumBytes = 8 * 1_024 * 1_024

    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let authenticator: any GADHostAuthorityAuthenticating

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        authenticator: (any GADHostAuthorityAuthenticating)? = nil
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.authenticator = authenticator ?? KeychainHostAuthorityAuthenticator(
            service: "com.goby.agentic-dashboard.host-transfer-ticket"
        )
    }

    public func save(_ ticket: GADHostTransferTicket) async throws {
        try prepareDirectory()
        let payload = try ticket.authenticatedPayload(using: encoder)
        let authentication = try await authenticator.issue(for: payload)
        let data = try encoder.encode(ticket.sealed(
            generation: authentication.generation,
            tag: authentication.tag
        ))
        guard data.count <= Self.maximumBytes else {
            throw GADHostTransferTicketError.oversized
        }
        let destination = directoryURL.appending(path: Self.fileName)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try validateRegularOwnerOnlyFile(destination)
        }
        try data.write(to: destination, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path(percentEncoded: false)
        )
        try validateRegularOwnerOnlyFile(destination)
    }

    public func load(now: Date = .now) async throws -> GADHostTransferTicket {
        let source = directoryURL.appending(path: Self.fileName)
        guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw GADHostTransferTicketError.missing
        }
        try validateDirectory()
        try validateRegularOwnerOnlyFile(source)
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        guard let count = values.fileSize, count <= Self.maximumBytes else {
            throw GADHostTransferTicketError.oversized
        }
        let ticket: GADHostTransferTicket
        do {
            ticket = try decoder.decode(GADHostTransferTicket.self, from: Data(contentsOf: source))
        } catch {
            throw GADHostTransferTicketError.malformed
        }
        guard ticket.issuedAt <= ticket.expiresAt, now <= ticket.expiresAt else {
            throw GADHostTransferTicketError.expired
        }
        guard ticket.authenticationGeneration > 0, !ticket.authenticationTag.isEmpty else {
            throw GADHostTransferTicketError.authenticationFailed
        }
        do {
            try await authenticator.verify(
                GADHostAuthorityAuthentication(
                    generation: ticket.authenticationGeneration,
                    tag: ticket.authenticationTag
                ),
                payload: ticket.authenticatedPayload(using: encoder)
            )
        } catch {
            throw GADHostTransferTicketError.authenticationFailed
        }
        return ticket
    }

    public func clear(expectedID: String) async throws {
        let source = directoryURL.appending(path: Self.fileName)
        guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { return }
        let ticket = try await load(now: .distantPast)
        guard ticket.id == expectedID else { return }
        try fileManager.removeItem(at: source)
    }

    private func prepareDirectory() throws {
        if fileManager.fileExists(atPath: directoryURL.path(percentEncoded: false)) {
            try validateDirectory()
        } else {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path(percentEncoded: false)
        )
        try validateDirectory()
    }

    private func validateDirectory() throws {
        var status = stat()
        let result = directoryURL.path(percentEncoded: false).withCString { lstat($0, &status) }
        guard result == 0,
              status.st_uid == geteuid(),
              (status.st_mode & S_IFMT) == S_IFDIR,
              (status.st_mode & 0o077) == 0 else {
            throw GADHostTransferTicketError.unsafeLocation
        }
    }

    private func validateRegularOwnerOnlyFile(_ url: URL) throws {
        var status = stat()
        let result = url.path(percentEncoded: false).withCString { lstat($0, &status) }
        guard result == 0,
              status.st_uid == geteuid(),
              (status.st_mode & S_IFMT) == S_IFREG,
              (status.st_mode & 0o077) == 0 else {
            throw GADHostTransferTicketError.unsafeLocation
        }
    }
}
