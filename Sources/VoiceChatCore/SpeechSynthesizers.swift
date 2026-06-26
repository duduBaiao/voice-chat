@preconcurrency import AVFoundation
import Foundation

public final class AppleSaySynthesizer: SpeechSynthesizer {
    public let name = "Apple say"
    public let isAvailable: Bool
    private let runner: ProcessRunning
    private let sayPath: String

    public init(
        sayPath: String = "/usr/bin/say",
        runner: ProcessRunning = AsyncProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.sayPath = sayPath
        self.runner = runner
        isAvailable = fileManager.isExecutableFile(atPath: sayPath)
    }

    public func speak(_ text: String) async throws {
        guard isAvailable else {
            throw VoiceChatError.componentUnavailable(name)
        }
        let result = try await runner.run(ProcessCommand(
            executablePath: sayPath,
            arguments: [text]
        ))
        guard result.exitCode == 0 else {
            throw VoiceChatError.processFailed(
                command: sayPath,
                exitCode: result.exitCode,
                stderr: result.stderrString
            )
        }
    }

    public func stop() {
        runner.stop()
    }
}

public struct PiperConfiguration: Equatable, Sendable {
    public var binaryPath: String
    public var modelPath: String
    public var configPath: String?

    public init(binaryPath: String, modelPath: String, configPath: String? = nil) {
        self.binaryPath = binaryPath
        self.modelPath = modelPath
        self.configPath = configPath
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> PiperConfiguration? {
        if let binaryPath = environment["PIPER_BIN"],
           let modelPath = environment["PIPER_MODEL"],
           !binaryPath.isEmpty,
           !modelPath.isEmpty {
            return PiperConfiguration(
                binaryPath: binaryPath,
                modelPath: modelPath,
                configPath: environment["PIPER_CONFIG"]
            )
        }

        let localRoot = URL(fileURLWithPath: environment["VOICE_CHAT_PROJECT_DIR"] ?? FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local")
            .appendingPathComponent("piper")
        return PiperConfiguration(
            binaryPath: localRoot.appendingPathComponent("piper").appendingPathComponent("piper").path,
            modelPath: localRoot.appendingPathComponent("voices").appendingPathComponent("en_US-lessac-medium.onnx").path,
            configPath: localRoot.appendingPathComponent("voices").appendingPathComponent("en_US-lessac-medium.onnx.json").path
        )
    }

    public var setupHint: String {
        "Run ./scripts/setup_piper.sh, or set PIPER_BIN and PIPER_MODEL."
    }
}

public final class PiperSynthesizer: SpeechSynthesizer {
    public let name = "Piper"
    public let isAvailable: Bool
    private let configuration: PiperConfiguration?
    private let runner: ProcessRunning
    private let fileManager: FileManager
    private let afplayPath: String

    public init(
        configuration: PiperConfiguration? = PiperConfiguration.fromEnvironment(),
        runner: ProcessRunning = AsyncProcessRunner(),
        fileManager: FileManager = .default,
        afplayPath: String = "/usr/bin/afplay"
    ) {
        self.configuration = configuration
        self.runner = runner
        self.fileManager = fileManager
        self.afplayPath = afplayPath

        if let configuration {
            isAvailable = fileManager.isExecutableFile(atPath: configuration.binaryPath)
                && fileManager.fileExists(atPath: configuration.modelPath)
                && fileManager.isExecutableFile(atPath: afplayPath)
        } else {
            isAvailable = false
        }
    }

    public func speak(_ text: String) async throws {
        guard let configuration, isAvailable else {
            let hint = configuration?.setupHint ?? "Run ./scripts/setup_piper.sh, or set PIPER_BIN and PIPER_MODEL."
            throw VoiceChatError.componentUnavailable("\(name). \(hint)")
        }

        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("voice-chat-piper-\(UUID().uuidString).wav")
        defer { try? fileManager.removeItem(at: outputURL) }

        var arguments = [
            "--model", configuration.modelPath,
            "--output_file", outputURL.path
        ]
        if let configPath = configuration.configPath,
           !configPath.isEmpty,
           fileManager.fileExists(atPath: configPath) {
            arguments += ["--config", configPath]
        }

        let synthesis = try await runner.run(ProcessCommand(
            executablePath: configuration.binaryPath,
            arguments: arguments,
            standardInput: Data(text.utf8),
            environment: piperEnvironment(for: configuration)
        ))
        guard synthesis.exitCode == 0 else {
            throw VoiceChatError.processFailed(
                command: configuration.binaryPath,
                exitCode: synthesis.exitCode,
                stderr: synthesis.stderrString
            )
        }

        let playback = try await runner.run(ProcessCommand(
            executablePath: afplayPath,
            arguments: [outputURL.path]
        ))
        guard playback.exitCode == 0 else {
            throw VoiceChatError.processFailed(
                command: afplayPath,
                exitCode: playback.exitCode,
                stderr: playback.stderrString
            )
        }
    }

    public func stop() {
        runner.stop()
    }

    private func piperEnvironment(for configuration: PiperConfiguration) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let binaryURL = URL(fileURLWithPath: configuration.binaryPath)
        let piperRoot = binaryURL.deletingLastPathComponent().deletingLastPathComponent()
        let runtimeLibraryPath = piperRoot
            .appendingPathComponent("piper-phonemize")
            .appendingPathComponent("lib")
            .path

        if fileManager.fileExists(atPath: runtimeLibraryPath) {
            let existing = environment["DYLD_LIBRARY_PATH"].map { ":\($0)" } ?? ""
            environment["DYLD_LIBRARY_PATH"] = runtimeLibraryPath + existing
        }

        let espeakDataPath = piperRoot
            .appendingPathComponent("piper-phonemize")
            .appendingPathComponent("share")
            .appendingPathComponent("espeak-ng-data")
            .path
        if fileManager.fileExists(atPath: espeakDataPath) {
            environment["ESPEAK_DATA_PATH"] = espeakDataPath
        }

        return environment
    }
}

public enum TTSBackend: String, CaseIterable, Equatable, Sendable {
    case apple
    case piper
}

public enum SpeechSynthesizerFactory {
    public static func make(
        backend: TTSBackend,
        runner: ProcessRunning = AsyncProcessRunner()
    ) -> SpeechSynthesizer {
        switch backend {
        case .apple:
            return AppleSaySynthesizer(runner: runner)
        case .piper:
            return PiperSynthesizer(runner: runner)
        }
    }
}

public final class AppleAVSpeechSynthesizerAdapter: NSObject, @unchecked Sendable, SpeechSynthesizer, AVSpeechSynthesizerDelegate {
    public let name = "Apple AVSpeechSynthesizer"
    public let isAvailable = true
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Error>?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let utterance = AVSpeechUtterance(string: text)
            synthesizer.speak(utterance)
        }
    }

    public func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        continuation?.resume(throwing: VoiceChatError.stopped)
        continuation = nil
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        continuation?.resume()
        continuation = nil
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        continuation?.resume(throwing: VoiceChatError.stopped)
        continuation = nil
    }
}
