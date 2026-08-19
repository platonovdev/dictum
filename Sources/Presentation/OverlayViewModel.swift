import Application
import Domain
import Foundation

public enum OverlayVisualState: Equatable {
    case recording
    case processing
    case error
}

@MainActor
public final class OverlayViewModel: ObservableObject {
    private enum WaveformConstants {
        static let pushInterval: Duration = .milliseconds(40)
    }

    @Published public private(set) var isVisible = false
    @Published public private(set) var visualState: OverlayVisualState = .recording
    @Published public private(set) var isLockedMode = false
    @Published public private(set) var statusText: String?
    /// Scrolling timeline buffer — newest bar at the end (right side).
    @Published public private(set) var waveformLevels = Array(
        repeating: LiveSpeechWaveform.idleLevel,
        count: LiveSpeechWaveform.barCount
    )
    @Published public private(set) var timerText = "0:00"

    private var tasks: [Task<Void, Never>] = []
    private var elapsedTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?

    private var latestMeterFrame = AudioMeterFrame.silent
    private var waveform = LiveSpeechWaveform()

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
                self.latestMeterFrame = meterFrame
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
        case .recording(let startedAt, let isHandsFree):
            let isContinuingRecording = isVisible && visualState == .recording
            isVisible = true
            visualState = .recording
            isLockedMode = isHandsFree
            statusText = nil
            if !isContinuingRecording {
                resetWaveform()
                startElapsedTimer(from: startedAt)
                startWaveformTicker()
            }
        case .transcribing:
            isVisible = true
            visualState = .processing
            isLockedMode = false
            statusText = nil
            stopElapsedTimer()
            stopWaveformTicker()
        case .inserting:
            isVisible = true
            visualState = .processing
            isLockedMode = false
            statusText = nil
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
                    self.updateWaveform()
                }
            }
        }
    }

    private func stopWaveformTicker() {
        waveformTask?.cancel()
        waveformTask = nil
    }

    private func updateWaveform() {
        waveformLevels = waveform.update(with: latestMeterFrame)
    }

    private func resetWaveform() {
        latestMeterFrame = .silent
        waveform.reset()
        waveformLevels = Array(repeating: LiveSpeechWaveform.idleLevel, count: LiveSpeechWaveform.barCount)
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
        timerText = Self.formattedElapsedTime(seconds: elapsed)
    }

    nonisolated static func formattedElapsedTime(seconds elapsed: Int) -> String {
        let elapsed = max(elapsed, 0)
        let hours = elapsed / 3_600
        let minutes = (elapsed % 3_600) / 60
        let seconds = elapsed % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
