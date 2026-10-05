import Foundation

public enum JSONRPCProcessTransportError: LocalizedError, Sendable {
    case alreadyRunning
    case notRunning
    case processExited(Int32, diagnostics: String?)
    case requestTimedOut(String)
    case closed
    case malformedResponse
    case frameTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "The provider helper is already running."
        case .notRunning:
            "The provider helper is not running."
        case let .processExited(status, diagnostics):
            diagnostics.map { "The provider helper exited with status \(status): \($0)" }
                ?? "The provider helper exited with status \(status)."
        case let .requestTimedOut(method):
            "The provider helper did not answer \(method) before the request timed out."
        case .closed:
            "The provider helper closed the connection."
        case .malformedResponse:
            "The provider helper returned a malformed response."
        case let .frameTooLarge(maximumBytes):
            "The provider helper returned a response larger than the \(maximumBytes)-byte safety limit."
        }
    }
}

/// Reusable newline-delimited JSON-RPC process transport for provider helpers.
/// Provider secrets may be supplied in `environment`; diagnostics are bounded
/// and never include that environment.
public actor JSONRPCProcessTransport {
    private let executableURL: URL
    private let arguments: [String]
    private var environment: [String: String]?
    private let requestTimeout: TimeInterval
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = JSONRPCLineBuffer()
    private var nextRequestID = 1
    private var pending: [JSONRPCID: CheckedContinuation<JSONValue, any Error>] = [:]
    private var diagnostics = ""
    private let notificationStream: AsyncStream<IncomingJSONRPCMessage>
    private let notificationContinuation: AsyncStream<IncomingJSONRPCMessage>.Continuation

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        requestTimeout: TimeInterval = 30
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.requestTimeout = max(0.1, requestTimeout)
        let pair = AsyncStream<IncomingJSONRPCMessage>.makeStream(
            bufferingPolicy: .bufferingNewest(500)
        )
        notificationStream = pair.stream
        notificationContinuation = pair.continuation
    }

    public func notifications() -> AsyncStream<IncomingJSONRPCMessage> {
        notificationStream
    }

    public func setEnvironment(_ environment: [String: String]?) throws {
        guard process == nil else { throw JSONRPCProcessTransportError.alreadyRunning }
        self.environment = environment
    }

    public func start() throws {
        guard process == nil else { throw JSONRPCProcessTransportError.alreadyRunning }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        if let environment {
            process.environment = environment
        }
        try process.run()

        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        diagnostics = ""
        let outputHandle = outputPipe.fileHandleForReading
        self.outputHandle = outputHandle
        outputBuffer.reset(keepingCapacity: true)
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                Task { await self?.connectionClosed() }
            } else {
                Task { await self?.receive(data) }
            }
        }
        let errorHandle = errorPipe.fileHandleForReading
        self.errorHandle = errorHandle
        errorHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                Task { await self?.appendDiagnostic(data) }
            }
        }
    }

    public func request<Parameters: Encodable & Sendable>(
        method: String,
        params: Parameters,
        timeout: TimeInterval? = nil
    ) async throws -> JSONValue {
        guard inputHandle != nil else { throw JSONRPCProcessTransportError.notRunning }
        let id = JSONRPCID.integer(nextRequestID)
        nextRequestID += 1
        let data = try JSONRPCCodec.encodeLine(JSONRPCRequest(id: id, method: method, params: params))
        let effectiveTimeout = max(0.1, timeout ?? requestTimeout)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try inputHandle?.write(contentsOf: data)
                Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .seconds(effectiveTimeout))
                    await self.timeout(id: id, method: method)
                }
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    public func stop() {
        try? inputHandle?.close()
        inputHandle = nil
        outputHandle?.readabilityHandler = nil
        try? outputHandle?.close()
        outputHandle = nil
        errorHandle?.readabilityHandler = nil
        try? errorHandle?.close()
        errorHandle = nil
        outputBuffer.reset()
        if let process, process.isRunning {
            process.terminate()
        }
        self.process = nil
        failPending(with: JSONRPCProcessTransportError.closed)
    }

    private func receive(_ data: Data) {
        do {
            for var line in try outputBuffer.append(data) {
                if line.last == 0x0D { line.removeLast() }
                receiveLine(line)
            }
        } catch let JSONRPCLineFramingError.frameTooLarge(maximumBytes) {
            abortConnection(with: JSONRPCProcessTransportError.frameTooLarge(maximumBytes))
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
                    continuation.resume(throwing: JSONRPCProcessTransportError.malformedResponse)
                }
            } else {
                notificationContinuation.yield(message)
            }
        } catch {
            notificationContinuation.yield(IncomingJSONRPCMessage(
                jsonrpc: "2.0",
                id: nil,
                method: "goby/transportError",
                params: .string(error.localizedDescription),
                result: nil,
                error: nil
            ))
        }
    }

    private func connectionClosed() {
        if var line = try? outputBuffer.finish() {
            if line.last == 0x0D { line.removeLast() }
            receiveLine(line)
        }
        let status = process?.terminationStatus ?? 0
        let diagnostic = diagnostics.isEmpty ? nil : diagnostics
        process = nil
        inputHandle = nil
        outputHandle?.readabilityHandler = nil
        outputHandle = nil
        errorHandle?.readabilityHandler = nil
        errorHandle = nil
        let error: JSONRPCProcessTransportError = status == 0
            ? .closed
            : .processExited(status, diagnostics: diagnostic)
        failPending(with: error)
        notificationContinuation.yield(IncomingJSONRPCMessage(
            jsonrpc: "2.0",
            id: nil,
            method: "goby/connectionClosed",
            params: .object([
                "status": .integer(Int(status)),
                "diagnostics": diagnostic.map(JSONValue.string) ?? .null,
            ]),
            result: nil,
            error: nil
        ))
    }

    private func connectionFailed(_ error: any Error) {
        process = nil
        inputHandle = nil
        outputHandle?.readabilityHandler = nil
        outputHandle = nil
        errorHandle?.readabilityHandler = nil
        errorHandle = nil
        failPending(with: error)
    }

    private func abortConnection(with error: any Error) {
        try? inputHandle?.close()
        inputHandle = nil
        outputHandle?.readabilityHandler = nil
        try? outputHandle?.close()
        outputHandle = nil
        errorHandle?.readabilityHandler = nil
        try? errorHandle?.close()
        errorHandle = nil
        outputBuffer.reset()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        failPending(with: error)
        notificationContinuation.yield(IncomingJSONRPCMessage(
            jsonrpc: "2.0",
            id: nil,
            method: "goby/transportError",
            params: .string(error.localizedDescription),
            result: nil,
            error: nil
        ))
    }

    private func appendDiagnostic(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        guard diagnostics.count < 8_000 else { return }
        let remaining = 8_000 - diagnostics.count
        diagnostics.append(contentsOf: Self.redactedDiagnostic(text).prefix(remaining))
    }

    nonisolated static func redactedDiagnostic(_ value: String) -> String {
        var result = value
        let replacements = [
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [redacted]"),
            (#"\b(?:sk-(?:ant-)?[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,})\b"#, "[redacted-token]"),
            (#"(?i)\b(api[_-]?key|access[_-]?token|token|password|secret)\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#, "$1=[redacted]"),
        ]
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return result
    }

    private func failPending(with error: any Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func timeout(id: JSONRPCID, method: String) {
        pending.removeValue(forKey: id)?.resume(
            throwing: JSONRPCProcessTransportError.requestTimedOut(method)
        )
    }
}
