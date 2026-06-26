import Foundation

public struct LMStudioClient: LLMClient {
    public var baseURL: URL
    public var model: String
    public var requestTimeout: TimeInterval
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(
        baseURL: URL = VoiceChatConfiguration().lmStudioBaseURL,
        model: String = VoiceChatConfiguration().lmStudioModel,
        requestTimeout: TimeInterval = 60,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.requestTimeout = requestTimeout
        self.session = session
    }

    public func complete(messages: [ChatMessage]) async throws -> String {
        var request = try makeRequest(messages: messages, stream: false)
        request.timeoutInterval = requestTimeout

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let completion = try decoder.decode(ChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message?.content else {
            throw VoiceChatError.invalidResponse("missing assistant message content")
        }
        return content
    }

    public func streamCompletion(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try makeRequest(messages: messages, stream: true)
                    request.timeoutInterval = requestTimeout

                    let (bytes, response) = try await session.bytes(for: request)
                    try validate(response: response, data: nil)

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let chunk = try Self.parseServerSentEventLine(line) else {
                            continue
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func makeRequest(messages: [ChatMessage], stream: Bool) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent("chat").appendingPathComponent("completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
            model: model,
            messages: messages
                .filter { !$0.isInterim }
                .map { ChatCompletionMessage(role: $0.role.rawValue, content: $0.content) },
            stream: stream
        ))
        return request
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VoiceChatError.invalidResponse("response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw VoiceChatError.invalidResponse("HTTP \(http.statusCode) \(body)")
        }
    }

    public static func parseServerSentEventLine(_ line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }

        let data = Data(payload.utf8)
        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)
        return chunk.choices.first?.delta.content
    }
}

private struct ChatCompletionRequest: Encodable {
    var model: String
    var messages: [ChatCompletionMessage]
    var stream: Bool
}

private struct ChatCompletionMessage: Codable {
    var role: String
    var content: String
}

private struct ChatCompletionResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: ChatCompletionMessage?
    }
}

private struct ChatCompletionChunk: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var delta: Delta
    }

    struct Delta: Decodable {
        var content: String?
    }
}
