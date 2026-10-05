import Darwin
import Foundation
import GobyApplication
import GobyDomain
import OSLog

public enum CodexTransportError: LocalizedError, Sendable, Equatable {
    case alreadyRunning
    case notRunning
    case processExited(Int32)
    case requestTimedOut(String)
    case closed
    case malformedResponse
    case frameTooLarge(Int)
    case duplicatePeerRequestID
    case tooManyPeerRequests(Int)
    case assignmentAlreadyActive(AssignmentID)
    case indeterminateTurnStart(threadID: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Codex App Server is already running."
        case .notRunning: "Codex App Server is not running."
        case let .processExited(status): "Codex App Server exited with status \(status)."
        case let .requestTimedOut(method): "Codex App Server did not answer \(method) before the request timed out."
        case .closed: "Codex App Server closed the connection."
        case .malformedResponse: "Codex App Server returned a malformed response."
        case let .frameTooLarge(maximumBytes):
            "Codex App Server returned a response larger than the \(maximumBytes)-byte safety limit."
        case .duplicatePeerRequestID:
            ProviderApprovalBindingError.duplicatePendingApproval.localizedDescription
        case let .tooManyPeerRequests(maximumCount):
            "Codex App Server exceeded the \(maximumCount)-request peer safety limit."
        case let .assignmentAlreadyActive(assignmentID):
            "Assignment \(assignmentID.rawValue) already has an active Codex turn. Goby did not start a duplicate."
        case let .indeterminateTurnStart(threadID):
            "Codex did not confirm whether thread \(threadID) started its turn. Goby quarantined the thread and will not retry the assignment automatically."
        }
    }
}

public actor CodexAppServerTransport {
    private let logger = Logger(subsystem: "com.demetrisgeorgiou.GobyAgenticDashboard", category: "CodexConnection")
    private let executableURL: URL
    private let clientVersion: String
    private let requestTimeout: TimeInterval
    private let runtimeValidator: any CodexRuntimeValidating
    private let environmentOverrides: [String: String]
    private var process: Process?
    private var sessionID: UUID?
    private var startupTask: Task<JSONValue, any Error>?
    private var initializedResponse: JSONValue?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var outputBuffer = JSONRPCLineBuffer()
    private var nextRequestID = 1
    private var pending: [JSONRPCID: CheckedContinuation<JSONValue, any Error>] = [:]
    private var inboundPeerRequestIDs = Set<JSONRPCID>()
    private let maximumInboundPeerRequests = 500
    private var notificationStream: AsyncStream<IncomingJSONRPCMessage>
    private var notificationContinuation: AsyncStream<IncomingJSONRPCMessage>.Continuation

    public init(
        executableURL: URL,
        clientVersion: String,
        requestTimeout: TimeInterval = 30,
        runtimeValidator: any CodexRuntimeValidating = CodexRuntimeIntegrityValidator(),
        environmentOverrides: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.clientVersion = clientVersion
        self.requestTimeout = max(0.1, requestTimeout)
        self.runtimeValidator = runtimeValidator
        self.environmentOverrides = environmentOverrides
        let pair = AsyncStream<IncomingJSONRPCMessage>.makeStream(bufferingPolicy: .bufferingNewest(500))
        self.notificationStream = pair.stream
        self.notificationContinuation = pair.continuation
    }

    public func notifications() -> AsyncStream<IncomingJSONRPCMessage> {
        notificationStream
    }

    public func start() async throws -> JSONValue {
        // Actor isolation alone does not serialize startup across validation and
        // initialization awaits. Every caller must join the same handshake.
        if let startupTask { return try await startupTask.value }
        if let initializedResponse, process?.isRunning == true { return initializedResponse }
        stop()
        let sessionID = UUID()
        self.sessionID = sessionID
        let pair = AsyncStream<IncomingJSONRPCMessage>.makeStream(bufferingPolicy: .bufferingNewest(500))
        notificationStream = pair.stream
        notificationContinuation = pair.continuation
        let task = Task { try await self.launch(sessionID: sessionID) }
        startupTask = task
        return try await task.value
    }

    private func launch(sessionID: UUID) async throws -> JSONValue {
        defer {
            if self.sessionID == sessionID { startupTask = nil }
        }
        do {
            return try await launchValidatedProcess(sessionID: sessionID)
        } catch {
            if self.sessionID == sessionID {
                logger.error("Codex startup failed: \(error.localizedDescription, privacy: .private)")
                stop()
            }
            throw error
        }
    }

    private func requireCurrentSession(_ sessionID: UUID) throws {
        try Task.checkCancellation()
        guard self.sessionID == sessionID else { throw CodexTransportError.closed }
    }

    private func launchValidatedProcess(sessionID: UUID) async throws -> JSONValue {
        try requireCurrentSession(sessionID)
        logger.notice("Validating Codex runtime before startup.")

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.environment = Self.sanitizedChildEnvironment(
            from: ProcessInfo.processInfo.environment
        ).merging(environmentOverrides) { _, override in override }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        guard fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw CodexTransportError.closed
        }
        let runtimeValidator = self.runtimeValidator
        let executableURL = self.executableURL
        try await Task.detached(priority: .userInitiated) {
            try runtimeValidator.validate(executableURL: executableURL)
        }.value
        try requireCurrentSession(sessionID)
        try process.run()
        // Retain the child immediately so stop() can terminate it even while
        // live-process attestation is suspended. No RPC is sent before attestation.
        self.process = process
        let processIdentifier = process.processIdentifier
        try await Task.detached(priority: .userInitiated) {
            try runtimeValidator.validateRunningProcess(
                processIdentifier: processIdentifier,
                executableURL: executableURL
            )
        }.value
        try requireCurrentSession(sessionID)
        logger.notice("Codex process attested; initializing the connection.")
        self.inputHandle = inputPipe.fileHandleForWriting
        let outputHandle = outputPipe.fileHandleForReading
        self.outputHandle = outputHandle
        outputBuffer.reset(keepingCapacity: true)
        inboundPeerRequestIDs.removeAll(keepingCapacity: true)
        armOutputRead(sessionID: sessionID)

        let result = try await request(
            method: "initialize",
            params: InitializeParameters(
                clientInfo: .init(
                    name: "goby-agentic-dashboard",
                    title: "Goby Agentic Dashboard",
                    version: clientVersion
                )
            )
        )
        try requireCurrentSession(sessionID)
        try sendNotification(method: "initialized", params: EmptyParameters())
        initializedResponse = result
        logger.notice("Codex initialize handshake completed.")
        return result
    }

    private func armOutputRead(sessionID: UUID) {
        guard self.sessionID == sessionID, let outputHandle else { return }
        // Read only one chunk at a time. Rearm after the actor has consumed it,
        // so neither another chunk nor EOF can overtake it. This also lets the
        // OS pipe apply backpressure instead of accumulating an async queue.
        outputHandle.readabilityHandler = { [weak self] handle in
            handle.readabilityHandler = nil
            let data = handle.availableData
            Task { await self?.consumeOutputChunk(data, sessionID: sessionID) }
        }
    }

    private func consumeOutputChunk(_ data: Data, sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        if data.isEmpty {
            connectionClosed(sessionID: sessionID)
        } else {
            receive(data, sessionID: sessionID)
            armOutputRead(sessionID: sessionID)
        }
    }

    nonisolated static func sanitizedChildEnvironment(
        from source: [String: String]
    ) -> [String: String] {
        let allowed = Set([
            "CODEX_HOME", "HOME", "LANG", "LC_ALL", "LOGNAME", "PATH",
            "SHELL", "TERM", "TMPDIR", "USER", "XDG_CONFIG_HOME",
        ])
        var result = source.filter { allowed.contains($0.key) }
        result["TERM"] = result["TERM"] ?? "dumb"
        return result
    }

    public func request<Parameters: Encodable & Sendable>(
        method: String,
        params: Parameters,
        timeout: TimeInterval? = nil
    ) async throws -> JSONValue {
        guard inputHandle != nil else { throw CodexTransportError.notRunning }
        let id = JSONRPCID.integer(nextRequestID)
        nextRequestID += 1
        let data = try JSONRPCCodec.encodeLine(JSONRPCRequest(id: id, method: method, params: params))
        let requestTimeout = max(0.1, timeout ?? self.requestTimeout)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try inputHandle?.write(contentsOf: data)
                Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .seconds(requestTimeout))
                    await self.timeout(id: id, method: method)
                }
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    public func sendNotification<Parameters: Encodable & Sendable>(
        method: String,
        params: Parameters
    ) throws {
        guard let inputHandle else { throw CodexTransportError.notRunning }
        let data = try JSONRPCCodec.encodeLine(JSONRPCNotification(method: method, params: params))
        try inputHandle.write(contentsOf: data)
    }

    public func sendResponse<Result: Encodable & Sendable>(id: JSONRPCID, result: Result) throws {
        guard let inputHandle else { throw CodexTransportError.notRunning }
        guard inboundPeerRequestIDs.contains(id) else {
            throw CodexTransportError.malformedResponse
        }
        let data = try JSONRPCCodec.encodeLine(JSONRPCResponse(id: id, result: result))
        try inputHandle.write(contentsOf: data)
        inboundPeerRequestIDs.remove(id)
    }

    public func stop() {
        sessionID = nil
        startupTask?.cancel()
        startupTask = nil
        initializedResponse = nil
        try? inputHandle?.close()
        inputHandle = nil
        outputHandle?.readabilityHandler = nil
        try? outputHandle?.close()
        outputHandle = nil
        outputBuffer.reset()
        inboundPeerRequestIDs.removeAll()
        if let process, process.isRunning {
            process.terminate()
        }
        self.process = nil
        failPending(with: CodexTransportError.closed)
        notificationContinuation.finish()
    }

    private func receive(_ data: Data, sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        do {
            for var line in try outputBuffer.append(data) {
                guard self.sessionID == sessionID else { return }
                if line.last == 0x0D { line.removeLast() }
                receiveLine(line)
            }
        } catch let JSONRPCLineFramingError.frameTooLarge(maximumBytes) {
            abortConnection(with: CodexTransportError.frameTooLarge(maximumBytes))
        } catch {
            abortConnection(with: error)
        }
    }

    private func receiveLine(_ line: Data) {
        do {
            let message = try JSONRPCCodec.decodeLine(line)
            if let id = message.id, message.method == nil {
                guard let continuation = pending.removeValue(forKey: id) else { return }
                if let error = message.error {
                    continuation.resume(throwing: error)
                } else if let result = message.result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: CodexTransportError.malformedResponse)
                }
            } else if let id = message.id, message.method != nil {
                guard inboundPeerRequestIDs.count < maximumInboundPeerRequests else {
                    abortConnection(with: CodexTransportError.tooManyPeerRequests(maximumInboundPeerRequests))
                    return
                }
                guard inboundPeerRequestIDs.insert(id).inserted else {
                    abortConnection(with: CodexTransportError.duplicatePeerRequestID)
                    return
                }
                notificationContinuation.yield(message)
            } else {
                notificationContinuation.yield(message)
            }
        } catch {
            // A failed gateway must never leave a live, unusable transport behind.
            // Record only framing/decoder metadata, never provider payloads.
            let decoderCode = (error as NSError).code
            let validJSON = (try? JSONSerialization.jsonObject(with: line, options: .fragmentsAllowed)) != nil
            logger.error("Codex JSON-RPC decode failed (code \(decoderCode), frame bytes \(line.count), valid JSON \(validJSON)).")
            abortConnection(with: error)
        }
    }

    private func connectionClosed(sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        if var line = try? outputBuffer.finish() {
            if line.last == 0x0D { line.removeLast() }
            receiveLine(line)
        }
        guard self.sessionID == sessionID else { return }
        let status = process.flatMap { $0.isRunning ? nil : $0.terminationStatus } ?? 0
        failPending(with: status == 0 ? CodexTransportError.closed : CodexTransportError.processExited(status))
        notificationContinuation.yield(IncomingJSONRPCMessage(
            jsonrpc: "2.0",
            id: nil,
            method: "goby/connectionClosed",
            params: .integer(Int(status)),
            result: nil,
            error: nil
        ))
        logger.notice("Codex connection closed (exit status \(status)).")
        stop()
    }

    private func abortConnection(with error: any Error) {
        failPending(with: error)
        notificationContinuation.yield(IncomingJSONRPCMessage(
            jsonrpc: "2.0",
            id: nil,
            method: "goby/transportError",
            params: .string(error.localizedDescription),
            result: nil,
            error: nil
        ))
        logger.error("Codex connection aborted: \(error.localizedDescription, privacy: .private)")
        stop()
    }

    private func failPending(with error: any Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func timeout(id: JSONRPCID, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: CodexTransportError.requestTimedOut(method))
    }
}
