import Combine
import Foundation

@MainActor
public final class VoiceChatViewModel: ObservableObject {
    public typealias ControllerFactory = (TTSBackend, ConversationStore, @escaping VoiceChatSessionController.EventSink) -> VoiceChatSessionController

    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var status: ConversationStatus = .idle
    @Published public private(set) var isTalking = false
    @Published public var selectedTTSBackend: TTSBackend = .apple

    private let makeController: ControllerFactory
    private let conversationStore: ConversationStore
    private var currentController: VoiceChatSessionController?
    private var loopTask: Task<Void, Never>?

    public init(
        conversationStore: ConversationStore = InMemoryConversationStore(),
        makeController: @escaping ControllerFactory
    ) {
        self.conversationStore = conversationStore
        self.makeController = makeController
    }

    public func toggleTalking() {
        isTalking ? stopTalking() : startTalking()
    }

    public func startTalking() {
        guard loopTask == nil else { return }
        isTalking = true
        status = .listening

        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isTalking {
                let backend = self.selectedTTSBackend
                let controller = self.makeController(backend, self.conversationStore) { event in
                    Task { @MainActor [weak self] in
                        self?.apply(event)
                    }
                }
                self.setCurrentController(controller)

                do {
                    let result = try await controller.runSingleTurn()
                    if result != .completed(userText: "", assistantText: "") {
                        switch result {
                        case .completed:
                            continue
                        case .skippedEmptyTranscript:
                            continue
                        case .noSpeechTimeout, .stopped:
                            self.finishTalking()
                            return
                        }
                    }
                } catch {
                    self.apply(.error(error.localizedDescription))
                    self.finishTalking()
                    return
                }
            }
        }
    }

    public func stopTalking() {
        currentController?.stop()
        loopTask?.cancel()
        finishTalking()
    }

    public func clearChat() {
        currentController?.stop()
        loopTask?.cancel()
        messages.removeAll()
        conversationStore.clear()
        finishTalking()
        status = .idle
    }

    public func apply(_ event: VoiceChatEvent) {
        switch event {
        case .statusChanged(let status):
            self.status = status
        case .interimTranscript(let transcript):
            upsertInterimUserMessage(transcript)
        case .finalTranscript(let transcript):
            commitUserMessage(transcript)
        case .assistantStarted:
            startAssistantMessage()
        case .assistantDelta(let delta):
            appendAssistantDelta(delta)
        case .assistantFinal(let text):
            finalizeAssistant(text)
        case .info:
            break
        case .error(let message):
            appendSystemMessage(message)
        }
    }

    private func upsertInterimUserMessage(_ transcript: String) {
        if let index = messages.lastIndex(where: { $0.role == .user && $0.isInterim }) {
            messages[index].content = transcript
        } else {
            messages.append(ChatMessage(role: .user, content: transcript, isInterim: true))
        }
    }

    private func commitUserMessage(_ transcript: String) {
        if let index = messages.lastIndex(where: { $0.role == .user && $0.isInterim }) {
            messages[index].content = transcript
            messages[index].isInterim = false
        } else {
            messages.append(ChatMessage(role: .user, content: transcript))
        }
    }

    private func appendAssistantDelta(_ delta: String) {
        if messages.last?.role == .assistant {
            let index = messages.count - 1
            messages[index].content += delta
        } else {
            messages.append(ChatMessage(role: .assistant, content: delta))
        }
    }

    private func finalizeAssistant(_ text: String) {
        guard !text.isEmpty else { return }
        if messages.last?.role == .assistant {
            let index = messages.count - 1
            messages[index].content = text
        } else {
            messages.append(ChatMessage(role: .assistant, content: text))
        }
    }

    private func startAssistantMessage() {
        guard messages.last?.role != .assistant else { return }
        messages.append(ChatMessage(role: .assistant, content: ""))
    }

    private func appendSystemMessage(_ text: String) {
        messages.append(ChatMessage(role: .system, content: text))
    }

    private func setCurrentController(_ controller: VoiceChatSessionController) {
        currentController = controller
    }

    private func finishTalking() {
        isTalking = false
        status = .stopped
        currentController = nil
        loopTask = nil
    }
}
