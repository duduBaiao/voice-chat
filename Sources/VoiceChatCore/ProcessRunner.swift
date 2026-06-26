import Foundation

public struct ProcessCommand: Equatable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var standardInput: Data?
    public var environment: [String: String]

    public init(
        executablePath: String,
        arguments: [String] = [],
        standardInput: Data? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.standardInput = standardInput
        self.environment = environment
    }

    public var displayString: String {
        ([executablePath] + arguments).joined(separator: " ")
    }
}

public struct ProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

public final class AsyncProcessRunner: ProcessRunning {
    private let lock = NSLock()
    private var currentProcess: Process?

    public init() {}

    public func run(_ command: ProcessCommand) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.environment = command.environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        var stdin: Pipe?
        if command.standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdin = pipe
        }

        lock.withLock {
            currentProcess = process
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { [weak self] terminatedProcess in
                    let output = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errors = stderr.fileHandleForReading.readDataToEndOfFile()
                    self?.lock.withLock {
                        if self?.currentProcess === terminatedProcess {
                            self?.currentProcess = nil
                        }
                    }
                    continuation.resume(returning: ProcessResult(
                        exitCode: terminatedProcess.terminationStatus,
                        stdout: output,
                        stderr: errors
                    ))
                }

                do {
                    try process.run()
                    if let input = command.standardInput, let stdin {
                        stdin.fileHandleForWriting.write(input)
                        try? stdin.fileHandleForWriting.close()
                    }
                } catch {
                    lock.withLock {
                        if currentProcess === process {
                            currentProcess = nil
                        }
                    }
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    public func stop() {
        lock.withLock {
            currentProcess?.terminate()
            currentProcess = nil
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
