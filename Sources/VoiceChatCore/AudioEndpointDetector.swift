import Foundation

public struct AudioEndpointDetector: Sendable {
    public var speechThresholdDecibels: Float
    public var trailingSilenceSeconds: TimeInterval
    public var minimumSpeechFrames: Int

    private var speechFrameCount = 0
    private var hasDetectedSpeech = false
    private var silenceStartedAt: TimeInterval?
    private var didEnd = false

    public init(
        speechThresholdDecibels: Float = -45,
        trailingSilenceSeconds: TimeInterval = 1.1,
        minimumSpeechFrames: Int = 3
    ) {
        self.speechThresholdDecibels = speechThresholdDecibels
        self.trailingSilenceSeconds = trailingSilenceSeconds
        self.minimumSpeechFrames = minimumSpeechFrames
    }

    public mutating func observe(powerDecibels: Float, timestamp: TimeInterval) -> Bool {
        guard !didEnd else { return false }

        if powerDecibels >= speechThresholdDecibels {
            speechFrameCount += 1
            silenceStartedAt = nil
            if speechFrameCount >= minimumSpeechFrames {
                hasDetectedSpeech = true
            }
            return false
        }

        guard hasDetectedSpeech else {
            return false
        }

        if silenceStartedAt == nil {
            silenceStartedAt = timestamp
        }

        if let silenceStartedAt, timestamp - silenceStartedAt >= trailingSilenceSeconds {
            didEnd = true
            return true
        }

        return false
    }
}
