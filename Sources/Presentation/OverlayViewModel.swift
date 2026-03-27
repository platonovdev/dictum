import Application
import Domain
import Foundation

public enum OverlayVisualState: Equatable {
    case recording
    case processing
    case preparing
    case error
}

@MainActor
public final class OverlayViewModel: ObservableObject {
    private enum WaveformConstants {
        /// Number of visible bars in the scrolling timeline.
        static let barCount = 24
        /// How often we push a new bar (controls scroll speed).
        static let pushInterval: Duration = .milliseconds(60)
    }

    @Published public private(set) var isVisible = false
    @Published public private(set) var visualState: OverlayVisualState = .recording
    @Published public private(set) var isLockedMode = false
    @Published public private(set) var statusText: String?
    /// Scrolling timeline buffer — newest bar at the end (right side).
    @Published public private(set) var waveformLevels = Array(
        repeating: Float(0.022),
        count: 24
    )
    @Published public private(set) var timerText = "0:00"

    private var tasks: [Task<Void, Never>] = []
    private var elapsedTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?

    private var latestVisualLevel: Float = 0
    private var waveformLeveler = AdaptiveWaveformLeveler()

    public init(coordinator: DictationSessionCoordinating) {
        tasks.append(Task { [weak self] in
            for await state in coordinator.makeStateStream() {
                guard let self else {
                    return
                }
                self.handle(state: state)
            }
        })

        tasks.append(Task { [weak self] in
            for await meterFrame in coordinator.makeMeterStream() {
                guard let self else {
                    return
                }
                if meterFrame.isSpeechDetected {
                    self.latestVisualLevel = meterFrame.visualLevel
                } else {
                    let residualNoise = meterFrame.visualLevel * (0.08 + (meterFrame.speechConfidence * 0.20))
                    self.latestVisualLevel = residualNoise
                }
            }
        })
    }

    deinit {
        tasks.forEach { $0.cancel() }
        elapsedTask?.cancel()
        waveformTask?.cancel()
    }

    private func handle(state: DictationSessionState) {
        switch state {
        case .idle:
            isVisible = false
            visualState = .recording
            isLockedMode = false
            statusText = nil
            timerText = "0:00"
            stopElapsedTimer()
            stopWaveformTicker()
            resetWaveform()
        case .preparingModel(let status):
            isVisible = true
            visualState = .preparing
            isLockedMode = false
            statusText = status.title
            timerText = "0:00"
            stopElapsedTimer()
            stopWaveformTicker()
            resetWaveform()
        case .recording(let startedAt, let isHandsFree):
            isVisible = true
            visualState = .recording
            isLockedMode = isHandsFree
            statusText = nil
            resetWaveform()
            startElapsedTimer(from: startedAt)
            startWaveformTicker()
        case .transcribing:
            isVisible = true
            visualState = .processing
            isLockedMode = false
            statusText = "Transcribing..."
            stopElapsedTimer()
            stopWaveformTicker()
        case .inserting:
            isVisible = true
            visualState = .processing
            isLockedMode = false
            statusText = "Inserting..."
            stopElapsedTimer()
            stopWaveformTicker()
        case .error(let error):
            isVisible = true
            visualState = .error
            isLockedMode = false
            statusText = error.userFacingDescription
            stopElapsedTimer()
            stopWaveformTicker()
        }
    }

    private func startWaveformTicker() {
        guard waveformTask == nil else {
            return
        }

        waveformTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: WaveformConstants.pushInterval)
                await MainActor.run {
                    guard let self, self.visualState == .recording else {
                        return
                    }
                    self.pushWaveformBar()
                }
            }
        }
    }

    private func stopWaveformTicker() {
        waveformTask?.cancel()
        waveformTask = nil
    }

    /// Compute a single bar height from the current volume, push it onto the
    /// right end of the buffer, and drop the oldest bar on the left — creating
    /// a scrolling timeline effect.
    private func pushWaveformBar() {
        let barHeight = waveformLeveler.push(inputLevel: latestVisualLevel)

        // Shift buffer left, append new bar on the right
        waveformLevels.append(barHeight)
        if waveformLevels.count > WaveformConstants.barCount {
            waveformLevels.removeFirst(waveformLevels.count - WaveformConstants.barCount)
        }
    }

    private func resetWaveform() {
        latestVisualLevel = 0
        waveformLeveler.reset()
        let idle = AdaptiveWaveformLeveler.idleLevel
        waveformLevels = Array(repeating: idle, count: WaveformConstants.barCount)
    }

    private func startElapsedTimer(from date: Date) {
        updateElapsedLabel(from: date)
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run {
                    self?.updateElapsedLabel(from: date)
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    private func updateElapsedLabel(from date: Date) {
        let elapsed = max(Int(Date().timeIntervalSince(date)), 0)
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        timerText = String(format: "%d:%02d", minutes, seconds)
    }

}
