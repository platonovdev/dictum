import AVFoundation
import Accelerate
import Application
import Domain
import Foundation

@MainActor
public final class AVAudioCaptureService: AudioCaptureService {
    private let audioEngine = AVAudioEngine()
    private let tapSink = TapSink()

    private var outputURL: URL?
    private var startedAt: Date?

    public init() {}

    public func makeMeterStream() -> AsyncStream<AudioMeterFrame> {
        tapSink.makeMeterStream()
    }

    public func startRecording() async throws {
        guard !audioEngine.isRunning else {
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneBtnVoice-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let outputFile = try AVAudioFile(forWriting: url, settings: format.settings)
        outputURL = url
        startedAt = Date()
        tapSink.configure(outputFile: outputFile)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: tapSink.makeTapHandler()
        )

        audioEngine.prepare()
        try audioEngine.start()
    }

    public func stopRecording() async throws -> CapturedAudio {
        guard audioEngine.isRunning, let outputURL else {
            throw AppError.audioCaptureFailed("No active recording session.")
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        let duration = Date().timeIntervalSince(startedAt ?? Date())

        tapSink.clear()

        startedAt = nil
        return CapturedAudio(fileURL: outputURL, duration: duration)
    }

    public func cancelRecording() async {
        guard audioEngine.isRunning else {
            tapSink.clear()
            outputURL = nil
            startedAt = nil
            return
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        tapSink.clear()
        outputURL = nil
        startedAt = nil
    }

}

private final class TapSink: @unchecked Sendable {
    private let lock = NSLock()
    private let meterBroadcast = AsyncBroadcast<AudioMeterFrame>()
    private let meterAnalyzer = AudioMeterAnalyzer()

    private var outputFile: AVAudioFile?

    func makeMeterStream() -> AsyncStream<AudioMeterFrame> {
        meterBroadcast.stream()
    }

    func configure(outputFile: AVAudioFile) {
        lock.lock()
        self.outputFile = outputFile
        lock.unlock()
    }

    func handle(buffer: AVAudioPCMBuffer) {
        lock.lock()
        let outputFile = self.outputFile
        lock.unlock()

        try? outputFile?.write(from: buffer)
        meterBroadcast.yield(meterAnalyzer.analyze(buffer: buffer))
    }

    func makeTapHandler() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
    }

    func clear() {
        lock.lock()
        outputFile = nil
        lock.unlock()
        meterAnalyzer.reset()
    }
}

private final class AudioMeterAnalyzer: @unchecked Sendable {
    private let bandWeights: [[Float]] = [
        [0.08, 0.20, 1.00],
        [0.12, 0.36, 0.90],
        [0.28, 0.64, 0.52],
        [0.54, 0.82, 0.24],
        [1.00, 0.46, 0.10],
        [0.54, 0.82, 0.24],
        [0.28, 0.64, 0.52],
        [0.12, 0.36, 0.90],
        [0.08, 0.20, 1.00]
    ]

    private var slowLowPass: Float = 0
    private var fastLowPass: Float = 0
    private var smoothedBands = Array(repeating: Float(0), count: 9)

    func analyze(buffer: AVAudioPCMBuffer) -> AudioMeterFrame {
        guard let channelData = buffer.floatChannelData else {
            return .silent
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return .silent
        }

        let channel = channelData[0]
        let segmentSize = max(frameLength / bandWeights.count, 1)
        var overallEnergy: Float = 0
        var lowEnergy: Float = 0
        var midEnergy: Float = 0
        var highEnergy: Float = 0
        var segmentPeaks = Array(repeating: Float(0), count: bandWeights.count)

        for index in 0..<frameLength {
            let sample = channel[index]
            overallEnergy += sample * sample

            fastLowPass += 0.18 * (sample - fastLowPass)
            slowLowPass += 0.045 * (sample - slowLowPass)

            let lowSample = slowLowPass
            let midSample = fastLowPass - slowLowPass
            let highSample = sample - fastLowPass

            lowEnergy += lowSample * lowSample
            midEnergy += midSample * midSample
            highEnergy += highSample * highSample

            let segmentIndex = min(index / segmentSize, segmentPeaks.count - 1)
            segmentPeaks[segmentIndex] = max(segmentPeaks[segmentIndex], abs(sample))
        }

        let overallLevel = normalizedLevel(energy: overallEnergy, frameLength: frameLength, gain: 28)
        let lowLevel = normalizedLevel(energy: lowEnergy, frameLength: frameLength, gain: 46)
        let midLevel = normalizedLevel(energy: midEnergy, frameLength: frameLength, gain: 60)
        let highLevel = normalizedLevel(energy: highEnergy, frameLength: frameLength, gain: 88)

        var bands: [Float] = []
        bands.reserveCapacity(bandWeights.count)

        for index in bandWeights.indices {
            let weights = bandWeights[index]
            let envelopeLevel = min(pow(segmentPeaks[index] * 4.8, 0.72), 1)
            let rawLevel = min(
                max(
                    (lowLevel * weights[0]) +
                    (midLevel * weights[1]) +
                    (highLevel * weights[2]) +
                    (envelopeLevel * 0.22),
                    0
                ),
                1
            )
            let attack: Float = rawLevel > smoothedBands[index] ? 0.58 : 0.18
            smoothedBands[index] += (rawLevel - smoothedBands[index]) * attack
            bands.append(smoothedBands[index])
        }

        return AudioMeterFrame(overallLevel: overallLevel, bands: bands)
    }

    func reset() {
        slowLowPass = 0
        fastLowPass = 0
        smoothedBands = Array(repeating: 0, count: bandWeights.count)
    }

    private func normalizedLevel(energy: Float, frameLength: Int, gain: Float) -> Float {
        let rms = sqrt(energy / Float(frameLength))
        return min(max(rms * gain, 0), 1)
    }
}
