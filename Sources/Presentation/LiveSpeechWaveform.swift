import Domain
import Foundation

/// A genuine bar meter: each strip follows an incoming frequency band, with
/// a fast attack and slower release. There is deliberately no oscillator,
/// scroll offset, or idle animation — a quiet microphone stays quiet.
struct LiveSpeechWaveform {
    static let barCount = 15
    static let idleLevel: Float = 0.075

    private static let sensitivities: [Float] = [
        0.76, 0.92, 1.10, 0.86, 1.18,
        0.98, 1.24, 0.82, 1.14, 0.94,
        1.20, 0.88, 1.06, 0.80, 0.98
    ]

    private var displayedLevels = Array(repeating: idleLevel, count: barCount)

    mutating func update(with frame: AudioMeterFrame) -> [Float] {
        let sourceBands = frame.bands.isEmpty ? [frame.visualLevel] : frame.bands
        let loudness = min(max((frame.visualLevel - 0.018) / 0.68, 0), 1)

        for index in displayedLevels.indices {
            let position = Float(index) / Float(max(Self.barCount - 1, 1))
            let sourcePosition = position * Float(sourceBands.count - 1)
            let lower = Int(sourcePosition.rounded(.down))
            let upper = min(lower + 1, sourceBands.count - 1)
            let blend = sourcePosition - Float(lower)
            let band = sourceBands[lower] + ((sourceBands[upper] - sourceBands[lower]) * blend)

            // The band controls the character of a strip; loudness supplies a
            // common floor so quiet speech remains legible instead of blank.
            let input = (band * 0.72) + (loudness * 0.28)
            let target = min(max(input * Self.sensitivities[index], 0), 1)
            let response: Float = target > displayedLevels[index] ? 0.86 : 0.20
            displayedLevels[index] += (target - displayedLevels[index]) * response
            displayedLevels[index] = min(max(displayedLevels[index], Self.idleLevel), 1)
        }

        return displayedLevels
    }

    mutating func reset() {
        displayedLevels = Array(repeating: Self.idleLevel, count: Self.barCount)
    }
}
