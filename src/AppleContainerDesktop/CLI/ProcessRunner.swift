import Foundation

struct ProcessCommand: Equatable, Sendable {
    var executableURL: URL
    var arguments: [String]
    var standardInput: Data?
    var timeout: TimeInterval?

    init(
        executableURL: URL,
        arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.standardInput = standardInput
        self.timeout = timeout
    }

    var preview: CLICommandPreview {
        CLICommandPreview(executable: executableURL.path, arguments: arguments)
    }
}

enum ProcessOutputSource: Sendable {
    case stdout
    case stderr
}

struct ProcessOutputEvent: Sendable {
    var source: ProcessOutputSource
    var text: String
}

typealias ProcessOutputHandler = @Sendable (ProcessOutputEvent) -> Void

enum ProcessRunnerError: Error, Equatable, Sendable {
    case timedOut(CLICommandPreview)
    case launchFailed(String)
}

protocol ProcessRunning: Sendable {
    func run(_ command: ProcessCommand) async throws -> CLIProcessResult
    func run(_ command: ProcessCommand, outputHandler: ProcessOutputHandler?) async throws -> CLIProcessResult
}

extension ProcessRunning {
    func run(_ command: ProcessCommand, outputHandler: ProcessOutputHandler?) async throws -> CLIProcessResult {
        try await run(command)
    }
}

final class ProcessRunner: ProcessRunning, @unchecked Sendable {
    func run(_ command: ProcessCommand) async throws -> CLIProcessResult {
        try await run(command, outputHandler: nil)
    }

    func run(_ command: ProcessCommand, outputHandler: ProcessOutputHandler?) async throws -> CLIProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.runSynchronously(command, outputHandler: outputHandler))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runSynchronously(_ command: ProcessCommand, outputHandler: ProcessOutputHandler?) throws -> CLIProcessResult {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = LockedDataBuffer()
        let stderrBuffer = LockedDataBuffer()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
                outputHandler?(ProcessOutputEvent(source: .stdout, text: data.utf8String))
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
                outputHandler?(ProcessOutputEvent(source: .stderr, text: data.utf8String))
            }
        }

        let stdinPipe: Pipe?
        if command.standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        if let input = command.standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(input)
            try? stdinPipe.fileHandleForWriting.close()
        }

        var didTimeOut = false
        if let timeout = command.timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() >= deadline {
                    didTimeOut = true
                    process.terminate()
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        stdoutBuffer.append(remainingStdout)
        stderrBuffer.append(remainingStderr)
        if !remainingStdout.isEmpty {
            outputHandler?(ProcessOutputEvent(source: .stdout, text: remainingStdout.utf8String))
        }
        if !remainingStderr.isEmpty {
            outputHandler?(ProcessOutputEvent(source: .stderr, text: remainingStderr.utf8String))
        }

        if didTimeOut {
            throw ProcessRunnerError.timedOut(command.preview)
        }

        return CLIProcessResult(
            preview: command.preview,
            exitCode: process.terminationStatus,
            stdout: stdoutBuffer.stringValue,
            stderr: stderrBuffer.stringValue
        )
    }
}

final class StreamingOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumCharacters: Int
    private var output = ""

    init(maximumCharacters: Int = 60_000) {
        self.maximumCharacters = maximumCharacters
    }

    func append(_ event: ProcessOutputEvent) -> String {
        lock.lock()
        if event.source == .stderr, !event.text.isEmpty {
            output += output.hasSuffix("\n") || output.isEmpty ? "[stderr] " : "\n[stderr] "
        }
        output += event.text
        if output.count > maximumCharacters {
            output = "…\n" + String(output.suffix(maximumCharacters))
        }
        let snapshot = output
        lock.unlock()
        return snapshot
    }
}

private extension Data {
    var utf8String: String {
        String(data: self, encoding: .utf8) ?? ""
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else {
            return
        }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let copy = data
        lock.unlock()
        return String(data: copy, encoding: .utf8) ?? ""
    }
}
