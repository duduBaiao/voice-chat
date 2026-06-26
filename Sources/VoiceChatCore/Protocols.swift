import Foundation

public protocol SpeechRecognizer {
    func start() -> AsyncThrowingStream<SpeechRecognitionEvent, Error>
    func stop()
}

public protocol LLMClient {
    func complete(messages: [ChatMessage]) async throws -> String
    func streamCompletion(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
}

public protocol SpeechSynthesizer {
    var name: String { get }
    var isAvailable: Bool { get }
    func speak(_ text: String) async throws
    func stop()
}

public protocol ConversationStore {
    var status: ConversationStatus { get }
    var messages: [ChatMessage] { get }

    @discardableResult
    func append(_ message: ChatMessage) -> ChatMessage
    @discardableResult
    func upsertInterimUserTranscript(_ transcript: String) -> ChatMessage
    @discardableResult
    func commitUserTranscript(_ transcript: String) throws -> ChatMessage
    @discardableResult
    func startAssistantMessage() -> ChatMessage
    @discardableResult
    func appendAssistantDelta(_ delta: String, to id: UUID) throws -> ChatMessage
    func setStatus(_ status: ConversationStatus)
    func clearInterimUserTranscript()
    func clear()
}

public protocol FinalTranscriptCorrector {
    var name: String { get }
    var isAvailable: Bool { get }
    func correct(transcript: String, audioURL: URL?) async throws -> String
}

public protocol ProcessRunning {
    func run(_ command: ProcessCommand) async throws -> ProcessResult
    func stop()
}
