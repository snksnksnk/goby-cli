import Darwin
import Foundation

/// Runs one fixed, read-only system tool with a timeout and an output cap.
/// It never uses a shell, and it waits for the tool itself rather than for
/// EOF on a pipe that a daemon it started might keep open.
enum BoundedProcess {
    struct Result: Sendable {
        let status: Int32
        let output: String
    }

    enum Failure: Error, Equatable {
        case couldNotStart
        case timedOut
        case outputTooLarge
    }

    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 5,
        maximumOutputBytes: Int = 1_048_576
    ) throws -> Result {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.couldNotStart }

        let state = BoundedProcessState(maximumBytes: maximumOutputBytes)
        let handle = pipe.fileHandleForReading
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { drained.signal() }
            while let chunk = try? handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                guard state.append(chunk) else {
                    if process.isRunning { process.terminate() }
                    return
                }
            }
        }
        let timer = DispatchWorkItem {
            guard process.isRunning else { return }
            state.markTimedOut()
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)

        process.waitUntilExit()
        timer.cancel()
        if drained.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
            try? handle.close()
            _ = drained.wait(timeout: .now() + .milliseconds(250))
        } else {
            try? handle.close()
        }
        if state.timedOut { throw Failure.timedOut }
        if state.exceededLimit { throw Failure.outputTooLarge }
        return Result(status: process.terminationStatus, output: String(decoding: state.snapshot(), as: UTF8.self))
    }
}

private final class BoundedProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()
    private var exceeded = false
    private var didTimeOut = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ chunk: Data) -> Bool {
        lock.withLock {
            guard data.count + chunk.count <= maximumBytes else {
                exceeded = true
                return false
            }
            data.append(chunk)
            return true
        }
    }

    func markTimedOut() { lock.withLock { didTimeOut = true } }
    var timedOut: Bool { lock.withLock { didTimeOut } }
    var exceededLimit: Bool { lock.withLock { exceeded } }
    func snapshot() -> Data { lock.withLock { data } }
}
