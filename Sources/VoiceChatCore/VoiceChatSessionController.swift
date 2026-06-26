import Foundation

public enum VoiceChatTurnResult: Equatable, Sendable {
    case completed(userText: String, assistantText: String)
    case noSpeechTimeout
    case stopped
    case skippedEmptyTranscript
}

public final class VoiceChatSessionController {
    public typealias EventSink = (VoiceChatEvent) -> Void

    private let recognizer: SpeechRecognizer
    private let llmClient: LLMClient
    private let synthesizer: SpeechSynthesizer
    private let corrector: FinalTranscriptCorrector
    private let configuration: VoiceChatConfiguration
    private let eventSink: EventSink
    public let store: ConversationStore

    private let lock = NSLock()
    private var stopped = false

    public init(
        recognizer: SpeechRecognizer,
        llmClient: LLMClient,
        synthesizer: SpeechSynthesizer,
        corrector: FinalTranscriptCorrector = NoopTranscriptCorrector(),
        store: ConversationStore = InMemoryConversationStore(),
        configuration: VoiceChatConfiguration = VoiceChatConfiguration(),
        eventSink: @escaping EventSink = { _ in }
    ) {
        self.recognizer = recognizer
        self.llmClient = llmClient
        self.synthesizer = synthesizer
        self.corrector = corrector
        self.store = store
        self.configuration = configuration
        self.eventSink = eventSink
    }

    public func runSingleTurn() async throws -> VoiceChatTurnResult {
        setStopped(false)
        transition(to: .listening)

        let events = recognizer.start()
        let iterator = SpeechEventIterator(events.makeAsyncIterator())
        var heardSpeech = false

        while !isStopped {
            let event: SpeechRecognitionEvent?
            if heardSpeech {
                event = try await iterator.next()
            } else {
                do {
                    event = try await withTimeout(
                        seconds: configuration.noSpeechTimeoutSeconds,
                        operationName: "No speech after Start"
                    ) {
                        try await iterator.next()
                    }
                } catch VoiceChatError.timedOut(_) {
                    recognizer.stop()
                    store.clearInterimUserTranscript()
                    transition(to: .idle)
                    return .noSpeechTimeout
                }
            }

            guard let event else {
                transition(to: .stopped)
                return .stopped
            }

            switch event {
            case .interim(let transcript):
                heardSpeech = true
                store.upsertInterimUserTranscript(transcript)
                eventSink(.interimTranscript(transcript))

            case .final(let transcript, let audioURL):
                recognizer.stop()
                return try await handleFinalTranscript(transcript, audioURL: audioURL)

            case .noSpeechTimeout:
                recognizer.stop()
                store.clearInterimUserTranscript()
                transition(to: .idle)
                return .noSpeechTimeout

            case .stopped:
                transition(to: .stopped)
                return .stopped
            }
        }

        transition(to: .stopped)
        return .stopped
    }

    public func handleFinalTranscript(_ transcript: String, audioURL: URL? = nil) async throws -> VoiceChatTurnResult {
        let trimmed = transcript.voiceChatTrimmed
        guard !trimmed.isEmpty else {
            store.clearInterimUserTranscript()
            return .skippedEmptyTranscript
        }

        if trimmed.isStandaloneStopCommand {
            stop()
            return .stopped
        }

        transition(to: .transcribing)
        let correctedTranscript: String
        if corrector.isAvailable {
            correctedTranscript = (try? await withTimeout(
                seconds: configuration.correctionTimeoutSeconds,
                operationName: "Transcript correction"
            ) {
                try await self.corrector.correct(transcript: trimmed, audioURL: audioURL)
            }) ?? trimmed
        } else {
            correctedTranscript = trimmed
        }

        let userMessage = try store.commitUserTranscript(correctedTranscript)
        eventSink(.finalTranscript(userMessage.content))

        let assistantText = try await answerLatestUserTurn()
        return .completed(userText: userMessage.content, assistantText: assistantText)
    }

    public func answerLatestUserTurn() async throws -> String {
        transition(to: .waitingForLLM)
        let requestMessages = messagesForLLMRequest()
        let assistant = store.startAssistantMessage()
        eventSink(.assistantStarted)
        var assistantText = ""

        do {
            for try await delta in llmClient.streamCompletion(messages: requestMessages) {
                try Task.checkCancellation()
                assistantText += delta
                try store.appendAssistantDelta(delta, to: assistant.id)
                eventSink(.assistantDelta(delta))
            }
        } catch is CancellationError {
            stop()
            throw VoiceChatError.stopped
        }

        let finalText = assistantText.voiceChatTrimmed
        eventSink(.assistantFinal(finalText))

        if !finalText.isEmpty {
            transition(to: .speaking)
            try await synthesizer.speak(finalText)
        }

        transition(to: .idle)
        return finalText
    }

    private func messagesForLLMRequest() -> [ChatMessage] {
        let prompt = configuration.systemPrompt.voiceChatTrimmed
        guard !prompt.isEmpty else {
            return store.messages
        }
        return [ChatMessage(role: .system, content: prompt)] + store.messages
    }

    public func stop() {
        setStopped(true)
        recognizer.stop()
        synthesizer.stop()
        transition(to: .stopped)
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    private func setStopped(_ value: Bool) {
        lock.withLock {
            stopped = value
        }
    }

    private func transition(to status: ConversationStatus) {
        store.setStatus(status)
        eventSink(.statusChanged(status))
    }
}

private final class SpeechEventIterator {
    private var iterator: AsyncThrowingStream<SpeechRecognitionEvent, Error>.Iterator

    init(_ iterator: AsyncThrowingStream<SpeechRecognitionEvent, Error>.Iterator) {
        self.iterator = iterator
    }

    func next() async throws -> SpeechRecognitionEvent? {
        try await iterator.next()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
