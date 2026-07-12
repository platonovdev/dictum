import AppKit
import SwiftUI

enum OverlayLayout {
    static let initialWidth: CGFloat = 174
    static let height: CGFloat = 50
    static let cornerRadius: CGFloat = 15
    static let waveformWidth: CGFloat = 104
    static let compactIndicatorWidth: CGFloat = 18
}

public struct OverlayView: View {
    @ObservedObject private var viewModel: OverlayViewModel

    private static let morphAnimation: Animation = .spring(duration: 0.34, bounce: 0.06)

    public init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))

            HStack(spacing: 8) {
                visualIndicator
                    .frame(width: indicatorWidth, height: 24)

                Text(displayText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .contentTransition(.opacity)

                if viewModel.isLockedMode {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 10)
                        .transition(.scale(scale: 0.75).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: viewModel.isLockedMode ? 1.5 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous))
        .compositingGroup()
        .animation(Self.morphAnimation, value: viewModel.visualState)
        .animation(Self.morphAnimation, value: viewModel.isLockedMode)
    }

    private var indicatorWidth: CGFloat {
        viewModel.visualState == .recording
            ? OverlayLayout.waveformWidth
            : OverlayLayout.compactIndicatorWidth
    }

    private var displayText: String {
        switch viewModel.visualState {
        case .recording:
            return viewModel.timerText
        case .processing, .error:
            return viewModel.statusText ?? ""
        }
    }

    @ViewBuilder
    private var visualIndicator: some View {
        ZStack {
            if viewModel.visualState == .recording {
                LiveSpeechBarsView(levels: viewModel.waveformLevels)
                    .transition(.opacity)
            }

            if viewModel.visualState == .processing {
                ProcessingOrbView(accent: Color(nsColor: .labelColor))
                    .frame(width: 18, height: 18)
                    .transition(.opacity)
            }

            if viewModel.visualState == .error {
                ErrorOrbView()
                    .frame(width: 18, height: 18)
                    .transition(.opacity)
            }
        }
    }

    private var borderColor: Color {
        viewModel.isLockedMode
            ? Color(nsColor: .controlAccentColor).opacity(0.5)
            : Color(nsColor: .separatorColor).opacity(0.4)
    }
}

private struct LiveSpeechBarsView: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let centerY = size.height / 2
            let count = levels.count
            let gap: CGFloat = 1.5
            let barWidth = max(2, (size.width - (CGFloat(max(count - 1, 0)) * gap)) / CGFloat(max(count, 1)))

            for i in 0..<count {
                let level = levels[i]
                let intensity = CGFloat(min(max(level, 0), 1))
                let barH = max(3, intensity * size.height)
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

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.08))

            Circle()
                .stroke(accent.opacity(0.16), lineWidth: 2)

            Circle()
                .trim(from: 0.10, to: 0.72)
                .stroke(
                    accent.opacity(0.88),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
        }
        .onAppear {
            guard !isAnimating else {
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
                .stroke(Color(nsColor: .systemRed).opacity(0.28), lineWidth: 2)

            Image(systemName: "exclamationmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemRed).opacity(0.92))
        }
    }
}
