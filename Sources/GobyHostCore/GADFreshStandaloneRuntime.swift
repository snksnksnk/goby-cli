import CryptoKit
import Foundation
import GobyApplication
import GobyDomain
import GobyInfrastructure
import GobyOperations

/// Fresh CLI activation has no foreground transfer ticket, authority marker,
/// or pre-host backup. The lease is still acquired before loading the store.
@MainActor
public final class GADFreshStandaloneRuntime {
    public let storeDirectory: URL
    public private(set) var store: AppStore?
    public private(set) var handler: GADHostIPCRequestHandler?

    private let lease: GADHostOwnershipLease
    private let ownerID: String
    private let notifier: any RunNotifying & AutomationNotifying
    private let trustPolicy: any ProviderRuntimeTrustPolicy
    private let keychainNamespace: GADHostKeychainNamespace
    private let localDefaults: UserDefaults
    private let providerRuntimeRootURL: URL?
    private let temporaryChatSupportDirectoryURL: URL?
    private let suppliedIdentifierAliasCodec: RemoteIdentifierAliasCodec?
    private var coordinator: GADCoordinator?
    private var commandHandler: AppStoreGADCommandHandler?
    private var observationTask: Task<Void, Never>?
    private let automationAuthenticator: (any GADAutomationDocumentAuthenticating)?

    public init(
        storeDirectory: URL = GADHostComposition.cliStoreDirectory(),
        notifier: any RunNotifying & AutomationNotifying,
        trustPolicy: any ProviderRuntimeTrustPolicy = StandaloneProviderRuntimeTrustPolicy(),
        keychainNamespace: GADHostKeychainNamespace = .cli,
        localDefaults: UserDefaults? = nil,
        providerRuntimeRootURL: URL? = nil,
        identifierAliasCodec: RemoteIdentifierAliasCodec? = nil,
        automationAuthenticator: (any GADAutomationDocumentAuthenticating)? = nil,
        temporaryChatSupportDirectoryURL: URL? = nil
    ) throws {
        self.storeDirectory = storeDirectory.standardizedFileURL
        self.notifier = notifier
        self.trustPolicy = trustPolicy
        self.keychainNamespace = keychainNamespace
        guard let resolvedDefaults = localDefaults ?? UserDefaults(suiteName: "com.goby.cli") else {
            throw GADFreshStandaloneError.preferencesUnavailable
        }
        self.localDefaults = resolvedDefaults
        self.providerRuntimeRootURL = providerRuntimeRootURL ?? Self.installedProviderRuntimeRoot()
        self.suppliedIdentifierAliasCodec = identifierAliasCodec
        self.automationAuthenticator = automationAuthenticator
        self.temporaryChatSupportDirectoryURL = temporaryChatSupportDirectoryURL
        self.ownerID = "cli-host-\(ProcessInfo.processInfo.processIdentifier)"
        self.lease = GADHostOwnershipLease(storeDirectory: self.storeDirectory)
    }

    public func start(hostVersion: String) async throws -> GADHostIPCRequestHandler {
        if let handler { return handler }
        try await lease.acquire(ownerID: ownerID, role: .standaloneCLI)
        do {
            let store = GADHostComposition.makeStore(
                storeURL: storeDirectory,
                localRunNotifier: notifier,
                automationAuthenticator: automationAuthenticator,
                accessGroup: nil,
                keychainNamespace: keychainNamespace,
                trustPolicy: trustPolicy,
                temporaryChatSupportDirectoryURL: temporaryChatSupportDirectoryURL ?? Self.chatCacheDirectory(store: storeDirectory),
                repositoryLockOwnerLabel: "Goby CLI host",
                localDefaults: localDefaults,
                providerRuntimeRootURL: providerRuntimeRootURL,
                parkedProviders: [],
                allowsClaudeSubscriptionCredentials: false
            )
            self.store = store
            await store.load(includingLiveProviderChecks: false)
            if let error = store.errorMessage {
                throw GADFreshStandaloneError.storeLoadFailed(error)
            }
            let hostID = HostID(rawValue: "cli-local-host")
            let localDeviceID = DeviceID(rawValue: "cli-local-client")
            let aliasCodec: RemoteIdentifierAliasCodec
            if let suppliedIdentifierAliasCodec {
                aliasCodec = suppliedIdentifierAliasCodec
            } else {
                let aliasKey = try await KeychainRemoteIdentifierAliasKeyStore(
                    service: keychainNamespace.identifierAlias,
                    accessGroup: nil
                ).loadOrCreate()
                aliasCodec = try RemoteIdentifierAliasCodec(keyData: aliasKey)
            }
            let commandHandler = AppStoreGADCommandHandler(
                store: store,
                hostID: hostID,
                updateNotificationRegistration: UpdateNotificationRegistrationUseCase(
                    repository: KeychainNotificationRegistrationStore(
                        service: keychainNamespace.notificationEndpoints,
                        accessGroup: nil
                    )
                ),
                providerCredentials: KeychainProviderCredentialStore(
                    service: keychainNamespace.providerCredentials,
                    accessGroup: nil
                ),
                remoteIdentifierAliasCodec: aliasCodec
            )
            let restored = try await store.loadCoordinatorCheckpoint(hostID: hostID)
            let initial = try await commandHandler.projection(replacing: restored?.projection)
            let securedRestored = try restored.map(commandHandler.secureCheckpoint)
            let coordinator = GADCoordinator(
                hostID: hostID,
                initialProjection: initial,
                capabilities: GADCapability.productionHost,
                authorizedDevices: [localDeviceID],
                handler: commandHandler,
                restoredCheckpoint: securedRestored,
                persistCheckpoint: { [weak store] checkpoint in
                    guard let store else { throw CancellationError() }
                    try await store.saveCoordinatorCheckpoint(checkpoint)
                }
            )
            if securedRestored != nil { _ = await coordinator.synchronize(initial) }
            try await coordinator.flushCheckpoint()
            commandHandler.authorizeLocalAttachmentSources(for: localDeviceID)
            let handler = GADHostIPCRequestHandler(
                hostVersion: hostVersion,
                coordinator: coordinator,
                mode: .authoritative,
                localAdministration: StandaloneLocalAdministration(store: store, commands: commandHandler)
            )
            self.coordinator = coordinator
            self.commandHandler = commandHandler
            self.handler = handler
            observationTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.synchronizeProjection()
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
            }
            return handler
        } catch {
            self.handler = nil
            self.coordinator = nil
            self.store = nil
            try? await lease.release()
            throw error
        }
    }

    private nonisolated static func chatCacheDirectory(store: URL) -> URL {
        let digest = SHA256.hash(data: Data(store.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return cache.appending(path: "com.goby.cli/" + digest, directoryHint: .isDirectory)
    }

    private nonisolated static func installedProviderRuntimeRoot() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        return executable.resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "libexec/provider-runtime", directoryHint: .isDirectory)
    }

    public func stop() async throws {
        observationTask?.cancel()
        await observationTask?.value
        observationTask = nil
        if let coordinator {
            await coordinator.quiesceCommands()
            try await coordinator.flushCheckpoint()
        }
        if let store {
            try await store.prepareForOwnershipTransfer()
            await store.disconnectIdleProvidersForOwnershipTransfer()
            try await store.checkpointOperationalContinuity()
            await store.sealPersistenceForOwnershipTransfer()
        }
        handler = nil
        coordinator = nil
        commandHandler = nil
        store = nil
        try await lease.release()
    }

    private func synchronizeProjection() async {
        guard let commandHandler, let coordinator else { return }
        let current = await coordinator.currentProjection()
        guard let projection = try? await commandHandler.projection(replacing: current) else { return }
        _ = await coordinator.synchronize(projection)
    }

    public var preventsIdleExit: Bool {
        guard let store else { return false }
        return GobyStandaloneIdlePolicy.preventsExit(
            runStatuses: store.runs.map(\.status), pendingApprovalCount: store.pendingApprovals.count,
            automations: store.automationSnapshot, isBusy: store.isBusy || !store.pendingRunControls.isEmpty
        ) || store.temporaryChat?.status == .answering
    }
}

/// Paused or recoverable work stays resident, just like work waiting on approval.
public enum GobyStandaloneIdlePolicy {
    public static func preventsExit(runStatuses: [RunStatus], pendingApprovalCount: Int,
                                   automations: AutomationSnapshot, isBusy: Bool, now: Date = .now) -> Bool {
        isBusy || pendingApprovalCount > 0 || runStatuses.contains { !$0.isFinished && $0 != .draft }
            || automations.occurrences.contains { !$0.status.isFinished }
            || automations.definitions.contains { $0.state == .active && ($0.nextRunAt ?? .distantFuture) <= now.addingTimeInterval(60) }
    }
}

public enum GADFreshStandaloneError: LocalizedError, Sendable {
    case storeLoadFailed(String)
    case preferencesUnavailable

    public var errorDescription: String? {
        switch self {
        case .storeLoadFailed:
            "The CLI store could not load. Review diagnostics before starting another host."
        case .preferencesUnavailable:
            "The CLI could not open its separate preferences domain."
        }
    }
}
