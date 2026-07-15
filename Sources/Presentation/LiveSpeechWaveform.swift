import Domain
import Foundation

/// A stationary voice meter: every bar keeps its horizontal position and only
/// changes height. Current loudness drives the whole meter while inexpensive
/// low/mid/high energy values give the bars a natural, speech-shaped profile.
struct LiveSpeechWaveform {
    static let barCount = 15
    static let idleLevel: Float = 0.015

    private static let sensitivities: [Float] = [
        0.78, 0.90, 1.04, 0.88, 1.12,
        0.96, 1.18, 0.91, 1.10, 0.95,
        1.14, 0.89, 1.05, 0.84, 0.94
    ]

    private var displayedLevels = Array(repeating: idleLevel, count: barCount)

    mutating func update(with frame: AudioMeterFrame) -> [Float] {
        // Use the signal itself as the source of truth. Speech confidence only
        // adds a subtle boost, so a detector miss can never blank a real voice.
        let capturedLevel = clamp(
            (frame.visualLevel * 0.80) +
            (min(frame.overallLevel * 1.20, 1) * 0.20)
        )
        let normalizedLevel = clamp((capturedLevel - 0.045) / 0.74)
        let gate = smoothStep(normalizedLevel, from: 0.04, to: 0.22)
        let amplitude = pow(normalizedLevel, 0.76) * gate
        let confidenceBoost = 0.90 + (clamp(frame.speechConfidence) * 0.10)
        let sourceBands = frame.bands.isEmpty ? [Float(0.72)] : frame.bands

        for index in displayedLevels.indices {
            let band = interpolatedBand(at: index, from: sourceBands)
            let spectralShape = 0.48 + (clamp(band) * 0.52)
            let target = clamp(
                Self.idleLevel +
                (amplitude * spectralShape * Self.sensitivities[index] * confidenceBoost)
            )

            // About 100 ms attack and 250 ms release at the 25 fps meter rate:
            // responsive enough for speech, but calm enough not to demand focus.
            let response: Float = target > displayedLevels[index] ? 0.36 : 0.14
            displayedLevels[index] += (target - displayedLevels[index]) * response
            displayedLevels[index] = max(displayedLevels[index], Self.idleLevel)
        }

        return displayedLevels
    }

    mutating func reset() {
        displayedLevels = Array(repeating: Self.idleLevel, count: Self.barCount)
    }

    private func interpolatedBand(at index: Int, from source: [Float]) -> Float {
        guard source.count > 1 else {
            return source.first ?? 0
        }

        let position = Float(index) / Float(max(Self.barCount - 1, 1))
        let sourcePosition = position * Float(source.count - 1)
        let lower = Int(sourcePosition.rounded(.down))
        let upper = min(lower + 1, source.count - 1)
        let blend = sourcePosition - Float(lower)
        return source[lower] + ((source[upper] - source[lower]) * blend)
    }

    private func smoothStep(_ value: Float, from lower: Float, to upper: Float) -> Float {
        let progress = clamp((value - lower) / (upper - lower))
        return progress * progress * (3 - (2 * progress))
    }

    private func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
