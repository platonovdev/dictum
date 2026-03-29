import AVFoundation
import Domain
import Foundation

public enum AudioCompression {
    public static func compressToM4A(
        sourceURL: URL,
        outputURL: URL,
        maximumSampleRate: Double = 16_000,
        bitRate: Int = 32_000
    ) throws {
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = sourceFile.processingFormat
        let targetSampleRate = min(sourceFormat.sampleRate, maximumSampleRate)
        let targetChannels: AVAudioChannelCount = 1

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVEncoderBitRateKey: bitRate
        ]

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFile.processingFormat) else {
            throw AppError.audioArchiveFailed("Could not create an audio converter.")
        }

        let inputBufferCapacity: AVAudioFrameCount = 8192
        let outputCapacityRatio = max(outputFile.processingFormat.sampleRate / sourceFormat.sampleRate, 1)
        let outputBufferCapacity = AVAudioFrameCount(Double(inputBufferCapacity) * outputCapacityRatio) + 1024
        let state = ConversionState()

        while true {
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFile.processingFormat,
                frameCapacity: outputBufferCapacity
            )!

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if state.reachedEndOfStream {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: inputBufferCapacity
                )!

                do {
                    try sourceFile.read(into: inputBuffer)
                } catch {
                    state.readError = error
                    state.reachedEndOfStream = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                if inputBuffer.frameLength == 0 {
                    state.reachedEndOfStream = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw conversionError
            }

            if let readError = state.readError {
                throw readError
            }

            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }

            if status == .endOfStream {
                break
            }
        }
    }
}

private final class ConversionState: @unchecked Sendable {
    var reachedEndOfStream = false
    var readError: Error?
}
