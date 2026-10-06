import Foundation
import OSLog
import GobyApplication
import GobyDomain
import GobyInfrastructure
import GobyOperations
import GobyRemoteTransport

public struct GADHostKeychainNamespace: Sendable {
    public let automation: String
    public let providerCredentials: String
    public let notificationEndpoints: String
    public let pairingRegistry: String
    public let relayAdmission: String
    public let rememberedCommands: String
    public let identifierAlias: String

    public static let app = Self(
        automation: "com.goby.agentic-dashboard.automation-authenticity",
        providerCredentials: "com.goby.agentic-dashboard.provider-credentials",
        notificationEndpoints: "com.goby.agentic-dashboard.notification-endpoints",
        pairingRegistry: "com.demetrisgeorgiou.Goby.pairing-registry",
        relayAdmission: "com.goby.agentic-dashboard.relay-admission",
        rememberedCommands: "com.goby.agentic-dashboard.remembered-commands",
        identifierAlias: "com.goby.agentic-dashboard.remote-identifier-alias"
    )
    public static let cli = Self(
        automation: "com.goby.cli.automation-authenticity",
        providerCredentials: "com.goby.cli.provider-credentials",
        notificationEndpoints: "com.goby.cli.notification-endpoints",
        pairingRegistry: "com.goby.cli.pairing-registry",
        relayAdmission: "com.goby.cli.relay-admission",
        rememberedCommands: "com.goby.cli.remembered-commands",
        identifierAlias: "com.goby.cli.remote-identifier-alias"
    )
    public static let spike = Self(
        automation: "com.goby.cli.spike.automation-authenticity",
        providerCredentials: "com.goby.cli.spike.provider-credentials",
        notificationEndpoints: "com.goby.cli.spike.notification-endpoints",
        pairingRegistry: "com.goby.cli.spike.pairing-registry",
        relayAdmission: "com.goby.cli.spike.relay-admission",
        rememberedCommands: "com.goby.cli.spike.remembered-commands",
        identifierAlias: "com.goby.cli.spike.remote-identifier-alias"
    )

    /// Alternate CLI stores have their own Keychain items too. The caller
    /// supplies a digest of the store identity, never a private path.
    public static func isolatedCLI(scopeDigest: String) -> Self {
        let prefix = "com.goby.cli.store.\(scopeDigest)."
        return Self(automation: prefix + "automation-authenticity",
                    providerCredentials: prefix + "provider-credentials",
                    notificationEndpoints: prefix + "notification-endpoints",
                    pairingRegistry: prefix + "pairing-registry",
                    relayAdmission: prefix + "relay-admission",
                    rememberedCommands: prefix + "remembered-commands",
                    identifierAlias: prefix + "remote-identifier-alias")
    }
}

/// Process-neutral macOS composition used during the one-writer host cutover.
/// It creates the same operational graph for validation in the helper without
/// moving any state or introducing a second persistence location.
@MainActor
public enum GADHostComposition {
    /// Providers parked for the v3 beta. Their adapters, records and history
    /// stay intact; they are simply not registered, so they appear nowhere in
    /// planning, the provider switcher or status. Remove an entry to restore.
    public static let parkedProviderIDs: Set<AgentProviderID> = [.githubCopilot]

    public static let managedWorktreesDirectoryName = "Worktrees"
    /// Builds before 30 September 2026 kept the temporary chat's Codex home
    /// here. It holds a symbolic link and live databases, so ownership
    /// backups must skip it; new builds keep it in Caches instead.
    public static let legacyTemporaryChatDirectoryName = "TemporaryChat"
    public static let temporaryAgentNotesDirectoryName = "Temporary Agent Notes"

    public static func makeStore(
        storeURL: URL,
        localRunNotifier: (any RunNotifying & AutomationNotifying)? = nil,
        automationAuthenticator suppliedAutomationAuthenticator: (any GADAutomationDocumentAuthenticating)? = nil,
        accessGroup: String? = nil,
        keychainNamespace: GADHostKeychainNamespace = .app,
        trustPolicy: any ProviderRuntimeTrustPolicy = AppProviderRuntimeTrustPolicy(),
        temporaryChatSupportDirectoryURL: URL = CodexTemporaryChatService.defaultSupportDirectory(),
        repositoryLockOwnerLabel: String = "Goby app host",
        localDefaults: UserDefaults = .standard,
        providerRuntimeRootURL: URL? = nil,
        parkedProviders: Set<AgentProviderID> = parkedProviderIDs,
        allowsClaudeSubscriptionCredentials: Bool = true,
        usesSavedClaudeCredentialsOnly: Bool = false
    ) -> AppStore {
        let providerBundle = providerRuntimeBundle()
        let codexExecutableURL = trustPolicy.codexExecutableURL()
        let codexValidator = trustPolicy.codexValidator()
        let automationAuthenticator: any GADAutomationDocumentAuthenticating
        if let suppliedAutomationAuthenticator {
            automationAuthenticator = suppliedAutomationAuthenticator
        } else {
#if DEBUG
            if usesIsolatedUITestState() {
                automationAuthenticator = UITestFileAutomationDocumentAuthenticator(
                    directoryURL: storeURL
                )
            } else {
                automationAuthenticator = KeychainAutomationDocumentAuthenticator(
                    scope: storeURL.standardizedFileURL.path(percentEncoded: false),
                    service: keychainNamespace.automation,
                    accessGroup: accessGroup
                )
            }
#else
            automationAuthenticator = KeychainAutomationDocumentAuthenticator(
                scope: storeURL.standardizedFileURL.path(percentEncoded: false),
                service: keychainNamespace.automation,
                accessGroup: accessGroup
            )
#endif
        }
        let persistence = PersistentStore(
            directoryURL: storeURL,
            automationAuthenticator: automationAuthenticator
        )
        let temporaryAgentNotes = LocalTemporaryAgentNotesStore(
            directoryURL: storeURL.appending(
                path: temporaryAgentNotesDirectoryName,
                directoryHint: .isDirectory
            )
        )
        let discovery = FileSystemProjectDiscovery()
        let projectDirectories = LocalProjectDirectoryCreator()
        let projectTemplates = BundledProjectTemplateInstantiator()
        let router = DeterministicRouter()
        let approvals = ApprovalPolicy()
        let graphLayout = RadialGraphLayout()
        let codex = CodexGateway(
            executableURL: codexExecutableURL,
            clientVersion: "0.2.0",
            runtimeValidator: codexValidator
        )
        let providerCredentials = KeychainProviderCredentialStore(
            service: keychainNamespace.providerCredentials,
            accessGroup: accessGroup,
            migratesUnscopedItems: keychainNamespace.providerCredentials == GADHostKeychainNamespace.app.providerCredentials
        )
        var runtimes: [any AgentRuntimeServing] = [
            CodexAgentRuntimeAdapter(codex: codex),
        ]
        var configuredProviderIDs: Set<AgentProviderID> = [.codex]
        var claudeAdapter: ClaudeAgentSDKRuntimeAdapter?
        let claudeInstallation: ClaudeBridgeInstallation?
        if let providerRuntimeRootURL {
            claudeInstallation = cliBridgeInstallation(
                root: providerRuntimeRootURL, name: "ClaudeAgentSDKBridge"
            ).map { ClaudeBridgeInstallation(
                nodeExecutableURL: $0.node, bridgeEntryURL: $0.entry
            ) }
        } else {
            claudeInstallation = InstalledClaudeAgentSDKBridgeLocator.locate(bundle: providerBundle)
        }
        if let claudeInstallation {
            let adapter = ClaudeAgentSDKRuntimeAdapter(
                nodeExecutableURL: claudeInstallation.nodeExecutableURL,
                bridgeEntryURL: claudeInstallation.bridgeEntryURL,
                credentialRepository: providerCredentials,
                integrityBundleURL: providerRuntimeRootURL ?? providerBundle.bundleURL,
                trustPolicy: trustPolicy,
                allowsSubscriptionCredentials: allowsClaudeSubscriptionCredentials,
                usesSavedCredentialsOnly: usesSavedClaudeCredentialsOnly
            )
            runtimes.append(adapter)
            claudeAdapter = adapter
            configuredProviderIDs.insert(.claude)
        }
        let copilotInstallation: CopilotBridgeInstallation?
        if let providerRuntimeRootURL {
            copilotInstallation = cliBridgeInstallation(
                root: providerRuntimeRootURL, name: "CopilotSDKBridge"
            ).map { CopilotBridgeInstallation(
                nodeExecutableURL: $0.node, bridgeEntryURL: $0.entry
            ) }
        } else {
            copilotInstallation = InstalledCopilotSDKBridgeLocator.locate(bundle: providerBundle)
        }
        if !parkedProviders.contains(.githubCopilot),
           let copilotInstallation {
            runtimes.append(CopilotSDKRuntimeAdapter(
                nodeExecutableURL: copilotInstallation.nodeExecutableURL,
                bridgeEntryURL: copilotInstallation.bridgeEntryURL,
                credentialRepository: providerCredentials,
                baseDirectoryURL: storeURL.appending(path: "Copilot", directoryHint: .isDirectory),
                integrityBundleURL: providerRuntimeRootURL ?? providerBundle.bundleURL,
                trustPolicy: trustPolicy
            ))
            configuredProviderIDs.insert(.githubCopilot)
        }
        let runtimeRegistry = AgentRuntimeRegistry(runtimes: runtimes)
        let globalAgentsURL = globalAgentsDirectory()
        let agentDiscovery = CodexAgentDiscovery(globalAgentsURL: globalAgentsURL)
        let agentRestructurer = AgentDefinitionRestructurer()
        let agentDefinitions = CodexAgentDefinitionStore(globalAgentsURL: globalAgentsURL)
        let preflight: SystemPreflight
#if DEBUG
        if usesIsolatedUITestState() {
            // UI journeys exercise Goby's product flow, not Apple's code-
            // signing implementation. Avoid system trust evaluation in the
            // launched test app so Security.framework cannot add an unrelated
            // performance warning or authorization surface to those journeys.
            preflight = SystemPreflight(
                codexURL: codexExecutableURL,
                storageURL: storeURL,
                codexRuntimeValidator: GADUITestCodexRuntimeValidator()
            )
        } else {
            preflight = SystemPreflight(
                codexURL: codexExecutableURL,
                storageURL: storeURL,
                codexRuntimeValidator: codexValidator
            )
        }
#else
        preflight = SystemPreflight(
            codexURL: codexExecutableURL,
            storageURL: storeURL,
            codexRuntimeValidator: codexValidator
        )
#endif
        let worktreesURL = storeURL.appending(
            path: managedWorktreesDirectoryName,
            directoryHint: .isDirectory
        )
        let workspaces = GitWorkspaceManager(
            worktreesRoot: worktreesURL,
            approvals: approvals,
            repositoryLockOwnerLabel: repositoryLockOwnerLabel,
            holdsRepositoryLockThroughRun: true
        )
        let projectBranches = LocalProjectGitBranchManager()
        let verifier = ProjectVerifier()
        let relayAdmissions = relayHostAdmissionStore(
            accessGroup: accessGroup,
            service: keychainNamespace.relayAdmission
        )
        let notifier = GADHostRunNotifier(
            local: localRunNotifier ?? LocalRunNotifier(),
            profiles: GADPairingProfileRegistry(
                service: keychainNamespace.pairingRegistry,
                accessGroup: accessGroup
            ),
            registrations: KeychainNotificationRegistrationStore(
                service: keychainNamespace.notificationEndpoints,
                accessGroup: accessGroup
            ),
            relayAdmissions: relayAdmissions
        )
        let diagnostics = RedactedDiagnosticExporter()
        let orchestrator = ProviderRunOrchestrator(
            catalog: persistence,
            runs: persistence,
            runtimes: runtimeRegistry,
            workspaces: workspaces,
            verifier: verifier,
            notifier: notifier,
            handoffCatalog: persistence,
            automationAuthority: persistence,
            rememberedApprovals: KeychainRememberedCommandApprovals(
                scope: storeURL.standardizedFileURL.path,
                service: keychainNamespace.rememberedCommands,
                accessGroup: accessGroup
            ),
            automationRepository: persistence
        )
        let automationCoordinator = AutomationCoordinator(
            repository: persistence,
            catalog: persistence,
            router: router,
            instructions: persistence,
            resources: persistence,
            approvals: approvals,
            orchestrator: orchestrator,
            notifier: notifier
        )

        return AppStore(
            loadDashboard: LoadDashboardUseCase(catalog: persistence, runs: persistence),
            discoverProjects: DiscoverProjectsUseCase(discovery: discovery),
            discoverCodexCatalogSync: DiscoverCodexCatalogSyncUseCase(
                catalog: persistence,
                codex: codex,
                projectDiscovery: discovery,
                agentDiscovery: agentDiscovery
            ),
            discoverCodexActivity: DiscoverCodexActivityUseCase(codex: codex),
            syncCodexCatalog: SyncCodexCatalogUseCase(catalog: persistence),
            registerProjects: RegisterProjectsUseCase(catalog: persistence),
            createProject: CreateProjectUseCase(
                catalog: persistence,
                projectCatalog: persistence,
                groups: persistence,
                agentCatalog: persistence,
                providerConfigurations: persistence,
                handoffs: persistence,
                definitions: agentDefinitions,
                directories: projectDirectories,
                templates: projectTemplates,
                configuredProviderIDs: configuredProviderIDs
            ),
            removeProject: RemoveProjectUseCase(catalog: persistence, runs: persistence),
            saveProjectGroup: SaveProjectGroupUseCase(catalog: persistence, groups: persistence),
            removeProjectGroup: RemoveProjectGroupUseCase(catalog: persistence, groups: persistence),
            preparePlan: PrepareRoutingPlanUseCase(catalog: persistence, router: router),
            stageRun: StageRunUseCase(
                repository: persistence,
                catalog: persistence,
                instructions: persistence,
                resources: persistence,
                approvals: approvals,
                automationAuthority: persistence
            ),
            buildGraph: BuildGraphUseCase(catalog: persistence, layout: graphLayout),
            loadMapLayout: LoadMapLayoutUseCase(repository: persistence),
            saveMapLayout: SaveMapLayoutUseCase(repository: persistence),
            inspectCodex: InspectCodexUseCase(codex: codex),
            discoverAgents: DiscoverAgentsUseCase(catalog: persistence, discovery: agentDiscovery),
            registerAgents: RegisterAgentsUseCase(catalog: persistence),
            previewAgentRestructure: PreviewAgentRestructureUseCase(restructurer: agentRestructurer),
            applyAgentRestructure: ApplyAgentRestructureUseCase(restructurer: agentRestructurer),
            undoAgentRestructure: UndoAgentRestructureUseCase(restructurer: agentRestructurer),
            loadAgentRestructureHistory: LoadAgentRestructureHistoryUseCase(repository: persistence),
            saveAgentRestructureHistory: SaveAgentRestructureHistoryUseCase(repository: persistence),
            executeRun: ExecuteRunUseCase(orchestrator: orchestrator),
            controlRun: ControlRunUseCase(orchestrator: orchestrator),
            followUpRun: FollowUpRunUseCase(orchestrator: orchestrator),
            observeRuns: ObserveRunsUseCase(orchestrator: orchestrator),
            manageApproval: ManageProviderApprovalUseCase(orchestrator: orchestrator),
            recoverInterruptedRuns: RecoverInterruptedRunsUseCase(orchestrator: orchestrator),
            checkSystemHealth: CheckSystemHealthUseCase(catalog: persistence, checker: preflight),
            loadInstructions: LoadInstructionsUseCase(repository: persistence),
            saveInstruction: SaveInstructionUseCase(repository: persistence),
            createAgent: CreateAgentUseCase(
                repository: persistence,
                catalog: persistence,
                definitions: agentDefinitions
            ),
            createTemporaryAgent: CreateTemporaryAgentUseCase(
                catalog: persistence,
                agents: persistence,
                providers: persistence,
                notes: temporaryAgentNotes
            ),
            retireTemporaryAgent: RetireTemporaryAgentUseCase(
                catalog: persistence,
                agents: persistence
            ),
            recordTemporaryAgentNotes: RecordTemporaryAgentNotesUseCase(store: temporaryAgentNotes),
            setAgentEnabled: SetAgentEnabledUseCase(repository: persistence),
            updateProviderBindingInstructions: UpdateProviderBindingInstructionsUseCase(
                catalog: persistence,
                providerConfigurations: persistence
            ),
            inspectProviderCredential: InspectProviderCredentialUseCase(repository: providerCredentials),
            saveProviderCredential: SaveProviderCredentialUseCase(repository: providerCredentials),
            removeProviderCredential: RemoveProviderCredentialUseCase(repository: providerCredentials),
            publishAgentToCodex: PublishAgentToCodexUseCase(
                repository: persistence,
                catalog: persistence,
                definitions: agentDefinitions
            ),
            deleteAgent: DeleteAgentUseCase(
                repository: persistence,
                catalog: persistence,
                definitions: agentDefinitions,
                history: persistence
            ),
            loadDeletedAgentHistory: LoadDeletedAgentHistoryUseCase(history: persistence),
            restoreDeletedAgent: RestoreDeletedAgentUseCase(
                repository: persistence,
                definitions: agentDefinitions,
                history: persistence
            ),
            generateDiagnostics: GenerateDiagnosticsUseCase(exporter: diagnostics),
            loadSharedResources: LoadSharedResourcesUseCase(repository: persistence),
            registerSharedResources: RegisterSharedResourcesUseCase(repository: persistence),
            setSharedResourceEnabled: SetSharedResourceEnabledUseCase(repository: persistence),
            setSharedResourceAccess: SetSharedResourceAccessUseCase(repository: persistence),
            setSharedResourceSettings: SetSharedResourceSettingsUseCase(repository: persistence),
            prepareManualHandoff: PrepareManualHandoffUseCase(
                catalog: persistence,
                runs: persistence,
                handoffs: persistence,
                credentials: providerCredentials
            ),
            dispatchManualHandoff: DispatchManualHandoffUseCase(
                catalog: persistence,
                runs: persistence,
                handoffs: persistence
            ),
            runtimeRegistry: runtimeRegistry,
            operationalContinuityRepository: persistence,
            coordinatorCheckpointRepository: persistence,
            persistenceOwnership: persistence,
            inspectProjectGitBranches: InspectProjectGitBranchesUseCase(
                catalog: persistence,
                branches: projectBranches
            ),
            switchProjectGitBranch: SwitchProjectGitBranchUseCase(
                catalog: persistence,
                branches: projectBranches
            ),
            loadAutomations: LoadAutomationsUseCase(repository: persistence),
            saveAutomation: SaveAutomationUseCase(
                repository: persistence,
                catalog: persistence
            ),
            setAutomationState: SetAutomationStateUseCase(repository: persistence),
            deleteAutomation: DeleteAutomationUseCase(repository: persistence),
            automationCoordinator: automationCoordinator,
            addMissingAutomationAgents: AddMissingAutomationAgentsUseCase(
                catalog: persistence,
                automations: persistence,
                createAgent: CreateAgentUseCase(
                    repository: persistence,
                    catalog: persistence,
                    definitions: agentDefinitions
                )
            ),
            temporaryChatService: ProviderTemporaryChatService(services: temporaryChatServices(
                codex: CodexTemporaryChatService(
                    executableURL: codexExecutableURL,
                    clientVersion: "0.2.0",
                    // Never inside the store: ownership backups reject symbolic
                    // links and live files there.
                    supportDirectoryURL: temporaryChatSupportDirectoryURL,
                    runtimeValidator: codexValidator
                ),
                claude: claudeAdapter
            )),
            promptAttachmentDirectoryURL: storeURL.appending(path: "PromptAttachments", directoryHint: .isDirectory),
            localDefaults: localDefaults
        )
    }

    /// Packaged provider runtimes live once in the outer app. A launch-agent
    /// helper resolves that sealed container instead of silently omitting
    /// Claude and Copilot when it becomes the canonical owner.
    private static func providerRuntimeBundle() -> Bundle {
        let running = Bundle.main.bundleURL.standardizedFileURL
        let loginItems = running.deletingLastPathComponent()
        let library = loginItems.deletingLastPathComponent()
        let contents = library.deletingLastPathComponent()
        let outer = contents.deletingLastPathComponent()
        guard loginItems.lastPathComponent == "LoginItems",
              library.lastPathComponent == "Library",
              contents.lastPathComponent == "Contents",
              let bundle = Bundle(url: outer),
              bundle.bundleIdentifier == "com.demetrisgeorgiou.GobyAgenticDashboard" else {
            return .main
        }
        return bundle
    }

    private static func cliBridgeInstallation(
        root: URL,
        name: String
    ) -> (node: URL, entry: URL)? {
        let directory = root.appending(path: name, directoryHint: .isDirectory)
        let node = directory.appending(path: "bin/node")
        let entry = directory.appending(path: "index.js")
        guard FileManager.default.isExecutableFile(atPath: node.path(percentEncoded: false)),
              FileManager.default.isReadableFile(atPath: entry.path(percentEncoded: false)) else {
            return nil
        }
        return (node, entry)
    }

    nonisolated public static func storeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = nil
    ) -> URL {
#if DEBUG
        if let path = environment["GOBY_UI_TEST_DATA_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
#endif
        let base = applicationSupportDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appending(path: "Goby Agentic Dashboard", directoryHint: .isDirectory)
    }

    nonisolated public static func cliStoreDirectory(
        applicationSupportDirectory: URL? = nil
    ) -> URL {
        let base = applicationSupportDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Goby CLI", directoryHint: .isDirectory)
    }

    nonisolated public static func hostSupportDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = nil
    ) -> URL {
#if DEBUG
        if let path = environment["GOBY_UI_TEST_DATA_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .appending(path: "Host Support", directoryHint: .isDirectory)
        }
#else
        _ = environment
#endif
        let base = applicationSupportDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appending(path: "Goby Agentic Dashboard Host", directoryHint: .isDirectory)
    }

    nonisolated public static func usesIsolatedUITestState(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
#if DEBUG
        environment["GOBY_UI_TEST_DATA_ROOT"].map { !$0.isEmpty } ?? false
#else
        _ = environment
        return false
#endif
    }

    /// Codex always offers temporary chat; Claude does when its bridge is installed.
    static func temporaryChatServices(
        codex: CodexTemporaryChatService,
        claude: ClaudeAgentSDKRuntimeAdapter?
    ) -> [AgentProviderID: any TemporaryChatServing] {
        var services: [AgentProviderID: any TemporaryChatServing] = [.codex: codex]
        if let claude {
            services[.claude] = ClaudeTemporaryChatService { prompt, model in
                try await claude.askTemporaryChat(prompt: prompt, model: model)
            }
        }
        return services
    }

    public static func relayHostAdmissionStore(
        accessGroup: String?,
        service: String = GADHostKeychainNamespace.app.relayAdmission
    ) -> any GADRelayHostAdmissionPersisting {
#if DEBUG
        if usesIsolatedUITestState() {
            return GADUITestRelayHostAdmissionStore()
        }
#endif
        return KeychainRelayHostAdmissionStore(service: service, accessGroup: accessGroup)
    }

    public static func remoteAccessDefaults() -> UserDefaults {
#if DEBUG
        if usesIsolatedUITestState() {
            let suiteName = "com.demetrisgeorgiou.GobyAgenticDashboard.ui-tests.\(ProcessInfo.processInfo.processIdentifier)"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            return defaults
        }
#endif
        return .standard
    }

    public static func uiTestRunNotifier() -> (any RunNotifying & AutomationNotifying)? {
#if DEBUG
        if usesIsolatedUITestState() {
            return GADUITestRunNotifier()
        }
#endif
        return nil
    }

    private static func globalAgentsDirectory() -> URL {
#if DEBUG
        if let path = ProcessInfo.processInfo.environment["GOBY_UI_TEST_CODEX_AGENTS_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
#endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/agents", directoryHint: .isDirectory)
            .standardizedFileURL
    }
}

#if DEBUG
private struct GADUITestCodexRuntimeValidator: CodexRuntimeValidating {
    func validate(executableURL: URL) throws {
        _ = executableURL
    }

    func validateRunningProcess(processIdentifier: Int32, executableURL: URL) throws {
        _ = processIdentifier
        _ = executableURL
    }
}

private struct GADUITestRunNotifier: RunNotifying, AutomationNotifying {
    func notify(for run: RunRecord) async {
        _ = run
    }

    func notify(for occurrence: AutomationOccurrence) async {
        _ = occurrence
    }
}

private actor GADUITestRelayHostAdmissionStore: GADRelayHostAdmissionPersisting {
    private var storedCredential: GADRelayHostAdmissionCredential?

    func credential() async throws -> GADRelayHostAdmissionCredential? {
        storedCredential
    }

    func save(_ credential: GADRelayHostAdmissionCredential) async throws {
        storedCredential = credential
    }

    func remove() async throws {
        storedCredential = nil
    }
}
#endif

public actor GADHostRunNotifier: RunNotifying, AutomationNotifying {
    private let local: any RunNotifying & AutomationNotifying
    private let profiles: GADPairingProfileRegistry
    private let registrations: any GADNotificationRegistrationPersisting
    private let relay: GADRelayNotificationClient
    private let relayAdmissions: any GADRelayHostAdmissionPersisting

    public init(
        local: any RunNotifying & AutomationNotifying,
        profiles: GADPairingProfileRegistry,
        registrations: any GADNotificationRegistrationPersisting,
        relayAdmissions: any GADRelayHostAdmissionPersisting,
        relay: GADRelayNotificationClient = .init()
    ) {
        self.local = local
        self.profiles = profiles
        self.registrations = registrations
        self.relayAdmissions = relayAdmissions
        self.relay = relay
    }

    public func notify(for run: RunRecord) async {
        await local.notify(for: run)
        let category: GADNotificationCategory
        switch run.status {
        case .completed:
            category = .runFinished
        case .failed, .needsAttention:
            category = .needsAttention
        default:
            return
        }
        await notifyRemotely(category)
    }

    public func notify(for occurrence: AutomationOccurrence) async {
        guard occurrence.status == .needsAttention else { return }
        await local.notify(for: occurrence)
        await notifyRemotely(.needsAttention)
    }

    private func notifyRemotely(_ category: GADNotificationCategory) async {
        guard let pairedProfiles = try? await profiles.profiles() else { return }
        guard let admission = try? await relayAdmissions.credential() else { return }
        for profile in pairedProfiles where profile.requiresRelayRepair {
            // A profile that cannot carry current command authority must not
            // retain a side channel through an older APNs route.
            try? await registrations.remove(for: profile.deviceID)
        }
        for profile in Self.notificationEligibleProfiles(pairedProfiles) {
            guard let registration = try? await registrations.registration(for: profile.deviceID),
                  registration.categories.contains(category) else { continue }
            try? await relay.send(category, for: profile, hostAdmission: admission)
        }
    }

    public static func notificationEligibleProfiles(
        _ profiles: [GADPairingProfile]
    ) -> [GADPairingProfile] {
        profiles.filter { !$0.requiresRelayRepair }
    }
}
