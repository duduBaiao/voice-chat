import Foundation

public final class InMemoryConversationStore: ConversationStore {
    private let lock = NSLock()
    private var storedMessages: [ChatMessage]
    private var storedStatus: ConversationStatus
    private var interimUserMessageID: UUID?

    public init(messages: [ChatMessage] = [], status: ConversationStatus = .idle) {
        storedMessages = messages
        storedStatus = status
    }

    public var status: ConversationStatus {
        lock.withLock { storedStatus }
    }

    public var messages: [ChatMessage] {
        lock.withLock { storedMessages }
    }

    @discardableResult
    public func append(_ message: ChatMessage) -> ChatMessage {
        lock.withLock {
            storedMessages.append(message)
            return message
        }
    }

    @discardableResult
    public func upsertInterimUserTranscript(_ transcript: String) -> ChatMessage {
        lock.withLock {
            if let id = interimUserMessageID,
               let index = storedMessages.firstIndex(where: { $0.id == id }) {
                storedMessages[index].content = transcript
                storedMessages[index].isInterim = true
                return storedMessages[index]
            }

            let message = ChatMessage(role: .user, content: transcript, isInterim: true)
            interimUserMessageID = message.id
            storedMessages.append(message)
            return message
        }
    }

    @discardableResult
    public func commitUserTranscript(_ transcript: String) throws -> ChatMessage {
        let trimmed = transcript.voiceChatTrimmed
        guard !trimmed.isEmpty else {
            throw VoiceChatError.emptyTranscript
        }

        return lock.withLock {
            if let id = interimUserMessageID,
               let index = storedMessages.firstIndex(where: { $0.id == id }) {
                storedMessages[index].content = trimmed
                storedMessages[index].isInterim = false
                interimUserMessageID = nil
                return storedMessages[index]
            }

            let message = ChatMessage(role: .user, content: trimmed)
            storedMessages.append(message)
            return message
        }
    }

    @discardableResult
    public func startAssistantMessage() -> ChatMessage {
        let message = ChatMessage(role: .assistant, content: "")
        return append(message)
    }

    @discardableResult
    public func appendAssistantDelta(_ delta: String, to id: UUID) throws -> ChatMessage {
        try lock.withLock {
            guard let index = storedMessages.firstIndex(where: { $0.id == id }) else {
                throw VoiceChatError.invalidResponse("assistant message \(id) does not exist")
            }
            storedMessages[index].content += delta
            return storedMessages[index]
        }
    }

    public func setStatus(_ status: ConversationStatus) {
        lock.withLock {
            storedStatus = status
        }
    }

    public func clearInterimUserTranscript() {
        lock.withLock {
            guard let id = interimUserMessageID else { return }
            storedMessages.removeAll { $0.id == id }
            interimUserMessageID = nil
        }
    }

    public func clear() {
        lock.withLock {
            storedMessages.removeAll()
            interimUserMessageID = nil
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
