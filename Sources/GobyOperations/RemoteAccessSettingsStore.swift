import Foundation
import Observation

public struct RemotePairedDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public let isConnected: Bool
    public let requiresRepair: Bool

    public init(
        id: String,
        name: String,
        createdAt: Date,
        isConnected: Bool,
        requiresRepair: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.isConnected = isConnected
        self.requiresRepair = requiresRepair
    }
}

public enum RemoteAccessPhase: Equatable, Sendable {
    case disabled
    case starting
    case waitingForDevice
    case confirmingDevice
    case listening
    case failed(String)

    public var isEnabled: Bool {
        switch self {
        case .waitingForDevice, .confirmingDevice, .listening: true
        case .disabled, .starting, .failed: false
        }
    }
}

@MainActor
@Observable
public final class RemoteAccessSettingsStore {
    public var relayURLText: String
    public var relayAdmissionText: String
    public private(set) var hasRelayAdmissionCredential: Bool
    public private(set) var relayAdmissionExpiresAt: Date?
    public private(set) var phase: RemoteAccessPhase = .disabled
    public private(set) var pairingLink: String?
    public private(set) var pairingExpiresAt: Date?
    public private(set) var pairedDeviceName: String?
    public private(set) var pairedDevices: [RemotePairedDevice] = []
    public private(set) var pairingConfirmationCode: String?
    public private(set) var pendingPairingDeviceName: String?

    @ObservationIgnored private var pairingConfirmationContinuation: CheckedContinuation<Bool, Never>?

    @ObservationIgnored public var provisionRelayAction: (@MainActor @Sendable () async throws -> Void)?
    @ObservationIgnored public var enableAction: (@MainActor @Sendable (String, String) async -> Void)?
    @ObservationIgnored public var disableAction: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored public var generatePairingAction: (@MainActor @Sendable (String, String) async -> Void)?
    @ObservationIgnored public var renameDeviceAction: (@MainActor @Sendable (String, String) async -> Void)?
    @ObservationIgnored public var revokeDeviceAction: (@MainActor @Sendable (String) async -> Void)?
    @ObservationIgnored public var revokeAllAction: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored public var resolvePairingAction: (@MainActor @Sendable (Bool) async -> Void)?

    public init(
        relayURLText: String = "",
        relayAdmissionText: String = "",
        hasRelayAdmissionCredential: Bool = false,
        relayAdmissionExpiresAt: Date? = nil
    ) {
        self.relayURLText = relayURLText
        self.relayAdmissionText = relayAdmissionText
        self.hasRelayAdmissionCredential = hasRelayAdmissionCredential
        self.relayAdmissionExpiresAt = relayAdmissionExpiresAt
    }

    /// A relay address and its admission credential are both present.
    public var isRelayConfigured: Bool {
        !relayURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasRelayAdmissionCredential
    }

    public func enable() async {
        phase = .starting
        await enableAction?(relayURLText, relayAdmissionText)
    }

    public func addRelay(address: String, accessKey: String) async {
        relayURLText = address
        relayAdmissionText = accessKey
        await enable()
    }

    public func provisionRelay() async {
        let priorPhase = phase
        phase = .starting
        guard let provisionRelayAction else {
            phase = .failed("Automatic relay setup is not configured in this Goby build.")
            return
        }
        do {
            try await provisionRelayAction()
            if phase == .starting { phase = priorPhase }
        } catch is CancellationError {
            phase = priorPhase
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func disable() async {
        await disableAction?()
    }

    public func generatePairingCode() async {
        resolvePairingConfirmation(accepted: false)
        phase = .starting
        pairingLink = nil
        pairingExpiresAt = nil
        await generatePairingAction?(relayURLText, relayAdmissionText)
    }

    public func renameDevice(id: String, name: String) async {
        await renameDeviceAction?(id, name)
    }

    public func revokeDevice(id: String) async {
        await revokeDeviceAction?(id)
    }

    public func revokeAllDevices() async {
        await revokeAllAction?()
    }

    public func updateDevices(_ devices: [RemotePairedDevice]) {
        pairedDevices = devices
        pairedDeviceName = devices.first(where: \.isConnected)?.name
    }

    public func updateRelayAdmissionConfiguration(isConfigured: Bool, expiresAt: Date? = nil) {
        hasRelayAdmissionCredential = isConfigured
        relayAdmissionExpiresAt = isConfigured ? expiresAt : nil
        if isConfigured { relayAdmissionText = "" }
    }

    public func requestPairingConfirmation(deviceName: String, code: String) async -> Bool {
        resolvePairingConfirmation(accepted: false)
        pendingPairingDeviceName = String(deviceName.prefix(120))
        pairingConfirmationCode = String(code.prefix(6))
        phase = .confirmingDevice
        return await withCheckedContinuation { continuation in
            pairingConfirmationContinuation = continuation
        }
    }

    public func confirmPairingDevice() {
        if let resolvePairingAction {
            Task { await resolvePairingAction(true) }
            return
        }
        resolvePairingConfirmation(accepted: true)
    }

    public func declinePairingDevice() {
        if let resolvePairingAction {
            Task { await resolvePairingAction(false) }
            return
        }
        resolvePairingConfirmation(accepted: false)
    }

    public func cancelPairingConfirmation() {
        resolvePairingConfirmation(accepted: false)
    }

    public func update(
        phase: RemoteAccessPhase,
        pairingLink: String? = nil,
        pairingExpiresAt: Date? = nil,
        pairedDeviceName: String? = nil
    ) {
        if phase != .confirmingDevice {
            resolvePairingConfirmation(accepted: false)
        }
        self.phase = phase
        self.pairingLink = pairingLink
        self.pairingExpiresAt = pairingExpiresAt
        self.pairedDeviceName = pairedDeviceName
    }

    public func presentRemotePairingConfirmation(deviceName: String, code: String) {
        pendingPairingDeviceName = String(deviceName.prefix(120))
        pairingConfirmationCode = String(code.prefix(6))
        phase = .confirmingDevice
    }

    private func resolvePairingConfirmation(accepted: Bool) {
        pairingConfirmationContinuation?.resume(returning: accepted)
        pairingConfirmationContinuation = nil
        pairingConfirmationCode = nil
        pendingPairingDeviceName = nil
    }
}
