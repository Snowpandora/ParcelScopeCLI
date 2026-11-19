import Foundation
import Darwin

/// A thread-safe runner for executing system processes with argument arrays.
public protocol ProcessExecuting: Sendable {
    func run(path: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessRunner.ProcessResult
}

public extension ProcessExecuting {
    func run(path: String, arguments: [String]) async throws -> ProcessRunner.ProcessResult {
        try await run(path: path, arguments: arguments, timeout: 15)
    }
}

public actor ProcessRunner: ProcessExecuting {
    private let targetVolume: String?
    private let launchQueue: DispatchQueue
    private let launchProcess: @Sendable (Process) throws -> Void

    public init(targetVolume: String? = nil) {
        self.targetVolume = targetVolume
        launchQueue = .global(qos: .utility)
        launchProcess = { try $0.run() }
    }

    init(targetVolume: String? = nil, launchQueue: DispatchQueue,
         launchProcess: @escaping @Sendable (Process) throws -> Void = { try $0.run() }) {
        self.targetVolume = targetVolume
        self.launchQueue = launchQueue
        self.launchProcess = launchProcess
    }

    public struct ProcessResult: Sendable {
        public let terminationStatus: Int32
        public let stdout: Data
        public let stderr: Data
        public init(terminationStatus: Int32, stdout: Data, stderr: Data) {
            self.terminationStatus = terminationStatus
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public enum ProcessError: LocalizedError {
        case executionFailed(String)
        case nonZeroExitCode(Int32, String)
        case timedOut(TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .executionFailed(let detail): "The process could not be started: \(detail)"
            case .nonZeroExitCode(let code, let detail): "The process exited with status \(code): \(detail)"
            case .timedOut(let seconds): "The process exceeded the \(seconds)-second time limit."
            }
        }
    }

    /// Runs without occupying a Swift cooperative thread while launching or reading pipes.
    public func run(path: String, arguments: [String], timeout: TimeInterval = 15.0) async throws -> ProcessResult {
        var finalArguments = arguments
        if let volume = targetVolume, volume != "/" {
            finalArguments = ["--volume", volume] + arguments
        }
        let invocation = ProcessInvocation(path: path, arguments: finalArguments, timeout: timeout, launchQueue: launchQueue, launchProcess: launchProcess)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                invocation.start(continuation)
            }
        } onCancel: {
            invocation.cancel()
        }
    }
}

// Mutable state, buffers and descriptor reads are confined to `queue`. Process.run is the
// sole exception: it executes on a GCD worker, after configuration, so a cold launch cannot
// block the state queue's deadline. Its completion always comes back through that queue.
private final class ProcessInvocation: @unchecked Sendable {
    private enum Stream { case stdout, stderr }
    private let queue = DispatchQueue(label: "me.rbbtsn0w.parcelscope.process." + UUID().uuidString)
    private let launchQueue: DispatchQueue
    private let launchProcess: @Sendable (Process) throws -> Void
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let path: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<ProcessRunner.ProcessResult, any Error>?
    private var completion: Result<ProcessRunner.ProcessResult, any Error>?
    private var stdoutSource: (any DispatchSourceRead)?
    private var stderrSource: (any DispatchSourceRead)?
    private var timer: (any DispatchSourceTimer)?
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutEOF = false
    private var stderrEOF = false
    private var launchFinished = false
    private var exitStatus: Int32?

    init(path: String, arguments: [String], timeout: TimeInterval, launchQueue: DispatchQueue,
         launchProcess: @escaping @Sendable (Process) throws -> Void) {
        self.path = path
        self.arguments = arguments
        self.timeout = timeout
        self.launchQueue = launchQueue
        self.launchProcess = launchProcess
    }

    func start(_ continuation: CheckedContinuation<ProcessRunner.ProcessResult, any Error>) {
        queue.async {
            self.continuation = continuation
            if let completion = self.completion {
                self.continuation = nil
                continuation.resume(with: completion)
                return
            }
            self.prepareAndLaunch()
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func prepareAndLaunch() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard timeout.isFinite else {
            finish(.failure(ProcessRunner.ProcessError.executionFailed("The time limit is not finite.")))
            return
        }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            self?.queue.async { [weak self] in self?.didExit(status) }
        }
        do {
            stdoutSource = try makeSource(stdoutPipe.fileHandleForReading, stream: .stdout)
            stderrSource = try makeSource(stderrPipe.fileHandleForReading, stream: .stderr)
        } catch {
            finish(.failure(error))
            return
        }
        if timeout > 0 {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.finish(.failure(ProcessRunner.ProcessError.timedOut(self.timeout)))
            }
            self.timer = timer
            timer.resume()
        }
        launchQueue.async {
            // Admission is serialized with completion; queued work cannot begin after a finished request.
            let mayLaunch = self.queue.sync {
                guard self.completion == nil else {
                    self.launchFinished = true
                    self.closeWriters()
                    return false
                }
                return true
            }
            guard mayLaunch else { return }
            do {
                try self.launchProcess(self.process)
                self.queue.async { self.didLaunch() }
            } catch {
                let detail = error.localizedDescription
                self.queue.async { self.didFailToLaunch(detail) }
            }
        }
    }

    private func makeSource(_ handle: FileHandle, stream: Stream) throws -> any DispatchSourceRead {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw ProcessRunner.ProcessError.executionFailed("Could not configure process output: " + String(cString: strerror(errno)))
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(stream) }
        // Closing after source cancellation prevents descriptor reuse while a queued read exists.
        source.setCancelHandler { try? handle.close() }
        source.resume()
        return source
    }

    private func didLaunch() {
        dispatchPrecondition(condition: .onQueue(queue))
        launchFinished = true
        closeWriters()
        if completion != nil { stopDirectChild() }
    }

    private func didFailToLaunch(_ detail: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        launchFinished = true
        closeWriters()
        finish(.failure(ProcessRunner.ProcessError.executionFailed(detail)))
    }

    private func didExit(_ status: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        exitStatus = status
        guard completion == nil else { return }
        // Drain both tails even if the termination callback precedes dispatch's read event.
        drain(.stdout)
        drain(.stderr)
        completeIfDrained()
    }

    private func drain(_ stream: Stream) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard completion == nil else { return }
        if stream == .stdout ? stdoutEOF : stderrEOF { return }
        let descriptor = (stream == .stdout ? stdoutPipe : stderrPipe).fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 65_536)
        // A continuously writing child must yield the queue to its deadline and cancellation.
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                if stream == .stdout { stdout.append(contentsOf: buffer.prefix(count)) }
                else { stderr.append(contentsOf: buffer.prefix(count)) }
            } else if count == 0 {
                if stream == .stdout { stdoutEOF = true; stdoutSource?.cancel(); stdoutSource = nil }
                else { stderrEOF = true; stderrSource?.cancel(); stderrSource = nil }
                completeIfDrained()
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno != EINTR {
                let name = stream == .stdout ? "standard output" : "standard error"
                finish(.failure(ProcessRunner.ProcessError.executionFailed("Could not read " + name + ": " + String(cString: strerror(errno)))))
                return
            }
        }
    }

    private func completeIfDrained() {
        guard completion == nil, let exitStatus, stdoutEOF, stderrEOF else { return }
        if exitStatus == 0 {
            finish(.success(.init(terminationStatus: exitStatus, stdout: stdout, stderr: stderr)))
        } else {
            finish(.failure(ProcessRunner.ProcessError.nonZeroExitCode(exitStatus,
                String(data: stderr, encoding: .utf8) ?? "Unknown error")))
        }
    }

    private func finish(_ result: Result<ProcessRunner.ProcessResult, any Error>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard completion == nil else { return }
        completion = result
        timer?.cancel()
        timer = nil
        stdoutSource?.cancel()
        stdoutSource = nil
        stderrSource?.cancel()
        stderrSource = nil
        if launchFinished { closeWriters(); stopDirectChild() }
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    private func closeWriters() {
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
    }

    private func stopDirectChild() {
        guard exitStatus == nil, process.isRunning else { return }
        let childPID = process.processIdentifier
        guard childPID > 0 else { return }
        // A POSIX signal tolerates an exit racing this request without an Objective-C exception.
        _ = Darwin.kill(childPID, SIGTERM)
        // Only the launched direct child is eligible; inherited descendants are never signalled.
        queue.asyncAfter(deadline: .now() + .milliseconds(200)) {
            guard self.exitStatus == nil, self.process.isRunning,
                  self.process.processIdentifier == childPID else { return }
            _ = Darwin.kill(childPID, SIGKILL)
        }
    }
}
