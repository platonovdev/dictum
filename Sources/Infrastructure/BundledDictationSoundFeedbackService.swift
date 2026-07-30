import Application
import AVFoundation
import Domain
import Foundation

/// Preloads short, bundled UI cues and releases each decoder after playback.
/// No audio engine or background work remains active while Dictator is idle.
@MainActor
public final class BundledDictationSoundFeedbackService: DictationSoundFeedbackService {
    private struct CuePair {
        let recordingStarted: Data
        let processingStarted: Data
    }

    private let cues: [DictationSoundTheme: CuePair]
    private var recordingStartedPlayer: AVAudioPlayer?
    private var processingStartedPlayer: AVAudioPlayer?
    private var previewTask: Task<Void, Never>?

    var availableThemeCount: Int { cues.count }

    public init() {
        cues = Dictionary(
            uniqueKeysWithValues: DictationSoundTheme.allCases.compactMap { theme in
                guard
                    let recordingStarted = Self.loadCue(theme: theme, suffix: "start"),
                    let processingStarted = Self.loadCue(theme: theme, suffix: "stop")
                else {
                    return nil
                }
                return (theme, CuePair(
                    recordingStarted: recordingStarted,
                    processingStarted: processingStarted
                ))
            }
        )
    }

    public func playRecordingStarted(theme: DictationSoundTheme, volume: Double) {
        previewTask?.cancel()
        recordingStartedPlayer = play(cues[theme]?.recordingStarted, volume: volume)
    }

    public func playProcessingStarted(theme: DictationSoundTheme, volume: Double) {
        previewTask?.cancel()
        processingStartedPlayer = play(cues[theme]?.processingStarted, volume: volume)
    }

    public func playPreview(theme: DictationSoundTheme, volume: Double) {
        previewTask?.cancel()
        recordingStartedPlayer = play(cues[theme]?.recordingStarted, volume: volume)

        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(480))
            guard !Task.isCancelled, let self else {
                return
            }
            processingStartedPlayer = play(cues[theme]?.processingStarted, volume: volume)
        }
    }

    private func play(_ data: Data?, volume: Double) -> AVAudioPlayer? {
        let clampedVolume = volume.isFinite ? min(max(volume, 0), 1) : 0
        guard clampedVolume > 0.001, let data else {
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

    private static func loadCue(theme: DictationSoundTheme, suffix: String) -> Data? {
        guard let url = Bundle.module.url(
            forResource: "\(theme.rawValue)-\(suffix)",
            withExtension: "m4a",
            subdirectory: "FeedbackSounds"
        ) else {
            return nil
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}
