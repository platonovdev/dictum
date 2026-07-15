import Application
import AVFoundation
import Foundation

/// Generates two tiny cues in memory so feedback remains instant and does not
/// require bundled media files or an audio engine running while the app is idle.
@MainActor
public final class SynthesizedDictationSoundFeedbackService: DictationSoundFeedbackService {
    private static let sampleRate = 44_100

    private let recordingStartedCue = SynthesizedDictationSoundFeedbackService.makeCue(
        duration: 0.12,
        startFrequency: 480,
        endFrequency: 660,
        overtoneRatio: 1.5
    )
    private let processingStartedCue = SynthesizedDictationSoundFeedbackService.makeCue(
        duration: 0.14,
        startFrequency: 660,
        endFrequency: 500,
        overtoneRatio: 1.25
    )

    private var recordingStartedPlayer: AVAudioPlayer?
    private var processingStartedPlayer: AVAudioPlayer?

    public init() {}

    public func playRecordingStarted(volume: Double) {
        recordingStartedPlayer = play(recordingStartedCue, volume: volume)
    }

    public func playProcessingStarted(volume: Double) {
        processingStartedPlayer = play(processingStartedCue, volume: volume)
    }

    private func play(_ data: Data, volume: Double) -> AVAudioPlayer? {
        let clampedVolume = volume.isFinite ? min(max(volume, 0), 1) : 0
        guard clampedVolume > 0.001 else {
            return nil
        }

        guard let player = try? AVAudioPlayer(data: data) else {
            return nil
        }
        player.volume = Float(clampedVolume)
        player.prepareToPlay()
        player.play()
        return player
    }

    private static func makeCue(
        duration: TimeInterval,
        startFrequency: Double,
        endFrequency: Double,
        overtoneRatio: Double
    ) -> Data {
        let frameCount = max(Int(duration * Double(sampleRate)), 1)
        let attackFrames = max(Int(0.012 * Double(sampleRate)), 1)
        let releaseFrames = max(Int(0.07 * Double(sampleRate)), 1)
        var samples = Data(capacity: frameCount * MemoryLayout<Int16>.size)
        var phase = 0.0
        var overtonePhase = 0.0

        for frame in 0..<frameCount {
            let progress = Double(frame) / Double(max(frameCount - 1, 1))
            let easedProgress = progress * progress * (3 - (2 * progress))
            let frequency = startFrequency + ((endFrequency - startFrequency) * easedProgress)
            phase += 2 * Double.pi * frequency / Double(sampleRate)
            overtonePhase += 2 * Double.pi * frequency * overtoneRatio / Double(sampleRate)

            let attack = min(Double(frame) / Double(attackFrames), 1)
            let framesRemaining = frameCount - frame - 1
            let release = min(Double(framesRemaining) / Double(releaseFrames), 1)
            let envelope = sin(attack * Double.pi / 2) * sin(release * Double.pi / 2)
            let tone = (sin(phase) * 0.78) + (sin(overtonePhase) * 0.22)
            let normalized = max(-1, min(tone * envelope * 0.42, 1))
            samples.appendLittleEndian(Int16(normalized * Double(Int16.max)))
        }

        return makeWaveFile(pcmSamples: samples, frameCount: frameCount)
    }

    private static func makeWaveFile(pcmSamples: Data, frameCount: Int) -> Data {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt16(bitsPerSample / 8)
        let byteRate = UInt32(sampleRate) * UInt32(channelCount) * UInt32(bytesPerSample)
        let blockAlign = channelCount * bytesPerSample
        let dataSize = UInt32(frameCount) * UInt32(blockAlign)

        var wave = Data(capacity: 44 + Int(dataSize))
        wave.appendASCII("RIFF")
        wave.appendLittleEndian(UInt32(36) + dataSize)
        wave.appendASCII("WAVE")
        wave.appendASCII("fmt ")
        wave.appendLittleEndian(UInt32(16))
        wave.appendLittleEndian(UInt16(1))
        wave.appendLittleEndian(channelCount)
        wave.appendLittleEndian(UInt32(sampleRate))
        wave.appendLittleEndian(byteRate)
        wave.appendLittleEndian(blockAlign)
        wave.appendLittleEndian(bitsPerSample)
        wave.appendASCII("data")
        wave.appendLittleEndian(dataSize)
        wave.append(pcmSamples)
        return wave
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
