import CryptoKit
import Foundation
import GobyApplication
import GobyRemoteContract
import LocalAuthentication
import Security

public enum GADDeviceIdentityProtection: String, Codable, Equatable, Sendable {
    case secureEnclave
    case keychain
}

public struct GADDeviceIdentity: Codable, Equatable, Sendable {
    public let signingPublicKey: Data
    public let protection: GADDeviceIdentityProtection

    public init(signingPublicKey: Data, protection: GADDeviceIdentityProtection) {
        self.signingPublicKey = signingPublicKey
        self.protection = protection
    }
}

public protocol GADDeviceIdentitySigning: Sendable {
    func identity() async throws -> GADDeviceIdentity
    func sign(_ data: Data) async throws -> Data
}

public protocol GADDeviceAuthorizationSigning: Sendable {
    func publicKey() async throws -> Data
    func signAuthorized(_ data: Data, reason: String) async throws -> Data
}

public enum GADDeviceIdentityError: LocalizedError, Equatable, Sendable {
    case invalidRecord
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidRecord:
            "The device identity record is invalid. Remove this pairing and create a new one."
        case let .keychain(status):
            "Goby could not access this device’s secure identity (\(status))."
        }
    }
}

/// Owns the non-exportable device signing identity when Secure Enclave is
/// available, with a ThisDeviceOnly Keychain fallback for Simulator and Macs
/// without a Secure Enclave.
public actor GADDeviceIdentityStore: GADDeviceIdentitySigning {
    private struct Record: Codable, Sendable {
        let protection: GADDeviceIdentityProtection
        let privateKeyRepresentation: Data
    }

    private let service: String
    private let account: String
    private let prefersSecureEnclave: Bool
    private let codec = GADWireCodec(maximumBytes: 16_384)

    public init(
        service: String = "com.demetrisgeorgiou.Goby.device-identity",
        account: String = "owner-device-signing",
        prefersSecureEnclave: Bool = true
    ) {
        self.service = service
        self.account = account
        self.prefersSecureEnclave = prefersSecureEnclave
    }

    public func identity() async throws -> GADDeviceIdentity {
        let record = try loadOrCreate()
        return try identity(for: record)
    }

    public func sign(_ data: Data) async throws -> Data {
        let record = try loadOrCreate()
        switch record.protection {
        case .secureEnclave:
            guard SecureEnclave.isAvailable else { throw GADDeviceIdentityError.invalidRecord }
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: record.privateKeyRepresentation
            )
            return try key.signature(for: data).derRepresentation
        case .keychain:
            let key = try P256.Signing.PrivateKey(rawRepresentation: record.privateKeyRepresentation)
            return try key.signature(for: data).derRepresentation
        }
    }

    public func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GADDeviceIdentityError.keychain(status)
        }
    }

    private func identity(for record: Record) throws -> GADDeviceIdentity {
        let publicKey: Data
        switch record.protection {
        case .secureEnclave:
            guard SecureEnclave.isAvailable else { throw GADDeviceIdentityError.invalidRecord }
            publicKey = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: record.privateKeyRepresentation
            ).publicKey.rawRepresentation
        case .keychain:
            publicKey = try P256.Signing.PrivateKey(
                rawRepresentation: record.privateKeyRepresentation
            ).publicKey.rawRepresentation
        }
        guard publicKey.count == 64 else { throw GADDeviceIdentityError.invalidRecord }
        return GADDeviceIdentity(signingPublicKey: publicKey, protection: record.protection)
    }

    private func loadOrCreate() throws -> Record {
        if let record = try load() { return record }
        let record = makeSecureEnclaveRecord() ?? makeKeychainRecord()
        try save(record)
        return record
    }

    private func makeSecureEnclaveRecord() -> Record? {
        guard prefersSecureEnclave, SecureEnclave.isAvailable else { return nil }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &accessError
        ), let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) else {
            return nil
        }
        return Record(protection: .secureEnclave, privateKeyRepresentation: key.dataRepresentation)
    }

    private func makeKeychainRecord() -> Record {
        let key = P256.Signing.PrivateKey()
        return Record(protection: .keychain, privateKeyRepresentation: key.rawRepresentation)
    }

    private func load() throws -> Record? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GADDeviceIdentityError.keychain(status)
        }
        do {
            return try codec.decode(Record.self, from: data)
        } catch {
            throw GADDeviceIdentityError.invalidRecord
        }
    }

    private func save(_ record: Record) throws {
        let data = try codec.encode(record)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updated = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            var item = identity
            attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw GADDeviceIdentityError.keychain(added) }
        } else if updated != errSecSuccess {
            throw GADDeviceIdentityError.keychain(updated)
        }
    }
}

/// A second device key used only for high-impact commands. Its private-key
/// operation requires system user presence, so the resulting signature binds
/// Face ID/passcode approval to the exact canonical command bytes. The normal
/// device identity remains separate so routine synchronization never prompts.
public actor GADDeviceAuthorizationStore: GADDeviceAuthorizationSigning {
    private let applicationTag: Data

    public init(
        applicationTag: Data = Data(
            "com.demetrisgeorgiou.Goby.device-authorization".utf8
        )
    ) {
        self.applicationTag = applicationTag
    }

    public func publicKey() async throws -> Data {
        let privateKey = try loadOrCreatePrivateKey(authenticationContext: nil)
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw GobyClientLocalError.localAuthenticationUnavailable
        }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              representation.count == 65,
              representation.first == 0x04 else {
            throw mapped(error)
        }
        return Data(representation.dropFirst())
    }

    public func signAuthorized(_ data: Data, reason: String) async throws -> Data {
        let context = LAContext()
        context.localizedReason = String(reason.prefix(240))
        let privateKey = try loadOrCreatePrivateKey(authenticationContext: context)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) as Data? else {
            throw mapped(error)
        }
        return signature
    }

    public func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: applicationTag
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mapped(status)
        }
    }

    private func loadOrCreatePrivateKey(authenticationContext: LAContext?) throws -> SecKey {
        if let key = try loadPrivateKey(authenticationContext: authenticationContext) {
            return key
        }
        try createPrivateKey(preferSecureEnclave: SecureEnclave.isAvailable)
        guard let key = try loadPrivateKey(authenticationContext: authenticationContext) else {
            throw GobyClientLocalError.localAuthenticationUnavailable
        }
        return key
    }

    private func loadPrivateKey(authenticationContext: LAContext?) throws -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: applicationTag,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result else {
            throw mapped(status)
        }
        return (result as! SecKey)
    }

    private func createPrivateKey(preferSecureEnclave: Bool) throws {
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            nil
        ) else {
            throw GobyClientLocalError.localAuthenticationUnavailable
        }
        func attributes(secureEnclave: Bool) -> [String: Any] {
            var attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: applicationTag,
                    kSecAttrAccessControl as String: accessControl
                ]
            ]
            if secureEnclave {
                attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
            }
            return attributes
        }

        var error: Unmanaged<CFError>?
        if preferSecureEnclave {
            if SecKeyCreateRandomKey(
                attributes(secureEnclave: true) as CFDictionary,
                &error
            ) != nil {
                return
            }
            _ = error?.takeRetainedValue()
            error = nil
        }
        guard SecKeyCreateRandomKey(
            attributes(secureEnclave: false) as CFDictionary,
            &error
        ) != nil else {
            throw mapped(error)
        }
    }

    private func mapped(_ status: OSStatus) -> GobyClientLocalError {
        if status == errSecUserCanceled || status == errSecAuthFailed {
            return .localAuthenticationCancelled
        }
        return .localAuthenticationUnavailable
    }

    private func mapped(_ error: Unmanaged<CFError>?) -> GobyClientLocalError {
        guard let error else { return .localAuthenticationUnavailable }
        let nsError = error.takeRetainedValue() as Error as NSError
        if nsError.domain == NSOSStatusErrorDomain,
           (nsError.code == Int(errSecUserCanceled) || nsError.code == Int(errSecAuthFailed)) {
            return .localAuthenticationCancelled
        }
        return .localAuthenticationUnavailable
    }
}

public struct GADPairingHostKeyMaterial: Equatable, Sendable {
    public let privateKey: Data
    public let publicKey: Data

    public init() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        privateKey = key.rawRepresentation
        publicKey = key.publicKey.rawRepresentation
    }

    init(privateKey: Data) throws {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        self.privateKey = key.rawRepresentation
        publicKey = key.publicKey.rawRepresentation
    }
}

public struct GADPairingConfirmation: Codable, Equatable, Sendable {
    public let code: String
    public let peerDisplayName: String

    public init(code: String, peerDisplayName: String) {
        self.code = code
        self.peerDisplayName = String(peerDisplayName.prefix(120))
    }
}

enum GADAuthenticatedPairingCryptoError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion
    case invalidMaterial
    case authenticationFailed
    case secureRandom(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "This pairing code does not support authenticated pairing."
        case .invalidMaterial:
            "The pairing request did not match the code created by the Mac."
        case .authenticationFailed:
            "Goby could not verify the other device’s pairing identity."
        case let .secureRandom(status):
            "Goby could not create secure pairing material (\(status))."
        }
    }
}

struct GADDevicePairingContext: Sendable {
    let request: GADAuthenticatedPairingRequest
    let sessionSecret: Data
    let transcriptDigest: Data
    let confirmationCode: String
}

struct GADHostPairingContext: Sendable {
    let request: GADAuthenticatedPairingRequest
    let sessionSecret: Data
    let transcriptDigest: Data
    let confirmationCode: String
}

enum GADAuthenticatedPairingCrypto {
    static func makeDeviceContext(
        payload: GADPairingPayload,
        deviceDisplayName: String,
        identityStore: any GADDeviceIdentitySigning,
        authorizationStore: any GADDeviceAuthorizationSigning,
        codec: GADWireCodec
    ) async throws -> GADDevicePairingContext {
        guard payload.version.major >= GADProtocolVersion.version3.major,
              let hostPublicKey = payload.hostEphemeralPublicKey,
              hostPublicKey.count == 32 else {
            throw GADAuthenticatedPairingCryptoError.unsupportedVersion
        }
        let identity = try await identityStore.identity()
        let authorizationPublicKey = try await authorizationStore.publicKey()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let material = GADAuthenticatedPairingMaterial(
            protocolVersion: payload.version,
            relayURL: payload.relayURL,
            hostID: payload.hostID,
            deviceID: payload.deviceID,
            hostEphemeralPublicKey: hostPublicKey,
            deviceIdentityPublicKey: identity.signingPublicKey,
            deviceAuthorizationPublicKey: authorizationPublicKey,
            deviceEphemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            clientNonce: try secureRandomBytes(count: 32),
            deviceDisplayName: String(deviceDisplayName.prefix(120)),
            expiresAt: payload.expiresAt
        )
        let materialData = try codec.encode(material)
        let request = GADAuthenticatedPairingRequest(
            material: material,
            deviceSignature: try await identityStore.sign(materialData)
        )
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostPublicKey)
        let sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey)
        return context(
            request: request,
            materialData: materialData,
            sharedSecret: sharedSecret,
            challengeSecret: payload.oneTimeSecret
        )
    }

    static func makeHostContext(
        payload: GADPairingPayload,
        hostPrivateKey: Data,
        request: GADAuthenticatedPairingRequest,
        codec: GADWireCodec
    ) throws -> GADHostPairingContext {
        let material = request.material
        let requiresAuthorizationKey = material.protocolVersion.major > 3
            || (material.protocolVersion.major == 3 && material.protocolVersion.minor >= 3)
        guard payload.version.major >= GADProtocolVersion.version3.major,
              material.protocolVersion == payload.version,
              material.relayURL == payload.relayURL,
              material.hostID == payload.hostID,
              material.deviceID == payload.deviceID,
              material.hostEphemeralPublicKey == payload.hostEphemeralPublicKey,
              material.deviceIdentityPublicKey.count == 64,
              (requiresAuthorizationKey
                ? material.deviceAuthorizationPublicKey?.count == 64
                : material.deviceAuthorizationPublicKey == nil
                    || material.deviceAuthorizationPublicKey?.count == 64),
              material.deviceEphemeralPublicKey.count == 32,
              material.clientNonce.count == 32,
              !material.deviceDisplayName.isEmpty,
              material.deviceDisplayName.count <= 120,
              abs(material.expiresAt.timeIntervalSince(payload.expiresAt)) < 0.001 else {
            throw GADAuthenticatedPairingCryptoError.invalidMaterial
        }
        let materialData = try codec.encode(material)
        let identityKey: P256.Signing.PublicKey
        let signature: P256.Signing.ECDSASignature
        do {
            identityKey = try P256.Signing.PublicKey(rawRepresentation: material.deviceIdentityPublicKey)
            signature = try P256.Signing.ECDSASignature(derRepresentation: request.deviceSignature)
        } catch {
            throw GADAuthenticatedPairingCryptoError.authenticationFailed
        }
        guard identityKey.isValidSignature(signature, for: materialData) else {
            throw GADAuthenticatedPairingCryptoError.authenticationFailed
        }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hostPrivateKey)
        guard privateKey.publicKey.rawRepresentation == payload.hostEphemeralPublicKey else {
            throw GADAuthenticatedPairingCryptoError.invalidMaterial
        }
        let deviceKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: material.deviceEphemeralPublicKey
        )
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: deviceKey)
        let device = context(
            request: request,
            materialData: materialData,
            sharedSecret: sharedSecret,
            challengeSecret: payload.oneTimeSecret
        )
        return GADHostPairingContext(
            request: device.request,
            sessionSecret: device.sessionSecret,
            transcriptDigest: device.transcriptDigest,
            confirmationCode: device.confirmationCode
        )
    }

    static func challenge(
        for context: GADHostPairingContext,
        relayRevocationProof: String? = nil
    ) -> GADAuthenticatedPairingChallenge {
        let proofLabel = relayRevocationProof.map { "host-confirm:\($0)" } ?? "host-confirm"
        return GADAuthenticatedPairingChallenge(
            confirmationCode: context.confirmationCode,
            hostProof: proof(label: proofLabel, context: context),
            relayRevocationProof: relayRevocationProof
        )
    }

    static func validate(
        _ challenge: GADAuthenticatedPairingChallenge,
        for context: GADDevicePairingContext
    ) throws {
        let requiresSeparatedRelayAuthority = context.request.material.protocolVersion
            >= GADProtocolVersion(major: 3, minor: 6)
        guard !requiresSeparatedRelayAuthority
                || challenge.relayRevocationProof?.count == 43 else {
            throw GADAuthenticatedPairingCryptoError.authenticationFailed
        }
        let proofLabel = challenge.relayRevocationProof.map { "host-confirm:\($0)" }
            ?? "host-confirm"
        guard challenge.confirmationCode == context.confirmationCode,
              valid(challenge.hostProof, label: proofLabel, context: context) else {
            throw GADAuthenticatedPairingCryptoError.authenticationFailed
        }
    }

    static func response(
        accepted: Bool,
        context: GADDevicePairingContext
    ) -> GADAuthenticatedPairingResponse {
        GADAuthenticatedPairingResponse(
            accepted: accepted,
            deviceProof: proof(
                label: accepted ? "device-accept" : "device-decline",
                context: context
            )
        )
    }

    static func validate(
        _ response: GADAuthenticatedPairingResponse,
        for context: GADHostPairingContext
    ) throws {
        guard valid(
            response.deviceProof,
            label: response.accepted ? "device-accept" : "device-decline",
            context: context
        ) else {
            throw GADAuthenticatedPairingCryptoError.authenticationFailed
        }
    }

    private static func context(
        request: GADAuthenticatedPairingRequest,
        materialData: Data,
        sharedSecret: SharedSecret,
        challengeSecret: Data
    ) -> GADDevicePairingContext {
        let materialDigest = Data(SHA256.hash(data: materialData))
        let sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: challengeSecret,
            sharedInfo: materialDigest + Data("goby-pairing-v3".utf8),
            outputByteCount: 32
        )
        let sessionSecret = sessionKey.withUnsafeBytes { Data($0) }
        let codeBytes = Data(HMAC<SHA256>.authenticationCode(
            for: materialDigest + Data("human-confirmation".utf8),
            using: sessionKey
        ))
        let value = codeBytes.prefix(4).reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        let code = String(format: "%06u", value % 1_000_000)
        return GADDevicePairingContext(
            request: request,
            sessionSecret: sessionSecret,
            transcriptDigest: materialDigest,
            confirmationCode: code
        )
    }

    private static func proof(
        label: String,
        context: GADDevicePairingContext
    ) -> Data {
        proof(label: label, secret: context.sessionSecret, digest: context.transcriptDigest)
    }

    private static func proof(
        label: String,
        context: GADHostPairingContext
    ) -> Data {
        proof(label: label, secret: context.sessionSecret, digest: context.transcriptDigest)
    }

    private static func proof(label: String, secret: Data, digest: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: digest + Data(label.utf8),
            using: SymmetricKey(data: secret)
        ))
    }

    private static func valid(
        _ candidate: Data,
        label: String,
        context: GADDevicePairingContext
    ) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            candidate,
            authenticating: context.transcriptDigest + Data(label.utf8),
            using: SymmetricKey(data: context.sessionSecret)
        )
    }

    private static func valid(
        _ candidate: Data,
        label: String,
        context: GADHostPairingContext
    ) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            candidate,
            authenticating: context.transcriptDigest + Data(label.utf8),
            using: SymmetricKey(data: context.sessionSecret)
        )
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw GADAuthenticatedPairingCryptoError.secureRandom(status)
        }
        return data
    }
}

public enum GADDeviceCommandAuthenticationError: LocalizedError, Equatable, Sendable {
    case identityMismatch
    case authorizationIdentityMismatch
    case invalidSignature
    case invalidAuthorizationSignature
    case invalidCommand

    public var errorDescription: String? {
        switch self {
        case .identityMismatch:
            "This device’s signing identity no longer matches its paired record. Pair it again."
        case .authorizationIdentityMismatch:
            "This device has no matching user-authorization identity. Pair it again."
        case .invalidSignature:
            "The Mac could not verify this device command."
        case .invalidAuthorizationSignature:
            "The Mac could not verify user authorization for this command."
        case .invalidCommand:
            "The signed device command is invalid."
        }
    }
}

enum GADDeviceCommandAuthenticator {
    static func sign(
        _ command: GADCommand,
        expectedPublicKey: Data,
        signer: any GADDeviceIdentitySigning,
        expectedAuthorizationPublicKey: Data?,
        authorizationSigner: any GADDeviceAuthorizationSigning,
        codec: GADWireCodec
    ) async throws -> GADSignedCommandEnvelope {
        let identity = try await signer.identity()
        guard identity.signingPublicKey == expectedPublicKey else {
            throw GADDeviceCommandAuthenticationError.identityMismatch
        }
        let bytes = try codec.encode(command)
        let authorizationSignature: Data?
        if let reason = command.payload.localAuthorizationReason {
            guard let expectedAuthorizationPublicKey,
                  expectedAuthorizationPublicKey.count == 64,
                  try await authorizationSigner.publicKey() == expectedAuthorizationPublicKey else {
                throw GADDeviceCommandAuthenticationError.authorizationIdentityMismatch
            }
            authorizationSignature = try await authorizationSigner.signAuthorized(
                bytes,
                reason: reason
            )
        } else {
            authorizationSignature = nil
        }
        return GADSignedCommandEnvelope(
            commandBytes: bytes,
            deviceSignature: try await signer.sign(bytes),
            localAuthorizationSignature: authorizationSignature
        )
    }

    static func verify(
        _ envelope: GADSignedCommandEnvelope,
        expectedPublicKey: Data,
        expectedAuthorizationPublicKey: Data?,
        codec: GADWireCodec
    ) throws -> GADCommand {
        guard expectedPublicKey.count == 64, !envelope.commandBytes.isEmpty else {
            throw GADDeviceCommandAuthenticationError.invalidCommand
        }
        let publicKey: P256.Signing.PublicKey
        let signature: P256.Signing.ECDSASignature
        do {
            publicKey = try P256.Signing.PublicKey(rawRepresentation: expectedPublicKey)
            signature = try P256.Signing.ECDSASignature(derRepresentation: envelope.deviceSignature)
        } catch {
            throw GADDeviceCommandAuthenticationError.invalidSignature
        }
        guard publicKey.isValidSignature(signature, for: envelope.commandBytes) else {
            throw GADDeviceCommandAuthenticationError.invalidSignature
        }
        let command: GADCommand
        do {
            command = try codec.decode(GADCommand.self, from: envelope.commandBytes)
        } catch {
            throw GADDeviceCommandAuthenticationError.invalidCommand
        }
        if command.payload.localAuthorizationReason != nil {
            guard let expectedAuthorizationPublicKey,
                  expectedAuthorizationPublicKey.count == 64,
                  let authorizationSignature = envelope.localAuthorizationSignature else {
                throw GADDeviceCommandAuthenticationError.invalidAuthorizationSignature
            }
            let authorizationKey: P256.Signing.PublicKey
            let signature: P256.Signing.ECDSASignature
            do {
                authorizationKey = try P256.Signing.PublicKey(
                    rawRepresentation: expectedAuthorizationPublicKey
                )
                signature = try P256.Signing.ECDSASignature(
                    derRepresentation: authorizationSignature
                )
            } catch {
                throw GADDeviceCommandAuthenticationError.invalidAuthorizationSignature
            }
            guard authorizationKey.isValidSignature(signature, for: envelope.commandBytes) else {
                throw GADDeviceCommandAuthenticationError.invalidAuthorizationSignature
            }
        } else if envelope.localAuthorizationSignature != nil {
            throw GADDeviceCommandAuthenticationError.invalidAuthorizationSignature
        }
        return command
    }
}

private extension GADCommandPayload {
    var localAuthorizationReason: String? {
        switch self {
        case let .startRun(approval) where approval.authorizationAssertion?.isEmpty == false:
            "Approve this Goby plan and its disclosed scope"
        case let .respondToApproval(response)
            where response.authorizationAssertion?.isEmpty == false:
            response.action == .allowForRun
                ? "Approve policy-permitted actions for this Goby run"
                : "Approve this exact agent request"
        case let .commitHostAdmin(commit)
            where commit.authorizationAssertion?.isEmpty == false:
            "Approve the reviewed change on your paired Mac"
        case let .reviewAndRunAutomationOccurrence(review)
            where review.authorizationAssertion?.isEmpty == false:
            "Approve this automation action and its disclosed scope"
        default:
            nil
        }
    }
}
