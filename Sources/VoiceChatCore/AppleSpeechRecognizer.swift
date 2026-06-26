import AVFoundation
import Foundation
import Speech

public final class AppleSpeechRecognizer: NSObject, SpeechRecognizer {
    private let speechRecognizer: SFSpeechRecognizer?
    private let recordUtteranceAudio: Bool
    private let endpointDetectorTemplate: AudioEndpointDetector
    private let audioEngine = AVAudioEngine()
    private let lock = NSLock()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var audioURL: URL?
    private var latestTranscript = ""
    private var hasFinishedCurrentRecognition = false

    public init(
        locale: Locale = .current,
        recordUtteranceAudio: Bool = true,
        endpointDetector: AudioEndpointDetector = AudioEndpointDetector()
    ) {
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        self.recordUtteranceAudio = recordUtteranceAudio
        endpointDetectorTemplate = endpointDetector
        super.init()
    }

    public func start() -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await startRecognition(continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.stop()
            }
        }
    }

    public func stop() {
        lock.withLock {
            if audioEngine.isRunning {
                audioEngine.inputNode.removeTap(onBus: 0)
                audioEngine.stop()
            }
            recognitionRequest?.endAudio()
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            audioFile = nil
            audioURL = nil
            latestTranscript = ""
            hasFinishedCurrentRecognition = false
        }
    }

    private func startRecognition(continuation: AsyncThrowingStream<SpeechRecognitionEvent, Error>.Continuation) async throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw VoiceChatError.componentUnavailable("Apple Speech")
        }

        let authorization = await requestSpeechAuthorization()
        guard authorization == .authorized else {
            throw VoiceChatError.componentUnavailable("Apple Speech authorization")
        }

        let microphoneAuthorized = await requestMicrophoneAuthorization()
        guard microphoneAuthorized else {
            throw VoiceChatError.componentUnavailable("Microphone authorization")
        }

        stop()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let utteranceURL = recordUtteranceAudio ? temporaryUtteranceURL() : nil
        let file = try utteranceURL.map {
            try AVAudioFile(forWriting: $0, settings: format.settings)
        }

        lock.withLock {
            recognitionRequest = request
            audioFile = file
            audioURL = utteranceURL
            latestTranscript = ""
            hasFinishedCurrentRecognition = false
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let transcript = result.bestTranscription.formattedString
                self?.lock.withLock {
                    self?.latestTranscript = transcript
                }
                if result.isFinal {
                    self?.finishRecognition(
                        transcript: transcript,
                        continuation: continuation,
                        endAudio: false
                    )
                } else {
                    continuation.yield(.interim(transcript))
                }
            }

            if let error {
                continuation.finish(throwing: error)
            }
        }

        var endpointDetector = endpointDetectorTemplate
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let hasTranscript = self?.lock.withLock {
                self?.latestTranscript.voiceChatTrimmed.isEmpty == false
            } ?? false
            let shouldFinish = endpointDetector.observe(
                powerDecibels: buffer.voiceChatPowerDecibels,
                timestamp: Date().timeIntervalSinceReferenceDate,
                forceSpeechDetected: hasTranscript
            )
            self?.lock.withLock {
                try? self?.audioFile?.write(from: buffer)
            }
            if shouldFinish {
                let transcript = self?.lock.withLock { self?.latestTranscript } ?? ""
                self?.finishRecognition(
                    transcript: transcript,
                    continuation: continuation,
                    endAudio: true
                )
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func temporaryUtteranceURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-chat-utterance-\(UUID().uuidString).wav")
    }

    private func finishRecognition(
        transcript: String,
        continuation: AsyncThrowingStream<SpeechRecognitionEvent, Error>.Continuation,
        endAudio: Bool
    ) {
        let finishState: (shouldYield: Bool, audioURL: URL?) = lock.withLock {
            guard !hasFinishedCurrentRecognition else {
                return (false, nil)
            }
            hasFinishedCurrentRecognition = true
            return (true, audioURL)
        }

        guard finishState.shouldYield else { return }

        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        if endAudio {
            recognitionRequest?.endAudio()
        }

        continuation.yield(.final(transcript, audioURL: finishState.audioURL))
        continuation.finish()
    }
}

private extension AVAudioPCMBuffer {
    var voiceChatPowerDecibels: Float {
        guard let channelData = floatChannelData else {
            return -100
        }

        let channelCount = Int(format.channelCount)
        let frameCount = Int(frameLength)
        guard channelCount > 0, frameCount > 0 else {
            return -100
        }

        var squareSum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                squareSum += sample * sample
            }
        }

        let meanSquare = squareSum / Float(channelCount * frameCount)
        guard meanSquare > 0 else {
            return -100
        }

        return 10 * log10(meanSquare)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
