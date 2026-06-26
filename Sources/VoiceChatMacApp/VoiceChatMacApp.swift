import SwiftUI
import VoiceChatCore

@main
struct VoiceChatMacApp: App {
    @StateObject private var viewModel = VoiceChatViewModel { backend, lmStudioBaseURL, store, eventSink in
        VoiceChatSessionController(
            recognizer: AppleSpeechRecognizer(),
            llmClient: LMStudioClient(baseURL: lmStudioBaseURL),
            synthesizer: makeSynthesizer(for: backend),
            corrector: makeCorrector(),
            store: store,
            eventSink: eventSink
        )
    }

    var body: some Scene {
        WindowGroup {
            VoiceChatView(viewModel: viewModel)
                .frame(minWidth: 720, minHeight: 560)
        }
    }
}

private func makeSynthesizer(for backend: TTSBackend) -> SpeechSynthesizer {
    switch backend {
    case .apple:
        return AppleAVSpeechSynthesizerAdapter()
    case .piper:
        return PiperSynthesizer()
    }
}

private func makeCorrector() -> FinalTranscriptCorrector {
    let whisper = WhisperCLITranscriptCorrector()
    return whisper.isAvailable ? whisper : NoopTranscriptCorrector()
}

struct VoiceChatView: View {
    @ObservedObject var viewModel: VoiceChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            controls
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice Chat")
                    .font(.title2.weight(.semibold))
                Text(viewModel.status.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Text("LM Studio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("http://host:1234", text: $viewModel.lmStudioBaseURLText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .foregroundColor(viewModel.isLMStudioBaseURLValid ? Color.primary : Color.red)
                    .disabled(viewModel.isTalking)
                    .help("LM Studio base URL")
            }
            Picker("TTS", selection: $viewModel.selectedTTSBackend) {
                Text("Apple").tag(TTSBackend.apple)
                Text("Piper").tag(TTSBackend.piper)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
        .padding()
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.messages) { _, messages in
                guard let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.toggleTalking()
            } label: {
                Label(
                    viewModel.isTalking ? "Stop talking" : "Start talking",
                    systemImage: viewModel.isTalking ? "stop.fill" : "mic.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                viewModel.clearChat()
            } label: {
                Label("Clear chat", systemImage: "trash")
            }
            .disabled(viewModel.messages.isEmpty)
            .help("Clear chat and history")
        }
        .padding()
    }

    private var statusText: String {
        switch viewModel.status {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening"
        case .transcribing:
            return "Transcribing"
        case .waitingForLLM:
            return "Thinking"
        case .speaking:
            return "Speaking"
        case .stopped:
            return "Stopped"
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant || message.role == .system {
                bubble
                Spacer(minLength: 80)
            } else {
                Spacer(minLength: 80)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message.content.isEmpty ? "..." : message.content)
                .font(.body)
                .textSelection(.enabled)
                .opacity(message.isInterim ? 0.72 : 1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: 460, alignment: .leading)
    }

    private var title: String {
        switch message.role {
        case .system:
            return "System"
        case .user:
            return message.isInterim ? "You" : "You"
        case .assistant:
            return "Gemma"
        }
    }

    private var background: Color {
        switch message.role {
        case .system:
            return Color(nsColor: .controlBackgroundColor)
        case .user:
            return Color.accentColor.opacity(0.16)
        case .assistant:
            return Color(nsColor: .textBackgroundColor)
        }
    }
}
