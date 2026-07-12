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
            bufferSize: 2048,
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
        // Meter consumers only need the freshest sample. Dropping stale frames
        // keeps long sessions from building an async backlog.
        meterBroadcast.stream(bufferingPolicy: .bufferingNewest(1))
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
    private static let fftSize = 2048
    private static let fftLog2n = vDSP_Length(11)
    private static let spectrumBandCount = 15

    private let fftSetup: FFTSetup
    private var fftWindow = [Float](repeating: 0, count: fftSize)
    private var fftInput = [Float](repeating: 0, count: fftSize)
    private var fftReal = [Float](repeating: 0, count: fftSize / 2)
    private var fftImaginary = [Float](repeating: 0, count: fftSize / 2)
    private var fftMagnitudes = [Float](repeating: 0, count: fftSize / 2)

    private var slowLowPass: Float = 0
    private var fastLowPass: Float = 0
    private var smoothedBands = Array(repeating: Float(0), count: spectrumBandCount)
    private var speechDetector = RealtimeSpeechActivityDetector()

    init() {
        guard let fftSetup = vDSP_create_fftsetup(Self.fftLog2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Could not create the audio spectrum FFT setup.")
        }
        self.fftSetup = fftSetup
        vDSP_hann_window(&fftWindow, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func analyze(buffer: AVAudioPCMBuffer) -> AudioMeterFrame {
        guard let channelData = buffer.floatChannelData else {
            return .silent
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return .silent
        }

        let channel = channelData[0]
        var overallEnergy: Float = 0
        var lowEnergy: Float = 0
        var midEnergy: Float = 0
        var highEnergy: Float = 0
        var overallPeak: Float = 0

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

            overallPeak = max(overallPeak, abs(sample))
        }

        let overallLevel = normalizedLevel(energy: overallEnergy, frameLength: frameLength, gain: 28)
        let overallRMS = sqrt(overallEnergy / Float(frameLength))
        let frameDuration = TimeInterval(buffer.frameLength) / buffer.format.sampleRate
        let rmsDB = decibels(for: overallRMS)
        let peakDB = decibels(for: overallPeak)
        let lowDB = decibels(for: sqrt(lowEnergy / Float(frameLength)))
        let midDB = decibels(for: sqrt(midEnergy / Float(frameLength)))
        let highDB = decibels(for: sqrt(highEnergy / Float(frameLength)))
        let speechDecision = speechDetector.process(
            rmsDB: rmsDB,
            peakDB: peakDB,
            lowDB: lowDB,
            midDB: midDB,
            highDB: highDB,
            frameDuration: Float(frameDuration)
        )
        let visualLevel = normalizedVisualLevel(rms: overallRMS, peak: overallPeak)
        let bands = spectrumBands(
            channel: channel,
            frameLength: frameLength,
            sampleRate: buffer.format.sampleRate
        )

        return AudioMeterFrame(
            overallLevel: overallLevel,
            visualLevel: visualLevel,
            speechConfidence: speechDecision.confidence,
            isSpeechDetected: speechDecision.isSpeechDetected,
            frameDuration: frameDuration,
            bands: bands
        )
    }

    func reset() {
        slowLowPass = 0
        fastLowPass = 0
        smoothedBands = Array(repeating: 0, count: Self.spectrumBandCount)
        speechDetector.reset()
    }

    private func spectrumBands(
        channel: UnsafePointer<Float>,
        frameLength: Int,
        sampleRate: Double
    ) -> [Float] {
        let availableSamples = min(frameLength, Self.fftSize)
        let sourceOffset = max(frameLength - availableSamples, 0)
        fftWindow.withUnsafeBufferPointer { window in
            fftInput.withUnsafeMutableBufferPointer { destination in
                destination.initialize(repeating: 0)
                vDSP_vmul(
                    channel.advanced(by: sourceOffset),
                    1,
                    window.baseAddress!.advanced(by: Self.fftSize - availableSamples),
                    1,
                    destination.baseAddress!.advanced(by: Self.fftSize - availableSamples),
                    1,
                    vDSP_Length(availableSamples)
                )
            }
        }

        fftInput.withUnsafeBufferPointer { input in
            fftReal.withUnsafeMutableBufferPointer { real in
                fftImaginary.withUnsafeMutableBufferPointer { imaginary in
                    var splitComplex = DSPSplitComplex(
                        realp: real.baseAddress!,
                        imagp: imaginary.baseAddress!
                    )
                    input.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: Self.fftSize / 2
                    ) { complexInput in
                        vDSP_ctoz(complexInput, 2, &splitComplex, 1, vDSP_Length(Self.fftSize / 2))
                    }
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, Self.fftLog2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&splitComplex, 1, &fftMagnitudes, 1, vDSP_Length(Self.fftSize / 2))
                }
            }
        }

        let minimumFrequency: Float = 70
        let maximumFrequency = min(Float(sampleRate / 2) * 0.92, 8_000)
        let ratio = maximumFrequency / minimumFrequency
        let frequencyPerBin = Float(sampleRate) / Float(Self.fftSize)
        var result = [Float]()
        result.reserveCapacity(Self.spectrumBandCount)

        for index in 0..<Self.spectrumBandCount {
            let start = minimumFrequency * pow(ratio, Float(index) / Float(Self.spectrumBandCount))
            let end = minimumFrequency * pow(ratio, Float(index + 1) / Float(Self.spectrumBandCount))
            let lowerBin = max(1, Int(start / frequencyPerBin))
            let upperBin = min(fftMagnitudes.count - 1, max(lowerBin, Int(end / frequencyPerBin)))
            let peakPower = fftMagnitudes[lowerBin...upperBin].max() ?? 0
            let decibels = 10 * log10(max(peakPower, 0.000_000_000_001))
            let normalized = min(max((decibels + 86) / 58, 0), 1)
            let target = pow(normalized, 0.72)
            let smoothing: Float = target > smoothedBands[index] ? 0.82 : 0.22
            smoothedBands[index] += (target - smoothedBands[index]) * smoothing
            result.append(smoothedBands[index])
        }

        return result
    }

    private func normalizedLevel(energy: Float, frameLength: Int, gain: Float) -> Float {
        let rms = sqrt(energy / Float(frameLength))
        return min(max(rms * gain, 0), 1)
    }

    private func normalizedVisualLevel(rms: Float, peak: Float) -> Float {
        let rmsDB = 20 * log10(max(rms, 0.000_001))
        let peakDB = 20 * log10(max(peak, 0.000_001))
        let rmsComponent = normalizedDecibel(db: rmsDB, floor: -58, ceiling: -14)
        let peakComponent = normalizedDecibel(db: peakDB, floor: -52, ceiling: -8)
        return min(max((rmsComponent * 0.8) + (peakComponent * 0.2), 0), 1)
    }

    private func normalizedDecibel(db: Float, floor: Float, ceiling: Float) -> Float {
        min(max((db - floor) / (ceiling - floor), 0), 1)
    }

    private func decibels(for linear: Float) -> Float {
        20 * log10(max(linear, 0.000_001))
    }
}
