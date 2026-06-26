import Foundation

public enum ChatRole: String, Codable, Equatable, Sendable {
    case system
    case user
    case assistant
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var role: ChatRole
    public var content: String
    public var isInterim: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        isInterim: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.isInterim = isInterim
        self.createdAt = createdAt
    }
}

public enum ConversationStatus: String, Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case waitingForLLM
    case speaking
    case stopped
}

public enum SpeechRecognitionEvent: Equatable, Sendable {
    case interim(String)
    case final(String, audioURL: URL? = nil)
    case noSpeechTimeout
    case stopped
}

public enum VoiceChatEvent: Equatable, Sendable {
    case statusChanged(ConversationStatus)
    case interimTranscript(String)
    case finalTranscript(String)
    case assistantStarted
    case assistantDelta(String)
    case assistantFinal(String)
    case info(String)
    case error(String)
}

public struct VoiceChatConfiguration: Equatable, Sendable {
    public static let defaultSystemPrompt = """
    You are Gemma, a warm voice-chat companion inside a local Mac app.
    Speak like a real person in a relaxed conversation, not like a help-center article.
    Keep replies short because they will be spoken aloud: usually 1-3 sentences.
    Be direct, lightly playful when it fits, and avoid corporate phrases like "How can I assist you today?"
    Do not make numbered lists unless the user asks for one.
    Do not explain that you are an AI model unless it is directly relevant.
    If the user gives feedback about your tone, adapt immediately without asking them to choose from options.
    """

    public var lmStudioBaseURL: URL
    public var lmStudioModel: String
    public var systemPrompt: String
    public var noSpeechTimeoutSeconds: TimeInterval
    public var correctionTimeoutSeconds: TimeInterval

    public init(
        lmStudioBaseURL: URL = URL(string: "http://100.127.238.44:1234")!,
        lmStudioModel: String = "google/gemma-4-26b-a4b-qat",
        systemPrompt: String = VoiceChatConfiguration.defaultSystemPrompt,
        noSpeechTimeoutSeconds: TimeInterval = 5,
        correctionTimeoutSeconds: TimeInterval = 4
    ) {
        self.lmStudioBaseURL = lmStudioBaseURL
        self.lmStudioModel = lmStudioModel
        self.systemPrompt = systemPrompt
        self.noSpeechTimeoutSeconds = noSpeechTimeoutSeconds
        self.correctionTimeoutSeconds = correctionTimeoutSeconds
    }
}

public enum VoiceChatError: Error, Equatable, LocalizedError {
    case componentUnavailable(String)
    case emptyTranscript
    case stopped
    case timedOut(String)
    case invalidResponse(String)
    case processFailed(command: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .componentUnavailable(let name):
            return "\(name) is unavailable."
        case .emptyTranscript:
            return "The transcript was empty."
        case .stopped:
            return "The voice chat session was stopped."
        case .timedOut(let operation):
            return "\(operation) timed out."
        case .invalidResponse(let reason):
            return "Invalid response: \(reason)"
        case .processFailed(let command, let exitCode, let stderr):
            return "\(command) failed with exit code \(exitCode): \(stderr)"
        }
    }
}

public extension String {
    var voiceChatTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isStandaloneStopCommand: Bool {
        let cleaned = lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!,?"))
        return cleaned == "stop"
    }
}
