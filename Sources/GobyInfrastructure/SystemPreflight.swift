import Darwin
import Foundation
import GobyApplication
import GobyDomain

public actor SystemPreflight: SystemHealthChecking {
    private let codexURL: URL
    private let storageURL: URL
    private let fileManager: SendableFileManager
    private let codexRuntimeValidator: any CodexRuntimeValidating
    private let commandTimeout: TimeInterval
    private let maximumCommandOutputBytes: Int

    public init(
        codexURL: URL,
        storageURL: URL,
        fileManager: FileManager = .default,
        codexRuntimeValidator: any CodexRuntimeValidating = CodexRuntimeIntegrityValidator(),
        commandTimeout: TimeInterval = 15,
        maximumCommandOutputBytes: Int = 256 * 1_024
    ) {
        self.codexURL = codexURL
        self.storageURL = storageURL
        self.fileManager = SendableFileManager(fileManager)
        self.codexRuntimeValidator = codexRuntimeValidator
        self.commandTimeout = max(0.1, commandTimeout)
        self.maximumCommandOutputBytes = max(1_024, maximumCommandOutputBytes)
    }

    public func check(projects: [LabProject]) async -> SystemHealthSnapshot {
        let codexURL = self.codexURL
        let storageURL = self.storageURL
        let fileManager = self.fileManager
        let codexRuntimeValidator = self.codexRuntimeValidator
        let commandTimeout = self.commandTimeout
        let maximumCommandOutputBytes = self.maximumCommandOutputBytes

        return await Task.detached(priority: .userInitiated) {
            Self.checkSynchronously(
                projects: projects,
                codexURL: codexURL,
                storageURL: storageURL,
                fileManager: fileManager.value,
                codexRuntimeValidator: codexRuntimeValidator,
                commandTimeout: commandTimeout,
                maximumCommandOutputBytes: maximumCommandOutputBytes
            )
        }.value
    }

    /// Foundation documents FileManager instances as safe to use from
    /// multiple threads. Keep the injected dependency explicit while making
    /// that guarantee visible to Swift's strict-concurrency checker.
    private struct SendableFileManager: @unchecked Sendable {
        let value: FileManager

        init(_ value: FileManager) {
            self.value = value
        }
    }

    nonisolated private static func checkSynchronously(
        projects: [LabProject],
        codexURL: URL,
        storageURL: URL,
        fileManager: FileManager,
        codexRuntimeValidator: any CodexRuntimeValidating,
        commandTimeout: TimeInterval,
        maximumCommandOutputBytes: Int
    ) -> SystemHealthSnapshot {
        var checks: [HealthCheck] = []
        let version = ProcessInfo.processInfo.operatingSystemVersion
        checks.append(.init(
            kind: .operatingSystem,
            status: version.majorVersion >= 26 ? .passed : .failed,
            summary: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            detail: version.majorVersion >= 26 ? nil : "Goby requires macOS 26 or newer."
        ))
        checks.append(toolCheck(
            kind: .codex,
            executable: codexURL.path(percentEncoded: false),
            arguments: ["--version"],
            fileManager: fileManager,
            runtimeValidator: codexRuntimeValidator,
            timeout: commandTimeout,
            maximumOutputBytes: maximumCommandOutputBytes
        ))
        checks.append(appServerSchemaCheck(
            codexURL: codexURL,
            fileManager: fileManager,
            codexRuntimeValidator: codexRuntimeValidator,
            timeout: commandTimeout,
            maximumOutputBytes: maximumCommandOutputBytes
        ))
        checks.append(toolCheck(
            kind: .git,
            executable: "/usr/bin/git",
            arguments: ["--version"],
            fileManager: fileManager,
            timeout: commandTimeout,
            maximumOutputBytes: maximumCommandOutputBytes
        ))
        checks.append(toolCheck(
            kind: .xcode,
            executable: "/usr/bin/xcodebuild",
            arguments: ["-version"],
            fileManager: fileManager,
            timeout: commandTimeout,
            maximumOutputBytes: maximumCommandOutputBytes
        ))

        let storageParent = storageURL.deletingLastPathComponent()
        checks.append(.init(
            kind: .storage,
            status: fileManager.isWritableFile(atPath: storageParent.path(percentEncoded: false)) ? .passed : .failed,
            summary: fileManager.isWritableFile(atPath: storageParent.path(percentEncoded: false)) ? "Application Support is writable" : "Application Support is not writable",
            detail: storageURL.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")
        ))

        let deferredProtectedRoots = projects.filter {
            Self.defersAutomaticAccessCheck(
                for: $0.rootURL,
                homeDirectory: fileManager.homeDirectoryForCurrentUser
            )
        }
        let protectedRootIDs = Set(deferredProtectedRoots.map(\.id))
        let missing = projects.filter {
            !protectedRootIDs.contains($0.id)
                && !fileManager.fileExists(atPath: $0.rootURL.path(percentEncoded: false))
        }
        let rootSummary: String
        let rootDetail: String?
        if !missing.isEmpty {
            rootSummary = "\(missing.count) registered roots are missing"
            rootDetail = missing.map(\.name).joined(separator: ", ")
        } else if !deferredProtectedRoots.isEmpty {
            rootSummary = "\(projects.count) registered roots; \(deferredProtectedRoots.count) protected roots verify when used"
            rootDetail = "Desktop, Documents, and Downloads are not opened automatically during startup."
        } else {
            rootSummary = "All \(projects.count) registered roots are available"
            rootDetail = nil
        }
        checks.append(.init(
            kind: .projectRoots,
            status: missing.isEmpty ? .passed : .warning,
            summary: rootSummary,
            detail: rootDetail
        ))
        return SystemHealthSnapshot(checks: checks)
    }

    static func defersAutomaticAccessCheck(for rootURL: URL, homeDirectory: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path(percentEncoded: false)
        let homePath = homeDirectory.standardizedFileURL.path(percentEncoded: false)
        let separator = homePath.hasSuffix("/") ? "" : "/"
        return ["Desktop", "Documents", "Downloads"].contains { folder in
            let protectedPath = homePath + separator + folder
            return rootPath == protectedPath || rootPath.hasPrefix(protectedPath + "/")
        }
    }

    nonisolated private static func toolCheck(
        kind: HealthCheckKind,
        executable: String,
        arguments: [String],
        fileManager: FileManager,
        runtimeValidator: (any CodexRuntimeValidating)? = nil,
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) -> HealthCheck {
        guard fileManager.isExecutableFile(atPath: executable) else {
            return .init(kind: kind, status: .failed, summary: "Not found", detail: executable)
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try runtimeValidator?.validate(
                executableURL: URL(fileURLWithPath: executable)
            )
            try process.run()
            let outputHandle = pipe.fileHandleForReading
            let output = PreflightProcessOutput(maximumBytes: maximumOutputBytes)
            let drainFinished = DispatchSemaphore(value: 0)
            // The enclosing preflight job is user-initiated because the
            // readiness result is surfaced immediately. Keep its pipe drain
            // and timeout observer at the same QoS so the synchronous process
            // wait cannot create a priority inversion.
            DispatchQueue.global(qos: .userInitiated).async {
                output.drain(outputHandle)
                drainFinished.signal()
            }
            let deadline = PreflightProcessDeadline()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning, deadline.beginTimeout() else { return }
                Self.terminateAndEscalate(process)
            }
            var runningValidationError: (any Error)?
            do {
                try runtimeValidator?.validateRunningProcess(
                    processIdentifier: process.processIdentifier,
                    executableURL: URL(fileURLWithPath: executable)
                )
            } catch {
                runningValidationError = error
                Self.terminateAndEscalate(process)
            }
            process.waitUntilExit()
            deadline.finish()
            if drainFinished.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
                try? outputHandle.close()
                guard drainFinished.wait(timeout: .now() + .milliseconds(250)) == .success else {
                    throw PreflightProcessError.outputStreamDidNotClose
                }
            }
            if deadline.didTimeOut {
                throw PreflightProcessError.timedOut
            }
            if output.exceededLimit {
                throw PreflightProcessError.outputTooLarge
            }
            if let runningValidationError { throw runningValidationError }
            let outputText = String(decoding: output.snapshot(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(
                kind: kind,
                status: process.terminationStatus == 0 ? .passed : .warning,
                summary: outputText.split(separator: "\n").first.map(String.init) ?? "Available",
                detail: executable
            )
        } catch {
            return .init(kind: kind, status: .failed, summary: error.localizedDescription, detail: executable)
        }
    }

    nonisolated private static func appServerSchemaCheck(
        codexURL: URL,
        fileManager: FileManager,
        codexRuntimeValidator: any CodexRuntimeValidating,
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) -> HealthCheck {
        guard fileManager.isExecutableFile(atPath: codexURL.path(percentEncoded: false)) else {
            return .init(kind: .appServerProtocol, status: .failed, summary: "Codex is unavailable")
        }
        let directory = fileManager.temporaryDirectory
            .appending(path: "goby-schema-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: directory) }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let result = toolCheck(
                kind: .appServerProtocol,
                executable: codexURL.path(percentEncoded: false),
                arguments: ["app-server", "generate-json-schema", "--out", directory.path(percentEncoded: false)],
                fileManager: fileManager,
                runtimeValidator: codexRuntimeValidator,
                timeout: timeout,
                maximumOutputBytes: maximumOutputBytes
            )
            guard result.status == .passed else { return result }
            let requestSchema = directory.appending(path: "ClientRequest.json")
            let serverRequestSchema = directory.appending(path: "ServerRequest.json")
            let serverNotificationSchema = directory.appending(path: "ServerNotification.json")
            let clientSchema = try String(contentsOf: requestSchema, encoding: .utf8)
            let serverSchema = try String(contentsOf: serverRequestSchema, encoding: .utf8)
            let notificationSchema = try String(contentsOf: serverNotificationSchema, encoding: .utf8)
            let requiredClientMethods = ["initialize", "thread/start", "turn/start", "turn/interrupt", "account/read"]
            let requiredServerMethods = [
                "item/commandExecution/requestApproval",
                "item/fileChange/requestApproval",
                "item/permissions/requestApproval"
            ]
            let requiredNotificationFeatures = [
                "item/completed",
                "commandExecution",
                "commandActions",
                "cwd",
                "status",
                "exitCode",
                "source"
            ]
            let missing = requiredClientMethods.filter { !clientSchema.contains($0) }
                + requiredServerMethods.filter { !serverSchema.contains($0) }
                + requiredNotificationFeatures.filter { !notificationSchema.contains($0) }
            guard missing.isEmpty else {
                return .init(
                    kind: .appServerProtocol,
                    status: .failed,
                    summary: "Incompatible schema",
                    detail: "Missing: \(missing.joined(separator: ", "))"
                )
            }
            return .init(
                kind: .appServerProtocol,
                status: .passed,
                summary: "Required methods available",
                detail: "Schema generated by the installed Codex"
            )
        } catch {
            return .init(
                kind: .appServerProtocol,
                status: .failed,
                summary: "Schema validation failed",
                detail: error.localizedDescription
            )
        }
    }

    nonisolated private static func terminateAndEscalate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(1)) {
            guard process.isRunning else { return }
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private enum PreflightProcessError: LocalizedError {
        case timedOut
        case outputTooLarge
        case outputStreamDidNotClose

        var errorDescription: String? {
            switch self {
            case .timedOut:
                "The command timed out."
            case .outputTooLarge:
                "The command returned too much output."
            case .outputStreamDidNotClose:
                "The command did not close its output stream."
            }
        }
    }

    private final class PreflightProcessDeadline: @unchecked Sendable {
        private enum State {
            case pending
            case timedOut
            case finished
        }

        private let lock = NSLock()
        private var state = State.pending

        var didTimeOut: Bool {
            lock.withLock { state == .timedOut }
        }

        func beginTimeout() -> Bool {
            lock.withLock {
                guard state == .pending else { return false }
                state = .timedOut
                return true
            }
        }

        func finish() {
            lock.withLock {
                guard state == .pending else { return }
                state = .finished
            }
        }
    }

    private final class PreflightProcessOutput: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private var data = Data()
        private var didExceedLimit = false

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        var exceededLimit: Bool {
            lock.withLock { didExceedLimit }
        }

        func drain(_ handle: FileHandle) {
            while true {
                let chunk: Data
                do {
                    guard let next = try handle.read(upToCount: 16 * 1_024),
                          !next.isEmpty else { return }
                    chunk = next
                } catch {
                    return
                }
                lock.withLock {
                    let remaining = maximumBytes - data.count
                    if remaining > 0 {
                        data.append(chunk.prefix(remaining))
                    }
                    if chunk.count > remaining {
                        didExceedLimit = true
                    }
                }
            }
        }

        func snapshot() -> Data {
            lock.withLock { data }
        }
    }
}
