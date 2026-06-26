import Foundation
import XCTest
@testable import VoiceChatCore

final class ConversationStoreTests: XCTestCase {
    func testStatusTransitions() {
        let store = InMemoryConversationStore()

        store.setStatus(.listening)
        XCTAssertEqual(store.status, .listening)

        store.setStatus(.waitingForLLM)
        XCTAssertEqual(store.status, .waitingForLLM)

        store.setStatus(.speaking)
        XCTAssertEqual(store.status, .speaking)
    }

    func testInterimTranscriptIsReplacedByFinalTranscript() throws {
        let store = InMemoryConversationStore()

        let interim = store.upsertInterimUserTranscript("hel")
        let updated = store.upsertInterimUserTranscript("hello")
        let final = try store.commitUserTranscript("hello there")

        XCTAssertEqual(interim.id, updated.id)
        XCTAssertEqual(updated.id, final.id)
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].content, "hello there")
        XCTAssertFalse(store.messages[0].isInterim)
    }

    func testAssistantDeltaAppendsInOrder() throws {
        let store = InMemoryConversationStore()
        let assistant = store.startAssistantMessage()

        try store.appendAssistantDelta("Hello", to: assistant.id)
        try store.appendAssistantDelta(", world", to: assistant.id)

        XCTAssertEqual(store.messages.last?.content, "Hello, world")
    }

    func testClearRemovesMessagesAndInterimState() throws {
        let store = InMemoryConversationStore()
        store.upsertInterimUserTranscript("draft")
        store.clear()
        try store.commitUserTranscript("fresh")

        XCTAssertEqual(store.messages.map(\.content), ["fresh"])
    }
}

final class AudioEndpointDetectorTests: XCTestCase {
    func testDoesNotEndBeforeSpeechIsDetected() {
        var detector = AudioEndpointDetector(
            speechThresholdDecibels: -40,
            trailingSilenceSeconds: 1,
            minimumSpeechFrames: 2
        )

        XCTAssertFalse(detector.observe(powerDecibels: -80, timestamp: 0))
        XCTAssertFalse(detector.observe(powerDecibels: -80, timestamp: 2))
    }

    func testEndsAfterSpeechThenTrailingSilence() {
        var detector = AudioEndpointDetector(
            speechThresholdDecibels: -40,
            trailingSilenceSeconds: 1,
            minimumSpeechFrames: 2
        )

        XCTAssertFalse(detector.observe(powerDecibels: -20, timestamp: 0))
        XCTAssertFalse(detector.observe(powerDecibels: -20, timestamp: 0.1))
        XCTAssertFalse(detector.observe(powerDecibels: -80, timestamp: 0.2))
        XCTAssertFalse(detector.observe(powerDecibels: -80, timestamp: 1.0))
        XCTAssertTrue(detector.observe(powerDecibels: -80, timestamp: 1.3))
        XCTAssertFalse(detector.observe(powerDecibels: -80, timestamp: 2.5))
    }

    func testSpeechResetsTrailingSilenceWindow() {
        var detector = AudioEndpointDetector(
            speechThresholdDecibels: -40,
            trailingSilenceSeconds: 1,
            minimumSpeechFrames: 1
        )

        XCTAssertFalse(detector.observe(powerDecibels: -20, timestamp: 0))
        XCTAssertFalse(detector.observe(powerDecibels: -80, timestamp: 0.2))
        XCTAssertFalse(detector.observe(powerDecibels: -20, timestamp: 0.8))
        XCTAssertFalse(detector.observe(powerDecibels: -80, timestamp: 1.0))
        XCTAssertFalse(detector.observe(powerDecibels: -80, timestamp: 1.8))
        XCTAssertTrue(detector.observe(powerDecibels: -80, timestamp: 2.1))
    }
}

final class LMStudioClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testCompleteDecodesSuccessfulResponse() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"choices":[{"message":{"role":"assistant","content":"Hello from Gemma"}}]}"#
            return (response, Data(body.utf8))
        }

        let client = LMStudioClient(baseURL: URL(string: "http://example.test")!, session: mockSession())
        let result = try await client.complete(messages: [
            ChatMessage(role: .user, content: "hello")
        ])

        XCTAssertEqual(result, "Hello from Gemma")
    }

    func testCompleteThrowsOnUnavailableServer() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data("down".utf8))
        }

        let client = LMStudioClient(baseURL: URL(string: "http://example.test")!, session: mockSession())

        do {
            _ = try await client.complete(messages: [ChatMessage(role: .user, content: "hello")])
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 503"))
        }
    }

    func testCompleteThrowsOnMalformedJSON() async {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{".utf8))
        }

        let client = LMStudioClient(baseURL: URL(string: "http://example.test")!, session: mockSession())

        do {
            _ = try await client.complete(messages: [ChatMessage(role: .user, content: "hello")])
            XCTFail("Expected an error")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testStreamingSSEParser() throws {
        let line = #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#
        XCTAssertEqual(try LMStudioClient.parseServerSentEventLine(line), "Hi")
        XCTAssertNil(try LMStudioClient.parseServerSentEventLine("data: [DONE]"))
        XCTAssertNil(try LMStudioClient.parseServerSentEventLine(": keep-alive"))
    }

    func testTimeoutHelperThrows() async {
        do {
            _ = try await withTimeout(seconds: 0.01, operationName: "test timeout") {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return "late"
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("test timeout"))
        }
    }

    func testOptionalRealLMStudioIntegration() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LM_STUDIO_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LM_STUDIO_TESTS=1 to call the real LM Studio server.")
        }

        let client = LMStudioClient(requestTimeout: 15)
        let response = try await client.complete(messages: [
            ChatMessage(role: .user, content: "Reply with exactly: pong")
        ])
        XCTAssertFalse(response.voiceChatTrimmed.isEmpty)
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class SpeechSynthesizerTests: XCTestCase {
    func testAppleSayRunsSayCommand() async throws {
        let runner = MockProcessRunner(result: ProcessResult(exitCode: 0))
        let synthesizer = AppleSaySynthesizer(
            sayPath: makeExecutableTempFile(),
            runner: runner
        )

        try await synthesizer.speak("hello")

        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(runner.commands[0].arguments, ["hello"])
    }

    func testPiperUnavailableWithoutConfiguration() async {
        let synthesizer = PiperSynthesizer(configuration: nil, runner: MockProcessRunner())

        XCTAssertFalse(synthesizer.isAvailable)
        do {
            try await synthesizer.speak("hello")
            XCTFail("Expected unavailable error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Piper"))
        }
    }

    func testPiperConfigurationUsesRepoLocalDefaultWhenEnvironmentIsMissing() {
        let configuration = PiperConfiguration.fromEnvironment([
            "VOICE_CHAT_PROJECT_DIR": "/tmp/voice-chat"
        ])

        XCTAssertEqual(configuration?.binaryPath, "/tmp/voice-chat/.local/piper/piper/piper")
        XCTAssertEqual(configuration?.modelPath, "/tmp/voice-chat/.local/piper/voices/en_US-lessac-medium.onnx")
        XCTAssertEqual(configuration?.configPath, "/tmp/voice-chat/.local/piper/voices/en_US-lessac-medium.onnx.json")
    }

    func testPiperRunsSynthesisThenPlayback() async throws {
        let binary = makeExecutableTempFile()
        let model = makeTempFile()
        let afplay = makeExecutableTempFile()
        let runner = MockProcessRunner(result: ProcessResult(exitCode: 0))
        let synthesizer = PiperSynthesizer(
            configuration: PiperConfiguration(binaryPath: binary, modelPath: model),
            runner: runner,
            afplayPath: afplay
        )

        try await synthesizer.speak("hello")

        XCTAssertEqual(runner.commands.count, 2)
        XCTAssertEqual(runner.commands[0].executablePath, binary)
        XCTAssertEqual(runner.commands[0].standardInput, Data("hello".utf8))
        XCTAssertEqual(runner.commands[1].executablePath, afplay)
    }

    func testWhisperFallsBackWhenUnavailable() async throws {
        let corrector = WhisperCLITranscriptCorrector(configuration: nil, runner: MockProcessRunner())
        let result = try await corrector.correct(transcript: "apple final", audioURL: nil)
        XCTAssertEqual(result, "apple final")
    }

    func testWhisperCleansTimestampOutput() {
        let output = "[00:00:00.000 --> 00:00:01.000] Hello\n[00:00:01.000 --> 00:00:02.000] world"
        XCTAssertEqual(WhisperCLITranscriptCorrector.cleanWhisperOutput(output), "Hello world")
    }
}

final class VoiceChatSessionControllerTests: XCTestCase {
    func testSingleTurnShowsInterimCommitsFinalStreamsAnswerAndSpeaks() async throws {
        let recognizer = MockSpeechRecognizer(events: [
            .interim("hel"),
            .interim("hello"),
            .final("hello")
        ])
        let llm = MockLLMClient(chunks: ["Hi", " there"])
        let synthesizer = MockSynthesizer()
        var events: [VoiceChatEvent] = []

        let controller = VoiceChatSessionController(
            recognizer: recognizer,
            llmClient: llm,
            synthesizer: synthesizer,
            eventSink: { events.append($0) }
        )

        let result = try await controller.runSingleTurn()

        XCTAssertEqual(result, .completed(userText: "hello", assistantText: "Hi there"))
        XCTAssertEqual(synthesizer.spokenTexts, ["Hi there"])
        XCTAssertTrue(events.contains(.interimTranscript("hello")))
        XCTAssertTrue(events.contains(.finalTranscript("hello")))
    }

    func testStandaloneStopCommandStopsSession() async throws {
        let controller = VoiceChatSessionController(
            recognizer: MockSpeechRecognizer(events: [.final("stop")]),
            llmClient: MockLLMClient(chunks: ["nope"]),
            synthesizer: MockSynthesizer()
        )

        let result = try await controller.runSingleTurn()

        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(controller.store.status, .stopped)
    }

    func testEmptyTranscriptIsSuppressed() async throws {
        let controller = VoiceChatSessionController(
            recognizer: MockSpeechRecognizer(events: [.final("   ")]),
            llmClient: MockLLMClient(chunks: ["nope"]),
            synthesizer: MockSynthesizer()
        )

        let result = try await controller.runSingleTurn()

        XCTAssertEqual(result, .skippedEmptyTranscript)
        XCTAssertTrue(controller.store.messages.isEmpty)
    }

    func testNoSpeechTimeoutStopsIdleStartAttempt() async throws {
        let controller = VoiceChatSessionController(
            recognizer: MockSpeechRecognizer(events: [], finishImmediately: false),
            llmClient: MockLLMClient(chunks: []),
            synthesizer: MockSynthesizer(),
            configuration: VoiceChatConfiguration(noSpeechTimeoutSeconds: 0.01)
        )

        let result = try await controller.runSingleTurn()

        XCTAssertEqual(result, .noSpeechTimeout)
    }

    func testCorrectionFallbackUsesAppleFinalOnFailure() async throws {
        let controller = VoiceChatSessionController(
            recognizer: MockSpeechRecognizer(events: [.final("apple final")]),
            llmClient: MockLLMClient(chunks: ["ok"]),
            synthesizer: MockSynthesizer(),
            corrector: FailingCorrector()
        )

        let result = try await controller.runSingleTurn()

        XCTAssertEqual(result, .completed(userText: "apple final", assistantText: "ok"))
    }

    func testMultipleTurnsKeepMessageOrder() async throws {
        let store = InMemoryConversationStore()
        let first = VoiceChatSessionController(
            recognizer: MockSpeechRecognizer(events: [.final("one")]),
            llmClient: MockLLMClient(chunks: ["first"]),
            synthesizer: MockSynthesizer(),
            store: store
        )
        let second = VoiceChatSessionController(
            recognizer: MockSpeechRecognizer(events: [.final("two")]),
            llmClient: MockLLMClient(chunks: ["second"]),
            synthesizer: MockSynthesizer(),
            store: store
        )

        _ = try await first.runSingleTurn()
        _ = try await second.runSingleTurn()

        XCTAssertEqual(store.messages.map(\.content), ["one", "first", "two", "second"])
    }

    func testLLMRequestIncludesPreviousTurnsButNotEmptyAssistantPlaceholder() async throws {
        let store = InMemoryConversationStore()
        let llm = CapturingLLMClient(chunks: ["answer"])
        let first = VoiceChatSessionController(
            recognizer: MockSpeechRecognizer(events: [.final("one")]),
            llmClient: llm,
            synthesizer: MockSynthesizer(),
            store: store
        )
        let second = VoiceChatSessionController(
            recognizer: MockSpeechRecognizer(events: [.final("two")]),
            llmClient: llm,
            synthesizer: MockSynthesizer(),
            store: store
        )

        _ = try await first.runSingleTurn()
        _ = try await second.runSingleTurn()

        XCTAssertEqual(llm.requests.count, 2)
        XCTAssertEqual(llm.requests[0].map(\.role), [.system, .user])
        XCTAssertEqual(llm.requests[0].dropFirst().map(\.content), ["one"])
        XCTAssertEqual(llm.requests[1].map(\.role), [.system, .user, .assistant, .user])
        XCTAssertEqual(llm.requests[1].dropFirst().map(\.content), ["one", "answer", "two"])
        XCTAssertFalse(llm.requests[1].contains { $0.role == .assistant && $0.content.isEmpty })
    }

    func testLLMRequestCanDisableSystemPrompt() async throws {
        let llm = CapturingLLMClient(chunks: ["answer"])
        let controller = VoiceChatSessionController(
            recognizer: MockSpeechRecognizer(events: [.final("one")]),
            llmClient: llm,
            synthesizer: MockSynthesizer(),
            configuration: VoiceChatConfiguration(systemPrompt: "")
        )

        _ = try await controller.runSingleTurn()

        XCTAssertEqual(llm.requests.first?.map(\.role), [.user])
    }

    func testDefaultSystemPromptAsksForConciseVoiceChatTone() async throws {
        let llm = CapturingLLMClient(chunks: ["answer"])
        let controller = VoiceChatSessionController(
            recognizer: MockSpeechRecognizer(events: [.final("hello")]),
            llmClient: llm,
            synthesizer: MockSynthesizer()
        )

        _ = try await controller.runSingleTurn()

        let prompt = try XCTUnwrap(llm.requests.first?.first)
        XCTAssertEqual(prompt.role, .system)
        XCTAssertTrue(prompt.content.contains("1-3 sentences"))
        XCTAssertTrue(prompt.content.contains("relaxed conversation"))
        XCTAssertTrue(prompt.content.contains("avoid corporate phrases"))
    }
}

@MainActor
final class VoiceChatViewModelTests: XCTestCase {
    func testApplyEventsUpdatesChatAndStatus() {
        let viewModel = VoiceChatViewModel { _, store, _ in
            VoiceChatSessionController(
                recognizer: MockSpeechRecognizer(events: [.stopped]),
                llmClient: MockLLMClient(chunks: []),
                synthesizer: MockSynthesizer(),
                store: store
            )
        }

        viewModel.apply(.statusChanged(.listening))
        viewModel.apply(.interimTranscript("hel"))
        viewModel.apply(.interimTranscript("hello"))
        viewModel.apply(.finalTranscript("hello"))
        viewModel.apply(.assistantStarted)
        viewModel.apply(.assistantDelta("Hi"))
        viewModel.apply(.assistantDelta(" there"))
        viewModel.apply(.assistantFinal("Hi there"))

        XCTAssertEqual(viewModel.status, .listening)
        XCTAssertEqual(viewModel.messages.map(\.content), ["hello", "Hi there"])
        XCTAssertFalse(viewModel.messages[0].isInterim)
    }

    func testToggleTalkingStartsAndStops() async throws {
        let viewModel = VoiceChatViewModel { _, store, _ in
            VoiceChatSessionController(
                recognizer: MockSpeechRecognizer(events: [.stopped]),
                llmClient: MockLLMClient(chunks: []),
                synthesizer: MockSynthesizer(),
                store: store
            )
        }

        viewModel.toggleTalking()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(viewModel.isTalking)
        XCTAssertEqual(viewModel.status, .stopped)
    }

    func testAssistantDeltaStartsNewBubbleAfterNewUserMessage() {
        let viewModel = VoiceChatViewModel { _, store, _ in
            VoiceChatSessionController(
                recognizer: MockSpeechRecognizer(events: [.stopped]),
                llmClient: MockLLMClient(chunks: []),
                synthesizer: MockSynthesizer(),
                store: store
            )
        }

        viewModel.apply(.finalTranscript("question 1"))
        viewModel.apply(.assistantStarted)
        viewModel.apply(.assistantDelta("answer 1"))
        viewModel.apply(.assistantFinal("answer 1"))
        viewModel.apply(.finalTranscript("question 2"))
        viewModel.apply(.assistantStarted)
        viewModel.apply(.assistantDelta("answer 2"))

        XCTAssertEqual(viewModel.messages.map(\.content), [
            "question 1",
            "answer 1",
            "question 2",
            "answer 2"
        ])
    }

    func testClearChatRemovesVisibleMessagesAndStoreHistory() throws {
        let store = InMemoryConversationStore()
        let viewModel = VoiceChatViewModel(conversationStore: store) { _, store, _ in
            VoiceChatSessionController(
                recognizer: MockSpeechRecognizer(events: [.stopped]),
                llmClient: MockLLMClient(chunks: []),
                synthesizer: MockSynthesizer(),
                store: store
            )
        }

        viewModel.apply(.finalTranscript("question"))
        viewModel.apply(.assistantStarted)
        viewModel.apply(.assistantDelta("answer"))
        try store.commitUserTranscript("stored question")

        viewModel.clearChat()

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(viewModel.status, .idle)
    }
}

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw VoiceChatError.invalidResponse("missing mock handler")
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class MockProcessRunner: ProcessRunning {
    var commands: [ProcessCommand] = []
    var result: ProcessResult
    var stopped = false

    init(result: ProcessResult = ProcessResult(exitCode: 0)) {
        self.result = result
    }

    func run(_ command: ProcessCommand) async throws -> ProcessResult {
        commands.append(command)
        return result
    }

    func stop() {
        stopped = true
    }
}

final class MockSpeechRecognizer: SpeechRecognizer {
    let events: [SpeechRecognitionEvent]
    let finishImmediately: Bool
    var stopped = false

    init(events: [SpeechRecognitionEvent], finishImmediately: Bool = true) {
        self.events = events
        self.finishImmediately = finishImmediately
    }

    func start() -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if finishImmediately {
                continuation.finish()
            }
        }
    }

    func stop() {
        stopped = true
    }
}

struct MockLLMClient: LLMClient {
    var chunks: [String]

    func complete(messages: [ChatMessage]) async throws -> String {
        chunks.joined()
    }

    func streamCompletion(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

final class CapturingLLMClient: LLMClient {
    let chunks: [String]
    private(set) var requests: [[ChatMessage]] = []

    init(chunks: [String]) {
        self.chunks = chunks
    }

    func complete(messages: [ChatMessage]) async throws -> String {
        requests.append(messages)
        return chunks.joined()
    }

    func streamCompletion(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        requests.append(messages)
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

final class MockSynthesizer: SpeechSynthesizer {
    let name = "Mock"
    let isAvailable = true
    var spokenTexts: [String] = []
    var stopped = false

    func speak(_ text: String) async throws {
        spokenTexts.append(text)
    }

    func stop() {
        stopped = true
    }
}

struct FailingCorrector: FinalTranscriptCorrector {
    let name = "Failing"
    let isAvailable = true

    func correct(transcript: String, audioURL: URL?) async throws -> String {
        throw VoiceChatError.invalidResponse("correction failed")
    }
}

private func makeTempFile() -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
    return url.path
}

private func makeExecutableTempFile() -> String {
    let path = makeTempFile()
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}
