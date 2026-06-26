import Foundation
import VoiceChatCore

@main
struct VoiceChatCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"

        do {
            switch command {
            case "text":
                let prompt = arguments.dropFirst().joined(separator: " ").voiceChatTrimmed
                guard !prompt.isEmpty else {
                    print("Usage: voice-chat text \"hello\"")
                    return
                }
                try await runTypedTurn(prompt)

            case "speak":
                let text = arguments.dropFirst().joined(separator: " ").voiceChatTrimmed
                guard !text.isEmpty else {
                    print("Usage: voice-chat speak \"hello\"")
                    return
                }
                try await makeSynthesizer().speak(text)

            case "listen":
                try refuseKnownHostWithoutSpeechUsageDescriptionIfNeeded()
                try ensureAudioCaptureEntitlementIfNeeded(for: command, arguments: CommandLine.arguments)
                try await runVoiceTurn()

            case "loop":
                try refuseKnownHostWithoutSpeechUsageDescriptionIfNeeded()
                try ensureAudioCaptureEntitlementIfNeeded(for: command, arguments: CommandLine.arguments)
                try await runVoiceLoop()

            default:
                printHelp()
            }
        } catch {
            fputs("voice-chat error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func runTypedTurn(_ prompt: String) async throws {
        let store = InMemoryConversationStore()
        try store.commitUserTranscript(prompt)

        let controller = VoiceChatSessionController(
            recognizer: NoopSpeechRecognizer(),
            llmClient: makeClient(),
            synthesizer: makeSynthesizer(),
            store: store,
            eventSink: printEvent
        )
        _ = try await controller.answerLatestUserTurn()
        print("")
    }

    private static func runVoiceTurn() async throws {
        let controller = makeVoiceController(store: InMemoryConversationStore())
        let result = try await controller.runSingleTurn()
        print("\nturn result: \(result)")
    }

    private static func runVoiceLoop() async throws {
        print("Listening loop started. Say \"stop\" to end, or press Ctrl+C.")
        let store = InMemoryConversationStore()
        while true {
            let controller = makeVoiceController(store: store)
            let result = try await controller.runSingleTurn()
            switch result {
            case .completed:
                continue
            case .noSpeechTimeout:
                print("No speech detected for 5 seconds. Listening stopped.")
                return
            case .stopped:
                print("Stopped.")
                return
            case .skippedEmptyTranscript:
                continue
            }
        }
    }

    private static func makeVoiceController(store: ConversationStore) -> VoiceChatSessionController {
        VoiceChatSessionController(
            recognizer: AppleSpeechRecognizer(),
            llmClient: makeClient(),
            synthesizer: makeSynthesizer(),
            corrector: makeCorrector(),
            store: store,
            eventSink: printEvent
        )
    }

    private static func makeClient() -> LMStudioClient {
        let environment = ProcessInfo.processInfo.environment
        let baseURL = environment["LM_STUDIO_BASE_URL"].flatMap(URL.init(string:))
            ?? VoiceChatConfiguration().lmStudioBaseURL
        let model = environment["LM_STUDIO_MODEL"] ?? VoiceChatConfiguration().lmStudioModel
        return LMStudioClient(baseURL: baseURL, model: model)
    }

    private static func makeSynthesizer() -> SpeechSynthesizer {
        let requested = ProcessInfo.processInfo.environment["VOICE_CHAT_TTS"]?.lowercased()
        if requested == "piper" {
            return PiperSynthesizer()
        }
        return AppleSaySynthesizer()
    }

    private static func makeCorrector() -> FinalTranscriptCorrector {
        let whisper = WhisperCLITranscriptCorrector()
        return whisper.isAvailable ? whisper : NoopTranscriptCorrector()
    }

    private static func printEvent(_ event: VoiceChatEvent) {
        switch event {
        case .statusChanged(let status):
            print("\n[\(status.rawValue)]")
        case .interimTranscript(let transcript):
            print("\rYou: \(transcript)", terminator: "")
            fflush(stdout)
        case .finalTranscript(let transcript):
            print("\nYou: \(transcript)")
        case .assistantStarted:
            print("Gemma: ", terminator: "")
            fflush(stdout)
        case .assistantDelta(let delta):
            print(delta, terminator: "")
            fflush(stdout)
        case .assistantFinal:
            print("")
        case .info(let message):
            print(message)
        case .error(let message):
            fputs("\(message)\n", stderr)
        }
    }

    private static func printHelp() {
        print("""
        voice-chat

        Commands:
          voice-chat text "hello"     Send typed text to LM Studio and speak the reply.
          voice-chat speak "hello"    Speak text with the selected free TTS backend.
          voice-chat listen           Run one microphone turn.
          voice-chat loop             Keep listening turn-by-turn until no speech or "stop".

        Environment:
          LM_STUDIO_BASE_URL          Defaults to http://100.127.238.44:1234
          LM_STUDIO_MODEL             Defaults to google/gemma-4-26b-a4b-qat
          VOICE_CHAT_TTS              apple or piper, defaults to apple
          PIPER_BIN/PIPER_MODEL       Required for Piper
          WHISPER_BIN/WHISPER_MODEL   Optional Whisper final correction
        """)
    }

    private static func ensureAudioCaptureEntitlementIfNeeded(for command: String, arguments: [String]) throws {
        guard command == "listen" || command == "loop" else { return }
        guard ProcessInfo.processInfo.environment["VOICE_CHAT_DID_SELF_SIGN"] != "1" else { return }
        guard let executableURL = Bundle.main.executableURL else { return }

        let entitlements = currentEntitlements(for: executableURL.path)
        guard !entitlements.contains("com.apple.security.device.audio-input") else { return }

        let entitlementsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Support")
            .appendingPathComponent("VoiceChat.entitlements")
        guard FileManager.default.fileExists(atPath: entitlementsURL.path) else {
            fputs("Missing \(entitlementsURL.path); cannot request microphone safely.\n", stderr)
            return
        }

        print("Adding local audio-input entitlement to \(executableURL.lastPathComponent)...")
        let signStatus = runSynchronousProcess(
            executablePath: "/usr/bin/codesign",
            arguments: [
                "--force",
                "--sign", "-",
                "--entitlements", entitlementsURL.path,
                executableURL.path
            ]
        )
        guard signStatus == 0 else {
            throw VoiceChatCLIError.selfSigningFailed(signStatus)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["VOICE_CHAT_DID_SELF_SIGN"] = "1"
        let relaunchStatus = runSynchronousProcess(
            executablePath: executableURL.path,
            arguments: Array(arguments.dropFirst()),
            environment: environment
        )
        Foundation.exit(relaunchStatus)
    }

    private static func refuseKnownHostWithoutSpeechUsageDescriptionIfNeeded() throws {
        let environment = ProcessInfo.processInfo.environment
        let isVSCodeTerminal = environment["TERM_PROGRAM"] == "vscode"
            || environment["VSCODE_INJECTION"] != nil
            || environment["VSCODE_PID"] != nil

        guard isVSCodeTerminal else { return }

        throw VoiceChatCLIError.unsupportedResponsibleProcess("""
        macOS is attributing Speech Recognition permission to Visual Studio Code, not to voice-chat.
        VS Code does not declare NSSpeechRecognitionUsageDescription, so TCC aborts child processes before permission can be requested.

        Run the signed app bundle instead:
          ./scripts/build_app.sh
          open .build/VoiceChat.app

        Or run the CLI from outside the VS Code integrated terminal.
        """)
    }

    private static func currentEntitlements(for executablePath: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", ":-", executablePath]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private static func runSynchronousProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}

private enum VoiceChatCLIError: Error, LocalizedError {
    case selfSigningFailed(Int32)
    case unsupportedResponsibleProcess(String)

    var errorDescription: String? {
        switch self {
        case .selfSigningFailed(let status):
            return "codesign failed while adding the audio-input entitlement, exit code \(status)."
        case .unsupportedResponsibleProcess(let message):
            return message
        }
    }
}

private struct NoopSpeechRecognizer: SpeechRecognizer {
    func start() -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.stopped)
            continuation.finish()
        }
    }

    func stop() {}
}
