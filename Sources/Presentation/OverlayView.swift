import AppKit
import SwiftUI

public struct OverlayView: View {
    @ObservedObject private var viewModel: OverlayViewModel

    private static let morphAnimation: Animation = .spring(duration: 0.4, bounce: 0.12)

    public init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 10) {
            visualIndicator

            Text(displayText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.interpolate)

            if viewModel.isLockedMode {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(borderColor, lineWidth: viewModel.isLockedMode ? 1.5 : 1)
        }
        .compositingGroup()
        .animation(Self.morphAnimation, value: viewModel.visualState)
        .animation(Self.morphAnimation, value: viewModel.isLockedMode)
    }

    private var displayText: String {
        switch viewModel.visualState {
        case .recording:
            return viewModel.timerText
        case .processing, .preparing, .error:
            return viewModel.statusText ?? ""
        }
    }

    @ViewBuilder
    private var visualIndicator: some View {
        ZStack {
            if viewModel.visualState == .recording {
                MonochromeWaveformView(levels: viewModel.waveformLevels)
                    .frame(width: 120, height: 28)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            if viewModel.visualState == .processing || viewModel.visualState == .preparing {
                ProcessingOrbView(accent: processingAccentColor)
                    .frame(width: 22, height: 22)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }

            if viewModel.visualState == .error {
                ErrorOrbView()
                    .frame(width: 22, height: 22)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
    }

    private var processingAccentColor: Color {
        switch viewModel.visualState {
        case .preparing:
            return Color(nsColor: .secondaryLabelColor)
        default:
            return Color(nsColor: .labelColor)
        }
    }

    private var borderColor: Color {
        viewModel.isLockedMode
            ? Color(nsColor: .controlAccentColor).opacity(0.5)
            : Color(nsColor: .separatorColor).opacity(0.4)
    }
}

private struct MonochromeWaveformView: View {
    let levels: [Float]

    private let barWidth: CGFloat = 3.5
    private let barGap: CGFloat = 1.5
    private let cornerRadius: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let step = barWidth + barGap
            let centerY = size.height / 2
            let count = levels.count

            for i in 0..<count {
                let level = levels[i]
                let intensity = CGFloat(min(max(level, 0), 1))
                let barH = max(2, intensity * size.height * 0.9)
                let opacity = 0.28 + (Double(intensity) * 0.52)

                let x = size.width - CGFloat(count - i) * step
                guard x + barWidth > 0 else { continue }

                let rect = CGRect(
                    x: x,
                    y: centerY - barH / 2,
                    width: barWidth,
                    height: barH
                )
                let path = Path(roundedRect: rect, cornerRadius: cornerRadius)
                context.fill(path, with: .color(Color(nsColor: .labelColor).opacity(opacity)))
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
                .stroke(accent.opacity(0.16), lineWidth: 2.5)

            Circle()
                .trim(from: 0.10, to: 0.72)
                .stroke(
                    accent.opacity(0.88),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
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
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemRed).opacity(0.92))
        }
    }
}
