import Foundation

/// The short-lived values produced by the native Vercel authorization flow.
/// They are exchanged once by the provisioning service and are never persisted.
public struct GADRelayProvisioningAuthorization: Equatable, Sendable {
    public let code: String
    public let codeVerifier: String
    public let redirectURI: String
    public let clientInstallationID: String

    public init(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        clientInstallationID: String
    ) {
        self.code = code
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
        self.clientInstallationID = clientInstallationID
    }
}

/// The only material returned by the provisioning control plane. The relay URL
/// is public configuration; the admission capability belongs in Keychain.
public struct GADProvisionedRelay: Equatable, Sendable {
    public let relayURL: URL
    public let admission: GADRelayHostAdmissionCredential

    public init(relayURL: URL, admission: GADRelayHostAdmissionCredential) {
        self.relayURL = relayURL
        self.admission = admission
    }
}

public protocol GADRelayProvisioning: Sendable {
    func provision(
        authorization: GADRelayProvisioningAuthorization
    ) async throws -> GADProvisionedRelay
}
