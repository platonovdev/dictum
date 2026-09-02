import AVFoundation
import Application
import AudioToolbox
import CoreAudio
import Domain
import Foundation
import OSLog

private struct AUHALInputRoute: Equatable {
    let deviceID: AudioDeviceID
    let sampleRate: Double
}

private final class AUHALCaptureContext: @unchecked Sendable {
    let audioUnit: AudioUnit
    let buffer: AVAudioPCMBuffer
    let sink: TapSink

    init(audioUnit: AudioUnit, format: AVAudioFormat, frameCapacity: AVAudioFrameCount, sink: TapSink) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw AppError.audioCaptureFailed("Could not allocate the microphone buffer.")
        }
        self.audioUnit = audioUnit
        self.buffer = buffer
        self.sink = sink
    }

    func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard frameCount <= buffer.frameCapacity else {
            return kAudioUnitErr_TooManyFramesToProcess
        }
        buffer.frameLength = frameCount
        let status = AudioUnitRender(
            audioUnit,
            flags,
            timestamp,
            1,
            frameCount,
            buffer.mutableAudioBufferList
        )
        if status == noErr {
            sink.handle(buffer: buffer)
        }
        return status
    }
}

private let auhalInputCallback: AURenderCallback = { reference, flags, timestamp, _, frameCount, _ in
    let context = Unmanaged<AUHALCaptureContext>
        .fromOpaque(reference)
        .takeUnretainedValue()
    return context.render(flags: flags, timestamp: timestamp, frameCount: frameCount)
}

/// Input-only Core Audio capture. Unlike AVAudioEngine on macOS, this does not
/// create a private aggregate from the default microphone and default output,
/// so a sleeping HDMI display cannot block dictation startup.
@MainActor
public final class AUHALAudioCaptureService: AudioCaptureService {
    private enum Constants {
        static let preparedResourceIdleDuration: Duration = .seconds(30 * 60)
        static let minimumFrameCapacity: UInt32 = 4_096
        static let startRetryDelay: Duration = .milliseconds(80)
    }

    private let tapSink = TapSink()
    private let fileManager: FileManager
    private let pendingDirectoryURL: URL
    private let logger = Logger(subsystem: "com.dictator.app", category: "audio-capture")

    private var audioUnit: AudioUnit?
    private var captureContext: AUHALCaptureContext?
    private var preparedRoute: AUHALInputRoute?
    private var outputURL: URL?
    private var isRunning = false
    private var preparedResourceReleaseTask: Task<Void, Never>?

    public convenience init(fileManager: FileManager = .default) {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
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
        cancelScheduledPreparedResourceRelease()
        guard outputURL == nil, !isRunning else {
            return
        }
        do {
            try ensurePreparedForCurrentInput()
            schedulePreparedResourceRelease()
            logger.info("Input-only microphone graph prepared")
        } catch {
            releasePreparedResources()
            logger.error("Could not prewarm input-only microphone graph: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func startRecording() async throws {
        cancelScheduledPreparedResourceRelease()
        guard outputURL == nil, !isRunning else {
            throw AppError.audioCaptureFailed("A recording session is already active.")
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            try startAttempt()
        } catch {
            logger.error("Warm input-only start failed; rebuilding once: \(error.localizedDescription, privacy: .public)")
            cleanupFailedStart()
            try? await Task.sleep(for: Constants.startRetryDelay)
            do {
                try startAttempt()
            } catch {
                cleanupFailedStart()
                throw error
            }
        }

        let latencyMilliseconds = Int(
            ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
        )
        logger.notice("Audio capture ready in \(latencyMilliseconds, privacy: .public)ms; inputOnly=true")
    }

    public func stopRecording() async throws -> CapturedAudio {
        guard let outputURL, let audioUnit, isRunning else {
            throw AppError.audioCaptureFailed("No active recording session.")
        }

        let stopStatus = AudioOutputUnitStop(audioUnit)
        isRunning = false
        schedulePreparedResourceRelease()
        let result = tapSink.finish()
        self.outputURL = nil

        guard stopStatus == noErr else {
            throw captureError(step: "stop", status: stopStatus)
        }
        if let writeError = result.writeError {
            throw AppError.audioCaptureFailed(
                "The recording could not be written: \(writeError.localizedDescription)"
            )
        }

        do {
            let file = try AVAudioFile(forReading: outputURL)
            let actualFrames = file.length
            guard actualFrames > 0 else {
                try? fileManager.removeItem(at: outputURL)
                throw AppError.audioCaptureFailed("The recording contains no audio frames.")
            }
            let allowedFrameDifference = max(
                1,
                AVAudioFramePosition(result.writtenFrames / 1_000)
            )
            guard abs(actualFrames - AVAudioFramePosition(result.writtenFrames)) <= allowedFrameDifference else {
                throw AppError.audioCaptureFailed(
                    "The recording was not finalized completely (expected \(result.writtenFrames) frames, found \(actualFrames))."
                )
            }
            try FileHandle(forUpdating: outputURL).synchronize()
            return CapturedAudio(
                fileURL: outputURL,
                duration: Double(actualFrames) / file.processingFormat.sampleRate
            )
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.audioCaptureFailed(
                "The finalized recording could not be verified: \(error.localizedDescription)"
            )
        }
    }

    public func cancelRecording() async {
        if let audioUnit, isRunning {
            _ = AudioOutputUnitStop(audioUnit)
        }
        isRunning = false
        schedulePreparedResourceRelease()
        _ = tapSink.finish()
        if let outputURL {
            try? fileManager.removeItem(at: outputURL)
        }
        outputURL = nil
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

    private func startAttempt() throws {
        try ensurePreparedForCurrentInput()
        guard let audioUnit, let captureContext else {
            throw AppError.audioCaptureFailed("The microphone graph is unavailable.")
        }

        try fileManager.createDirectory(
            at: pendingDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let url = pendingDirectoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let format = captureContext.buffer.format
        let outputFile = try AVAudioFile(forWriting: url, settings: format.settings)
        outputURL = url
        tapSink.configure(outputFile: outputFile, sampleRate: format.sampleRate)

        let status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            _ = tapSink.finish()
            outputURL = nil
            try? fileManager.removeItem(at: url)
            throw captureError(step: "start", status: status)
        }
        isRunning = true
    }

    private func ensurePreparedForCurrentInput() throws {
        let route = try Self.currentInputRoute()
        if audioUnit != nil, captureContext != nil, preparedRoute == route {
            return
        }
        releasePreparedResources()
        try configureAudioUnit(for: route)
    }

    private func configureAudioUnit(for route: AUHALInputRoute) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AppError.audioCaptureFailed("The macOS microphone component is unavailable.")
        }

        var instance: AudioUnit?
        try requireNoError(
            AudioComponentInstanceNew(component, &instance),
            step: "create input unit"
        )
        guard let instance else {
            throw AppError.audioCaptureFailed("The macOS microphone unit could not be created.")
        }

        do {
            var enabled: UInt32 = 1
            try requireNoError(
                AudioUnitSetProperty(
                    instance,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Input,
                    1,
                    &enabled,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                step: "enable microphone input"
            )

            var disabled: UInt32 = 0
            try requireNoError(
                AudioUnitSetProperty(
                    instance,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Output,
                    0,
                    &disabled,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                step: "disable audio output"
            )

            var deviceID = route.deviceID
            try requireNoError(
                AudioUnitSetProperty(
                    instance,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                ),
                step: "select microphone"
            )

            var hardwareFormat = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try requireNoError(
                AudioUnitGetProperty(
                    instance,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    1,
                    &hardwareFormat,
                    &formatSize
                ),
                step: "read microphone format"
            )
            guard hardwareFormat.mSampleRate > 0,
                  hardwareFormat.mChannelsPerFrame > 0,
                  let clientFormat = AVAudioFormat(
                    standardFormatWithSampleRate: hardwareFormat.mSampleRate,
                    channels: hardwareFormat.mChannelsPerFrame
                  ) else {
                throw AppError.audioCaptureFailed("The selected microphone has no usable input format.")
            }

            var clientDescription = clientFormat.streamDescription.pointee
            try requireNoError(
                AudioUnitSetProperty(
                    instance,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output,
                    1,
                    &clientDescription,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ),
                step: "set capture format"
            )

            let frameCapacity = max(
                Self.bufferFrameSize(for: route.deviceID),
                Constants.minimumFrameCapacity
            )
            var maximumFrames = frameCapacity
            try requireNoError(
                AudioUnitSetProperty(
                    instance,
                    kAudioUnitProperty_MaximumFramesPerSlice,
                    kAudioUnitScope_Global,
                    0,
                    &maximumFrames,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                step: "set capture buffer capacity"
            )

            let context = try AUHALCaptureContext(
                audioUnit: instance,
                format: clientFormat,
                frameCapacity: frameCapacity,
                sink: tapSink
            )
            var callback = AURenderCallbackStruct(
                inputProc: auhalInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
            )
            try requireNoError(
                AudioUnitSetProperty(
                    instance,
                    kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global,
                    0,
                    &callback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                step: "install microphone callback"
            )
            try requireNoError(AudioUnitInitialize(instance), step: "initialize microphone")

            audioUnit = instance
            captureContext = context
            preparedRoute = route
        } catch {
            AudioUnitUninitialize(instance)
            AudioComponentInstanceDispose(instance)
            throw error
        }
    }

    private func cleanupFailedStart() {
        if let outputURL {
            try? fileManager.removeItem(at: outputURL)
        }
        outputURL = nil
        isRunning = false
        _ = tapSink.finish()
        releasePreparedResources()
    }

    private func schedulePreparedResourceRelease() {
        cancelScheduledPreparedResourceRelease()
        preparedResourceReleaseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Constants.preparedResourceIdleDuration)
            } catch {
                return
            }
            guard let self, !self.isRunning, self.outputURL == nil else {
                return
            }
            self.releasePreparedResources()
            self.preparedResourceReleaseTask = nil
            self.logger.notice("Released idle input-only microphone graph after 30 minutes")
        }
    }

    private func cancelScheduledPreparedResourceRelease() {
        preparedResourceReleaseTask?.cancel()
        preparedResourceReleaseTask = nil
    }

    private func releasePreparedResources() {
        if let audioUnit {
            if isRunning {
                _ = AudioOutputUnitStop(audioUnit)
            }
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
        isRunning = false
        audioUnit = nil
        captureContext = nil
        preparedRoute = nil
    }

    private func requireNoError(_ status: OSStatus, step: String) throws {
        guard status == noErr else {
            throw captureError(step: step, status: status)
        }
    }

    private func captureError(step: String, status: OSStatus) -> AppError {
        .audioCaptureFailed("Microphone \(step) failed (Core Audio \(status)).")
    }

    private static func currentInputRoute() throws -> AUHALInputRoute {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let systemObject = AudioObjectID(bitPattern: kAudioObjectSystemObject)
        let status = AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw AppError.audioCaptureFailed("No default microphone is available.")
        }
        return AUHALInputRoute(
            deviceID: deviceID,
            sampleRate: nominalSampleRate(for: deviceID)
        )
    }

    private static func nominalSampleRate(for deviceID: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &sampleRate
        ) == noErr else {
            return 0
        }
        return sampleRate
    }

    private static func bufferFrameSize(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var frameSize: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &frameSize
        ) == noErr else {
            return Constants.minimumFrameCapacity
        }
        return frameSize
    }
}
