import AVFoundation
import Application
import CoreAudio
import Domain
import Foundation
import OSLog

struct AudioCaptureRoute: Equatable, Sendable {
    let inputDeviceID: AudioObjectID
    let outputDeviceID: AudioObjectID
    let inputSampleRate: Double
}

@MainActor
public final class AVAudioCaptureService: AudioCaptureService {
    // Keep a configured engine between recordings. Rebuilding AVAudioEngine on
    // every press makes Bluetooth devices tear down and recreate their private
    // input/output aggregate, which can take several seconds. The route
    // fingerprint below still forces a fresh graph after a real device or
    // sample-rate change.
    private var audioEngine: AVAudioEngine?
    private var preparedRoute: AudioCaptureRoute?
    private var isTapInstalled = false
    private let tapSink = TapSink()
    private let fileManager: FileManager
    private let pendingDirectoryURL: URL
    private let logger = Logger(subsystem: "com.dictator.app", category: "audio-capture")

    private var outputURL: URL?

    public convenience init(fileManager: FileManager = .default) {
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.init(
            fileManager: fileManager,
            pendingDirectoryURL: applicationSupportURL
            .appendingPathComponent("Dictator", isDirectory: true)
            .appendingPathComponent("PendingRecordings", isDirectory: true)
        )
    }

    init(fileManager: FileManager, pendingDirectoryURL: URL) {
        self.fileManager = fileManager
        self.pendingDirectoryURL = pendingDirectoryURL
    }

    public func makeMeterStream() -> AsyncStream<AudioMeterFrame> {
        tapSink.makeMeterStream()
    }

    public func suppressSystemFeedback(for duration: TimeInterval) {
        tapSink.suppressSystemFeedback(for: duration)
    }

    public func prepareForRecording() async {
        guard outputURL == nil, audioEngine?.isRunning != true else {
            return
        }

        let route = Self.currentRoute()
        if !Self.canReuseEngine(
            hasEngine: audioEngine != nil,
            preparedRoute: preparedRoute,
            currentRoute: route
        ) {
            replaceAudioEngine()
        }

        guard let engine = audioEngine else {
            return
        }
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            return
        }

        installTapIfNeeded(on: inputNode)
        engine.prepare()
        preparedRoute = route
        logger.info("Audio capture graph prepared without starting the microphone")
    }

    public func startRecording() async throws {
        guard outputURL == nil, audioEngine?.isRunning != true else {
            throw AppError.audioCaptureFailed("A recording session is already active.")
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let currentRoute = Self.currentRoute()
        var reusedEngine = Self.canReuseEngine(
            hasEngine: audioEngine != nil,
            preparedRoute: preparedRoute,
            currentRoute: currentRoute
        )
        if !reusedEngine {
            replaceAudioEngine()
        }

        var engine = audioEngine ?? AVAudioEngine()
        audioEngine = engine
        var inputNode = engine.inputNode
        var format = inputNode.outputFormat(forBus: 0)

        // A disconnected device can temporarily leave a cached node with an
        // invalid output format. Retry once with a fresh graph. Do not compare
        // the input and output bus formats here: AirPods legitimately change
        // those formats while leaving the reusable capture route intact.
        if reusedEngine, format.sampleRate <= 0 || format.channelCount == 0 {
            logger.info("Discarding cached audio engine with an invalid format")
            replaceAudioEngine()
            engine = audioEngine ?? AVAudioEngine()
            audioEngine = engine
            inputNode = engine.inputNode
            format = inputNode.outputFormat(forBus: 0)
            reusedEngine = false
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AppError.audioCaptureFailed("The selected microphone has no usable input format.")
        }
        try fileManager.createDirectory(
            at: pendingDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let url = pendingDirectoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let outputFile = try AVAudioFile(forWriting: url, settings: format.settings)
        outputURL = url
        tapSink.configure(outputFile: outputFile, sampleRate: format.sampleRate)

        installTapIfNeeded(on: inputNode)

        do {
            engine.prepare()
            try engine.start()
            preparedRoute = currentRoute ?? Self.currentRoute()
            let latencyMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
            )
            logger.info(
                "Audio capture ready in \(latencyMilliseconds, privacy: .public)ms; reusedEngine=\(reusedEngine, privacy: .public)"
            )
        } catch {
            if isTapInstalled {
                inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
            engine.stop()
            _ = tapSink.finish()
            outputURL = nil
            audioEngine = nil
            preparedRoute = nil
            try? fileManager.removeItem(at: url)
            throw AppError.audioCaptureFailed(error.localizedDescription)
        }
    }

    public func stopRecording() async throws -> CapturedAudio {
        guard let outputURL else {
            throw AppError.audioCaptureFailed("No active recording session.")
        }

        guard let audioEngine else {
            throw AppError.audioCaptureFailed("The recording audio engine is unavailable.")
        }
        if audioEngine.isRunning {
            // Unlike stop(), pause() turns off the microphone hardware while
            // retaining the resources allocated by prepare(). This is the
            // fast, privacy-safe path for the next hotkey press.
            audioEngine.pause()
        }

        // Pausing prevents new callbacks; `finish` then waits on the same lock
        // used for every file write. The tap remains installed on the inactive
        // graph so the next recording requires no graph mutation.
        let result = tapSink.finish()
        self.outputURL = nil

        if let writeError = result.writeError {
            throw AppError.audioCaptureFailed("The recording could not be written: \(writeError.localizedDescription)")
        }

        do {
            let file = try AVAudioFile(forReading: outputURL)
            let actualFrames = file.length
            guard actualFrames > 0 else {
                try? fileManager.removeItem(at: outputURL)
                throw AppError.audioCaptureFailed("The recording contains no audio frames.")
            }

            let allowedFrameDifference = max(1, AVAudioFramePosition(result.writtenFrames / 1_000))
            guard abs(actualFrames - AVAudioFramePosition(result.writtenFrames)) <= allowedFrameDifference else {
                throw AppError.audioCaptureFailed(
                    "The recording was not finalized completely (expected \(result.writtenFrames) frames, found \(actualFrames))."
                )
            }

            // Push the finalized header and samples to disk before the file is
            // handed to the archive/transcription pipeline.
            try FileHandle(forUpdating: outputURL).synchronize()
            let duration = Double(actualFrames) / file.processingFormat.sampleRate
            return CapturedAudio(fileURL: outputURL, duration: duration)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.audioCaptureFailed("The finalized recording could not be verified: \(error.localizedDescription)")
        }
    }

    public func cancelRecording() async {
        if let audioEngine, audioEngine.isRunning {
            audioEngine.pause()
        }
        _ = tapSink.finish()
        if let outputURL {
            try? fileManager.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    static func canReuseEngine(
        hasEngine: Bool,
        preparedRoute: AudioCaptureRoute?,
        currentRoute: AudioCaptureRoute?
    ) -> Bool {
        guard hasEngine, let preparedRoute, let currentRoute else {
            return false
        }
        return preparedRoute == currentRoute
    }

    private func replaceAudioEngine() {
        audioEngine?.stop()
        audioEngine = AVAudioEngine()
        preparedRoute = nil
        isTapInstalled = false
    }

    private func installTapIfNeeded(on inputNode: AVAudioInputNode) {
        guard !isTapInstalled else {
            return
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: 2048,
            // nil asks AVFoundation to follow the input node's native output
            // format and avoids a route-change race with Bluetooth devices.
            format: nil,
            block: tapSink.makeTapHandler()
        )
        isTapInstalled = true
    }

    private static func currentRoute() -> AudioCaptureRoute? {
        guard
            let inputDeviceID = defaultDevice(
                selector: kAudioHardwarePropertyDefaultInputDevice
            ),
            let outputDeviceID = defaultDevice(
                selector: kAudioHardwarePropertyDefaultOutputDevice
            )
        else {
            return nil
        }
        return AudioCaptureRoute(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID,
            inputSampleRate: nominalSampleRate(for: inputDeviceID)
        )
    }

    private static func defaultDevice(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = kAudioObjectUnknown
        var byteCount = UInt32(MemoryLayout<AudioObjectID>.size)
        let systemObject = AudioObjectID(bitPattern: kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &byteCount,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private static func nominalSampleRate(for deviceID: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var byteCount = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &byteCount,
            &sampleRate
        ) == noErr else {
            return 0
        }
        return sampleRate
    }

    public func recoverPendingRecordings() async -> [CapturedAudio] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: pendingDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files.compactMap { url in
            guard url.pathExtension.lowercased() == "wav",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let file = try? AVAudioFile(forReading: url) else {
                return nil
            }

            guard file.length > 0 else {
                // A finalized header without a single audio frame cannot be
                // recovered and should not accumulate after failed starts.
                try? fileManager.removeItem(at: url)
                return nil
            }
            guard file.processingFormat.sampleRate > 0 else {
                return nil
            }
            return CapturedAudio(
                fileURL: url,
                duration: Double(file.length) / file.processingFormat.sampleRate
            )
        }
    }
}

private final class TapSink: @unchecked Sendable {
    struct FinishResult {
        let writtenFrames: AVAudioFramePosition
        let sampleRate: Double
        let writeError: Error?
    }

    private let lock = NSLock()
    private let meterBroadcast = AsyncBroadcast<AudioMeterFrame>()
    private let meterAnalyzer = AudioMeterAnalyzer()

    private var outputFile: AVAudioFile?
    private var writtenFrames: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var writeError: Error?
    private var suppressInputUntilUptime: TimeInterval = 0

    func makeMeterStream() -> AsyncStream<AudioMeterFrame> {
        // Meter consumers only need the freshest sample. Dropping stale frames
        // keeps long sessions from building an async backlog.
        meterBroadcast.stream(bufferingPolicy: .bufferingNewest(1))
    }

    func configure(outputFile: AVAudioFile, sampleRate: Double) {
        lock.lock()
        self.outputFile = outputFile
        writtenFrames = 0
        self.sampleRate = sampleRate
        writeError = nil
        suppressInputUntilUptime = 0
        meterAnalyzer.reset()
        lock.unlock()
    }

    func handle(buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let outputFile else {
            lock.unlock()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now < suppressInputUntilUptime {
            lock.unlock()
            meterBroadcast.yield(.silent)
            return
        }
        if suppressInputUntilUptime > 0 {
            suppressInputUntilUptime = 0
            // The app's cue must not calibrate the speech/noise floor either.
            meterAnalyzer.reset()
        }
        do {
            try outputFile.write(from: buffer)
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            writeError = writeError ?? error
        }
        let meterFrame = meterAnalyzer.analyze(buffer: buffer)
        lock.unlock()
        meterBroadcast.yield(meterFrame)
    }

    func suppressSystemFeedback(for duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else {
            return
        }
        lock.lock()
        suppressInputUntilUptime = max(
            suppressInputUntilUptime,
            ProcessInfo.processInfo.systemUptime + duration
        )
        lock.unlock()
    }

    func makeTapHandler() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
    }

    func finish() -> FinishResult {
        lock.lock()
        let result = FinishResult(
            writtenFrames: writtenFrames,
            sampleRate: sampleRate,
            writeError: writeError
        )
        outputFile = nil
        suppressInputUntilUptime = 0
        meterAnalyzer.reset()
        lock.unlock()
        return result
    }
}

private final class AudioMeterAnalyzer: @unchecked Sendable {
    private var slowLowPass: Float = 0
    private var fastLowPass: Float = 0
    private var speechDetector = RealtimeSpeechActivityDetector()

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
        let visualBands = [lowDB, midDB, highDB].map { decibels in
            pow(normalizedDecibel(db: decibels, floor: -72, ceiling: -18), 0.82)
        }
        return AudioMeterFrame(
            overallLevel: overallLevel,
            visualLevel: visualLevel,
            speechConfidence: speechDecision.confidence,
            isSpeechDetected: speechDecision.isSpeechDetected,
            frameDuration: frameDuration,
            // Three IIR-derived ranges keep the stationary meter expressive
            // without bringing back the significantly heavier FFT path.
            bands: visualBands
        )
    }

    func reset() {
        slowLowPass = 0
        fastLowPass = 0
        speechDetector.reset()
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
