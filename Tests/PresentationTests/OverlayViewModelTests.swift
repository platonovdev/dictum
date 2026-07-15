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
    await waitUntil { coordinator.isStateStreamReady }

    coordinator.sendState(.transcribing(partialText: nil))
    await waitUntil { viewModel.visualState == .processing }

    #expect(viewModel.visualState == .processing)
    #expect(viewModel.statusText == nil)
    #expect(viewModel.timerText == "0:00")

    coordinator.sendState(.error(.audioCaptureFailed("boom")))
    await waitUntil { viewModel.visualState == .error }

    #expect(viewModel.visualState == .error)
    #expect(viewModel.statusText == "Audio capture failed: boom")

    coordinator.sendState(.recording(startedAt: Date().addingTimeInterval(-2)))
    await waitUntil { viewModel.visualState == .recording && viewModel.statusText == nil }

    #expect(viewModel.visualState == .recording)
    #expect(viewModel.statusText == nil)
    #expect(viewModel.timerText != "0:00")
}

@Test
@MainActor
func overlayViewModelHidesOnIdle() async {
    let coordinator = MockCoordinator()
    let viewModel = OverlayViewModel(coordinator: coordinator)
    await waitUntil { coordinator.isStateStreamReady }

    coordinator.sendState(.recording(startedAt: Date()))
    await waitUntil { viewModel.isVisible }
    coordinator.sendState(.idle())
    await waitUntil { !viewModel.isVisible }

    #expect(!viewModel.isVisible)
    #expect(viewModel.statusText == nil)
    #expect(viewModel.timerText == "0:00")
}

@Test
func liveSpeechWaveformMovesStationaryBarsWithCurrentVoiceEnergy() {
    var waveform = LiveSpeechWaveform()
    let quiet = AudioMeterFrame(
        overallLevel: 0.01,
        visualLevel: 0.01,
        speechConfidence: 0,
        isSpeechDetected: false,
        frameDuration: 0.04,
        bands: Array(repeating: 0.01, count: 9)
    )
    let quietBars = waveform.update(with: quiet)
    var speechBars = quietBars
    for _ in 0..<10 {
        speechBars = waveform.update(with: AudioMeterFrame(
            overallLevel: 0.58,
            visualLevel: 0.74,
            speechConfidence: 0.95,
            isSpeechDetected: true,
            frameDuration: 0.04,
            bands: [0.28, 0.86, 0.42]
        ))
    }

    #expect(quietBars.allSatisfy { $0 <= LiveSpeechWaveform.idleLevel + 0.01 })
    #expect(speechBars.max()! > 0.55)
    #expect(Set(speechBars.map { Int($0 * 100) }).count > 7)

    let softerBars = waveform.update(with: AudioMeterFrame(
        overallLevel: 0.22,
        visualLevel: 0.31,
        speechConfidence: 0.15,
        isSpeechDetected: false,
        frameDuration: 0.04,
        bands: [0.52, 0.31, 0.18]
    ))
    let changedInPlace = zip(speechBars, softerBars).filter { abs($0 - $1) > 0.001 }.count
    #expect(changedInPlace == LiveSpeechWaveform.barCount)

    var settledBars = softerBars
    for _ in 0..<35 {
        settledBars = waveform.update(with: quiet)
    }
    #expect(settledBars.allSatisfy { $0 <= LiveSpeechWaveform.idleLevel + 0.01 })
}

private final class MockCoordinator: DictationSessionCoordinating {
    private var stateContinuation: AsyncStream<DictationSessionState>.Continuation?
    private var meterContinuation: AsyncStream<AudioMeterFrame>.Continuation?

    var isStateStreamReady: Bool {
        stateContinuation != nil
    }

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

@MainActor
private func waitUntil(_ predicate: @escaping () -> Bool) async {
    for _ in 0..<100 {
        if predicate() {
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}
#endif
