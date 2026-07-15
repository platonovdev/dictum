import AppKit
import SwiftUI

enum OverlayLayout {
    static let initialWidth: CGFloat = 162
    static let height: CGFloat = 40
    static let cornerRadius: CGFloat = 12
    static let waveformWidth: CGFloat = 82
    static let compactIndicatorWidth: CGFloat = 15
}

public struct OverlayView: View {
    @ObservedObject private var viewModel: OverlayViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let stateAnimation: Animation = .easeInOut(duration: 0.22)
    private static let lockAnimation: Animation = .easeOut(duration: 0.18)

    public init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.985))

            // A restrained highlight keeps the light panel distinct from the desktop
            // without tinting the content itself blue.
            RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.34), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            stateContent
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: viewModel.isLockedMode ? 1 : 0.7)
        }
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .clipShape(RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous))
        .compositingGroup()
        .animation(reduceMotion ? nil : Self.stateAnimation, value: viewModel.visualState)
        .animation(reduceMotion ? nil : Self.lockAnimation, value: viewModel.isLockedMode)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .help(viewModel.statusText ?? "")
    }

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.visualState {
        case .recording:
            recordingContent
                .transition(.opacity)
        case .processing:
            ProcessingOrbView(accent: Color.black.opacity(0.56))
                .frame(width: OverlayLayout.compactIndicatorWidth, height: 15)
                .frame(maxWidth: .infinity, alignment: .center)
            .transition(.opacity)
        case .error:
            statusContent {
                ErrorOrbView()
            }
            .transition(.opacity)
        }
    }

    private var recordingContent: some View {
        HStack(spacing: 7) {
            LiveSpeechBarsView(levels: viewModel.waveformLevels)
                .frame(width: OverlayLayout.waveformWidth, height: 20)

            Text(viewModel.timerText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.black.opacity(0.82))
                .frame(width: 32, alignment: .leading)

            ZStack {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .opacity(viewModel.isLockedMode ? 1 : 0)
                    .scaleEffect(viewModel.isLockedMode ? 1 : 0.82)
            }
            .frame(width: 14)
        }
    }

    @ViewBuilder
    private func statusContent<Indicator: View>(@ViewBuilder indicator: () -> Indicator) -> some View {
        HStack(spacing: 7) {
            indicator()
                .frame(width: OverlayLayout.compactIndicatorWidth, height: 15)
            Text(viewModel.statusText ?? "")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.82))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var accentColor: Color {
        Color(nsColor: .controlAccentColor)
    }

    private var borderColor: Color {
        viewModel.isLockedMode
            ? accentColor.opacity(0.48)
            : .black.opacity(0.10)
    }

    private var accessibilityLabel: String {
        switch viewModel.visualState {
        case .recording:
            return viewModel.isLockedMode
                ? L10n.text("Dictator recording, locked", "Диктатор записывает, запись закреплена")
                : L10n.text("Dictator recording", "Диктатор записывает")
        case .processing:
            return L10n.text("Dictator is processing speech", "Диктатор обрабатывает речь")
        case .error:
            return L10n.text("Dictator error", "Ошибка Диктатора")
        }
    }

    private var accessibilityValue: String {
        switch viewModel.visualState {
        case .recording:
            return viewModel.timerText
        case .processing:
            return L10n.text("Please wait", "Подождите")
        case .error:
            return viewModel.statusText ?? ""
        }
    }
}

private struct LiveSpeechBarsView: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let centerY = size.height / 2
            let count = levels.count
            let gap: CGFloat = 1.2
            let barWidth = max(1.7, (size.width - (CGFloat(max(count - 1, 0)) * gap)) / CGFloat(max(count, 1)))

            for i in 0..<count {
                let level = levels[i]
                let intensity = CGFloat(min(max(level, 0), 1))
                let barH = max(1, intensity * size.height)
                let opacity = 0.35 + (Double(intensity) * 0.62)

                let x = CGFloat(i) * (barWidth + gap)

                let rect = CGRect(
                    x: x,
                    y: centerY - barH / 2,
                    width: barWidth,
                    height: barH
                )
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(path, with: .color(Color.accentColor.opacity(opacity)))
            }
        }
        .clipped()
    }
}

private struct ProcessingOrbView: View {
    let accent: Color
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.08))

            Circle()
                .stroke(accent.opacity(0.16), lineWidth: 1.5)

            Circle()
                .trim(from: 0.10, to: 0.72)
                .stroke(
                    accent.opacity(0.88),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
        }
        .onAppear {
            guard !reduceMotion, !isAnimating else {
                return
            }

            withAnimation(.linear(duration: 0.95).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
}

private struct ErrorOrbView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .systemRed).opacity(0.12))

            Circle()
                .stroke(Color(nsColor: .systemRed).opacity(0.28), lineWidth: 1.5)

            Image(systemName: "exclamationmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemRed).opacity(0.92))
        }
    }
}
