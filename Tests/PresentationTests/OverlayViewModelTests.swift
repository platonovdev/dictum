#if canImport(Testing)
@testable import Presentation
import Application
import Domain
import Foundation
import Testing

@Test
@MainActor
func overlayViewModelShowsStatusTextOutsideRecording() async {
    let coordinator = MockCoordinator()
    let viewModel = OverlayViewModel(coordinator: coordinator)

    coordinator.sendState(.preparingModel(
        ModelPreparationStatus(
            title: "Checking local model",
            detail: "Looking for a cached model.",
            progress: 0.1,
            startedAt: Date()
        )
    ))
    await Task.yield()

    #expect(viewModel.isVisible)
    #expect(viewModel.visualState == .preparing)
    #expect(viewModel.statusText == "Checking local model")
    #expect(viewModel.timerText == "0:00")

    coordinator.sendState(.transcribing(partialText: nil))
    await Task.yield()

    #expect(viewModel.visualState == .processing)
    #expect(viewModel.statusText == "Transcribing...")
    #expect(viewModel.timerText == "0:00")

    coordinator.sendState(.error(.audioCaptureFailed("boom")))
    await Task.yield()

    #expect(viewModel.visualState == .error)
    #expect(viewModel.statusText == "Audio capture failed: boom")

    coordinator.sendState(.recording(startedAt: Date().addingTimeInterval(-2)))
    await Task.yield()

    #expect(viewModel.visualState == .recording)
    #expect(viewModel.statusText == nil)
    #expect(viewModel.timerText != "0:00")
}

@Test
@MainActor
func overlayViewModelHidesOnIdle() async {
    let coordinator = MockCoordinator()
    let viewModel = OverlayViewModel(coordinator: coordinator)

    coordinator.sendState(.recording(startedAt: Date()))
    await Task.yield()
    coordinator.sendState(.idle())
    await Task.yield()

    #expect(!viewModel.isVisible)
    #expect(viewModel.statusText == nil)
    #expect(viewModel.timerText == "0:00")
}

@Test
func liveSpeechWaveformMovesWithTheIncomingBandEnergy() {
    var waveform = LiveSpeechWaveform()
    let quiet = AudioMeterFrame(
        overallLevel: 0.01,
        visualLevel: 0.01,
        speechConfidence: 0,
        isSpeechDetected: false,
        frameDuration: 0.04,
        bands: Array(repeating: 0.01, count: 9)
    )
    let speech = AudioMeterFrame(
        overallLevel: 0.48,
        visualLevel: 0.62,
        speechConfidence: 0.95,
        isSpeechDetected: true,
        frameDuration: 0.04,
        bands: [0.18, 0.36, 0.68, 0.42, 0.78, 0.51, 0.29, 0.63, 0.40]
    )

    let quietBars = waveform.update(with: quiet)
    let speechBars = waveform.update(with: speech)

    #expect(quietBars.allSatisfy { $0 <= LiveSpeechWaveform.idleLevel + 0.01 })
    #expect(speechBars.max()! > 0.55)
    #expect(Set(speechBars.map { Int($0 * 100) }).count > 5)
}

private final class MockCoordinator: DictationSessionCoordinating {
    private var stateContinuation: AsyncStream<DictationSessionState>.Continuation?
    private var meterContinuation: AsyncStream<AudioMeterFrame>.Continuation?

    func makeStateStream() -> AsyncStream<DictationSessionState> {
        AsyncStream { continuation in
            stateContinuation = continuation
            continuation.yield(.idle())
        }
    }

    func makePartialTranscriptStream() -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func makeMeterStream() -> AsyncStream<AudioMeterFrame> {
        AsyncStream { continuation in
            meterContinuation = continuation
            continuation.yield(.silent)
        }
    }

    func makeHistoryStream() -> AsyncStream<[DictationHistoryEntry]> {
        AsyncStream { continuation in
            continuation.yield([])
        }
    }

    func loadHistoryEntries() async -> [DictationHistoryEntry] { [] }
    func handleHotkeyEvent(_ event: HotkeyEvent) async {}
    func prepare() async {}
    func reloadSettings() async {}
    func startDictation() async {}
    func stopDictation() async {}
    func resetSession() async {}
    func retryHistoryEntry(id: UUID) async {}
    func deleteHistoryEntry(id: UUID) async {}

    func sendState(_ state: DictationSessionState) {
        stateContinuation?.yield(state)
    }
}
#endif
