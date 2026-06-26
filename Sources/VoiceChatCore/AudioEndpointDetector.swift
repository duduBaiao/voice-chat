import Foundation

public struct AudioEndpointDetector: Sendable {
    public var initialNoiseFloorDecibels: Float
    public var speechMarginDecibels: Float
    public var silenceMarginDecibels: Float
    public var trailingSilenceSeconds: TimeInterval
    public var minimumSpeechFrames: Int
    public var calibrationFrames: Int

    private var noiseFloorDecibels: Float
    private var observedFrames = 0
    private var speechFrameCount = 0
    private var hasDetectedSpeech = false
    private var silenceStartedAt: TimeInterval?
    private var didEnd = false

    public init(
        initialNoiseFloorDecibels: Float = -60,
        speechMarginDecibels: Float = 10,
        silenceMarginDecibels: Float = 7,
        trailingSilenceSeconds: TimeInterval = 1.1,
        minimumSpeechFrames: Int = 3,
        calibrationFrames: Int = 8
    ) {
        self.initialNoiseFloorDecibels = initialNoiseFloorDecibels
        self.speechMarginDecibels = speechMarginDecibels
        self.silenceMarginDecibels = silenceMarginDecibels
        self.trailingSilenceSeconds = trailingSilenceSeconds
        self.minimumSpeechFrames = minimumSpeechFrames
        self.calibrationFrames = calibrationFrames
        noiseFloorDecibels = initialNoiseFloorDecibels
    }

    public mutating func observe(
        powerDecibels: Float,
        timestamp: TimeInterval,
        forceSpeechDetected: Bool = false
    ) -> Bool {
        guard !didEnd else { return false }

        observedFrames += 1

        if forceSpeechDetected {
            hasDetectedSpeech = true
            speechFrameCount = max(speechFrameCount, minimumSpeechFrames)
            let inferredNoiseFloor = powerDecibels - speechMarginDecibels
            if powerDecibels >= initialNoiseFloorDecibels + speechMarginDecibels,
               noiseFloorDecibels > inferredNoiseFloor {
                noiseFloorDecibels = inferredNoiseFloor
            }
        }

        if observedFrames <= calibrationFrames && !hasDetectedSpeech {
            updateNoiseFloor(with: powerDecibels, weight: 0.35)
            return false
        }

        let speechThreshold = noiseFloorDecibels + speechMarginDecibels
        let silenceThreshold = noiseFloorDecibels + silenceMarginDecibels

        if powerDecibels >= speechThreshold {
            speechFrameCount += 1
            silenceStartedAt = nil
            if speechFrameCount >= minimumSpeechFrames {
                hasDetectedSpeech = true
            }
            return false
        }

        updateNoiseFloor(with: powerDecibels, weight: hasDetectedSpeech ? 0.04 : 0.20)

        guard hasDetectedSpeech else {
            speechFrameCount = 0
            return false
        }

        guard powerDecibels <= silenceThreshold else {
            silenceStartedAt = nil
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

    private mutating func updateNoiseFloor(with powerDecibels: Float, weight: Float) {
        let clampedWeight = min(max(weight, 0), 1)
        noiseFloorDecibels = (noiseFloorDecibels * (1 - clampedWeight)) + (powerDecibels * clampedWeight)
    }
}
