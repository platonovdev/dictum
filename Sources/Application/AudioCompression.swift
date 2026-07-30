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
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw AppError.audioArchiveFailed("Could not open the source recording: \(error.localizedDescription)")
        }
        let sourceFormat = sourceFile.processingFormat
        let targetSampleRate = min(sourceFormat.sampleRate, maximumSampleRate)
        let targetChannels: AVAudioChannelCount = 1

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVEncoderBitRateKey: bitRate
        ]

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AppError.audioArchiveFailed("Could not create the retained recording: \(error.localizedDescription)")
        }

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
            let status = converter.convert(to: outputBuffer, error: &conversionError) { requestedPacketCount, outStatus in
                if state.reachedEndOfStream || sourceFile.framePosition >= sourceFile.length {
                    state.reachedEndOfStream = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                let remainingFrames = sourceFile.length - sourceFile.framePosition
                let requestedFrames = AVAudioFrameCount(max(requestedPacketCount, 1))
                let frameCapacity = min(
                    inputBufferCapacity,
                    requestedFrames,
                    AVAudioFrameCount(clamping: remainingFrames)
                )
                let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: frameCapacity
                )!

                do {
                    try sourceFile.read(into: inputBuffer, frameCount: frameCapacity)
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
                throw AppError.audioArchiveFailed("Could not convert the retained recording: \(conversionError.localizedDescription)")
            }

            if let readError = state.readError {
                throw AppError.audioArchiveFailed("Could not read the source recording: \(readError.localizedDescription)")
            }

            if outputBuffer.frameLength > 0 {
                do {
                    try outputFile.write(from: outputBuffer)
                } catch {
                    throw AppError.audioArchiveFailed("Could not write the retained recording: \(error.localizedDescription)")
                }
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
