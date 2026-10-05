import Darwin
import Dispatch
import Foundation
import GobyApplication
import GobyDomain
import GobyHostCore
import GobyInfrastructure

public struct GobyCLIConfiguration: Sendable {
    public let storeDirectory: URL
    public let socketURL: URL
    public let executableURL: URL
    public let hostVersion: String
    public let idleTimeout: TimeInterval
    public init(storeDirectory: URL, executableURL: URL, hostVersion: String, idleTimeout: TimeInterval = 300) {
        self.storeDirectory = GobySocketIO.canonicalLocation(storeDirectory)
        socketURL = self.storeDirectory.appending(path: "run/host.sock")
        self.executableURL = executableURL
        self.hostVersion = hostVersion
        self.idleTimeout = idleTimeout
    }
}

/// Drain admission is separate from checkpoint sealing: existing runs retain
/// their approvals and run controls until they finish.
public actor GobyCLIHostRouter: GADHostIPCRequestHandling {
    private let handler: any GADHostIPCRequestHandling
    private let version: String
    private var draining = false
    private var shuttingDown = false
    private var inFlight = 0
    private var lastActivity: Date = .now
    public init(handler: any GADHostIPCRequestHandling, version: String) {
        self.handler = handler
        self.version = version
    }
    public func handle(_ request: GADHostIPCRequest) async -> GADHostIPCResponse {
        lastActivity = .now
        if !shuttingDown, request.operation == .localAdministration(.preparePermanentHostShutdown) {
            // This control is intentionally decodable across IPC schema versions
            // so an old host can drain before a new client negotiates normally.
            draining = true
            return .init(requestID: request.requestID, hostVersion: version, generatedAt: .now,
                         isReadOnly: false, artifact: .localReceipt(.init(id: "cli-drain",
                         summary: "The CLI host will checkpoint and stop after active work and approvals finish.", isUndoAvailable: false)))
        }
        if shuttingDown || (draining && !Self.allowedDuringDrain(request.operation)) {
            return .init(requestID: request.requestID, hostVersion: version, generatedAt: .now,
                         isReadOnly: true, failureDisposition: .rejectedCapability,
                         error: "The CLI host is draining. Finish or cancel active work before starting new work.")
        }
        inFlight += 1
        defer { inFlight -= 1 }
        return await handler.handle(request)
    }
    private static func allowedDuringDrain(_ operation: GADHostIPCOperation) -> Bool {
        switch operation {
        case .ping, .connect, .snapshot, .events, .disconnect: true
        case let .send(command):
            switch command.payload {
            case .controlRun, .requestApprovalDisclosure, .respondToApproval, .reviewAndRunAutomationOccurrence, .cancelAutomationOccurrence: true
            case let .setAutomationState(mutation): mutation.state == .paused
            default: false
            }
        case let .localAdministration(command):
            switch command {
            case .inspectLocalCatalog, .inspectLocalRun, .inspectLocalRunDiff: true
            default: false
            }
        default: false
        }
    }
    public func shouldExit(now: Date, idleTimeout: TimeInterval, busy: Bool) -> Bool {
        !busy && inFlight == 0 && (draining || now.timeIntervalSince(lastActivity) >= idleTimeout)
    }
    public func closeAdmission() { shuttingDown = true }
    public var hasInFlightRequests: Bool { inFlight > 0 }
}

@MainActor
public final class GobyCLIHostService {
    private let configuration: GobyCLIConfiguration
    private let runtime: GADFreshStandaloneRuntime
    private var listener: GobyUnixSocketListener?
    private var router: GobyCLIHostRouter?
    private var signals: [DispatchSourceSignal] = []
    private var terminationRequested = false

    public init(configuration: GobyCLIConfiguration, runtime: GADFreshStandaloneRuntime) {
        self.configuration = configuration
        self.runtime = runtime
    }
    public func run() async throws {
        installSignals()
        defer { signals.forEach { $0.cancel() }; signals.removeAll() }
        let handler = try await runtime.start(hostVersion: configuration.hostVersion)
        let router = GobyCLIHostRouter(handler: handler, version: configuration.hostVersion)
        let listener = GobyUnixSocketListener(socketURL: configuration.socketURL, handler: router)
        self.router = router
        self.listener = listener
        do {
            try await listener.start()
            while !terminationRequested {
                if await router.shouldExit(now: .now, idleTimeout: configuration.idleTimeout, busy: runtime.preventsIdleExit) { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            await router.closeAdmission()
            while await router.hasInFlightRequests { try await Task.sleep(for: .milliseconds(50)) }
            try await runtime.stop()
            // Keep the endpoint present until the writer lease is released;
            // replacement clients must never observe an absent socket while
            // the old process is still checkpointing.
            await listener.stop()
            signals.forEach { $0.cancel() }
            signals.removeAll()
        } catch {
            await router.closeAdmission()
            await listener.stop()
            try? await runtime.stop()
            signals.forEach { $0.cancel() }
            signals.removeAll()
            throw error
        }
    }
    private func installSignals() {
        signal(SIGHUP, SIG_IGN)
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.terminationRequested = true } }
            source.resume()
            signals.append(source)
        }
    }
    public func requestTermination() { terminationRequested = true }
}

public protocol GobyHostLaunching: Sendable {
    func launch(configuration: GobyCLIConfiguration) async throws
}
public actor GobyProcessHostLauncher: GobyHostLaunching {
    public init() {}
    public func launch(configuration: GobyCLIConfiguration) throws {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw GobySocketError.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw GobySocketError.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw GobySocketError.unavailable }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0) == 0 else { throw GobySocketError.unavailable }
        }
        let strings = [configuration.executableURL.path, "host", "run", "--store", configuration.storeDirectory.path]
        var argv = strings.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = argv.withUnsafeMutableBufferPointer { arguments in
            posix_spawn(&pid, configuration.executableURL.path, &actions, &attributes, arguments.baseAddress!, environ)
        }
        guard status == 0 else { throw GobySocketError.unavailable }
        // A separate process group keeps terminal Ctrl-C away from the host.
        // Reap if this client remains attached; launchd adopts it if we exit.
        let child = pid
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        }
    }
}

/// A per-user flock serializes startup across processes. The store lease is
/// the second, independent barrier for a manually started host.
public actor GobyLazyHostConnection {
    private let configuration: GobyCLIConfiguration
    private let launcher: any GobyHostLaunching
    public init(configuration: GobyCLIConfiguration, launcher: any GobyHostLaunching = GobyProcessHostLauncher()) {
        self.configuration = configuration
        self.launcher = launcher
    }
    public func connect() async throws -> GobyUnixSocketTransport {
        let transport = GobyUnixSocketTransport(socketURL: configuration.socketURL)
        if try await compatible(transport) { return transport }
        try GobySocketIO.secureDirectory(configuration.socketURL.deletingLastPathComponent())
        let lockURL = configuration.socketURL.deletingLastPathComponent().appending(path: "start.lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw GobySocketError.unsafePath }
        defer { flock(fd, LOCK_UN); close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw GobySocketError.unsafePath }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, clock.now < deadline else { throw GobySocketError.unavailable }
            try await Task.sleep(for: .milliseconds(100))
        }
        if try await compatible(transport) { return transport }
        // If a different host is still answering, request a drain and return
        // needs-host status. Never kill it or start a competing writer.
        if let ping = try? await transport.exchange(.init(operation: .ping)) {
            if ping.hostVersion != configuration.hostVersion || ping.protocolVersion != GADHostIPCRequest.currentProtocolVersion {
                _ = try await transport.exchange(.init(operation: .localAdministration(.preparePermanentHostShutdown)))
                let drainDeadline = clock.now.advanced(by: .seconds(2))
                while clock.now < drainDeadline {
                    try await Task.sleep(for: .milliseconds(100))
                    if (try? await transport.exchange(.init(operation: .ping))) == nil { break }
                }
                if (try? await transport.exchange(.init(operation: .ping))) != nil { throw GobySocketError.incompatibleVersion }
            } else { throw GobySocketError.unavailable }
        }
        try await launcher.launch(configuration: configuration)
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            if try await compatible(transport) { return transport }
        }
        throw GobySocketError.startupTimedOut
    }
    private func compatible(_ transport: GobyUnixSocketTransport) async throws -> Bool {
        do {
            let response = try await transport.exchange(.init(operation: .ping))
            return response.error == nil && !response.isReadOnly
                && response.hostVersion == configuration.hostVersion
                && response.protocolVersion == GADHostIPCRequest.currentProtocolVersion
        } catch GobySocketError.unavailable { return false }
    }
}
