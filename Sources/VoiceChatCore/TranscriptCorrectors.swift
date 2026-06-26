import Foundation

public struct NoopTranscriptCorrector: FinalTranscriptCorrector {
    public let name = "None"
    public let isAvailable = true

    public init() {}

    public func correct(transcript: String, audioURL: URL?) async throws -> String {
        transcript
    }
}

public struct WhisperConfiguration: Equatable, Sendable {
    public var binaryPath: String
    public var modelPath: String
    public var language: String?

    public init(binaryPath: String, modelPath: String, language: String? = nil) {
        self.binaryPath = binaryPath
        self.modelPath = modelPath
        self.language = language
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> WhisperConfiguration? {
        guard let binaryPath = environment["WHISPER_BIN"],
              let modelPath = environment["WHISPER_MODEL"],
              !binaryPath.isEmpty,
              !modelPath.isEmpty else {
            return nil
        }
        return WhisperConfiguration(
            binaryPath: binaryPath,
            modelPath: modelPath,
            language: environment["WHISPER_LANGUAGE"]
        )
    }
}

public final class WhisperCLITranscriptCorrector: FinalTranscriptCorrector {
    public let name = "whisper.cpp"
    public let isAvailable: Bool
    private let configuration: WhisperConfiguration?
    private let runner: ProcessRunning
    private let fileManager: FileManager

    public init(
        configuration: WhisperConfiguration? = WhisperConfiguration.fromEnvironment(),
        runner: ProcessRunning = AsyncProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.runner = runner
        self.fileManager = fileManager

        if let configuration {
            isAvailable = fileManager.isExecutableFile(atPath: configuration.binaryPath)
                && fileManager.fileExists(atPath: configuration.modelPath)
        } else {
            isAvailable = false
        }
    }

    public func correct(transcript: String, audioURL: URL?) async throws -> String {
        guard let configuration, isAvailable else {
            return transcript
        }
        guard let audioURL else {
            return transcript
        }

        var arguments = [
            "-m", configuration.modelPath,
            "-f", audioURL.path,
            "-nt"
        ]
        if let language = configuration.language, !language.isEmpty {
            arguments += ["-l", language]
        }

        let result = try await runner.run(ProcessCommand(
            executablePath: configuration.binaryPath,
            arguments: arguments
        ))
        guard result.exitCode == 0 else {
            throw VoiceChatError.processFailed(
                command: configuration.binaryPath,
                exitCode: result.exitCode,
                stderr: result.stderrString
            )
        }

        let corrected = Self.cleanWhisperOutput(result.stdoutString)
        return corrected.isEmpty ? transcript : corrected
    }

    public static func cleanWhisperOutput(_ output: String) -> String {
        output
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(
                    of: #"^\s*\[[^\]]+\]\s*"#,
                    with: "",
                    options: .regularExpression
                )
            }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .voiceChatTrimmed
    }
}
