import AppKit
import SwiftUI

public struct OverlayView: View {
    @ObservedObject private var viewModel: OverlayViewModel

    public init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 10) {
            visualIndicator

            Text(displayText)
                .font(displayFont)
                .monospacedDigit()
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.16), radius: 12, y: 4)
        .animation(.easeOut(duration: 0.14), value: viewModel.visualState)
    }

    private var displayText: String {
        switch viewModel.visualState {
        case .recording:
            return viewModel.timerText
        case .processing, .preparing, .error:
            return viewModel.statusText ?? ""
        }
    }

    private var displayFont: Font {
        switch viewModel.visualState {
        case .recording:
            return .system(size: 24, weight: .semibold, design: .rounded)
        case .processing, .preparing, .error:
            return .system(size: 15, weight: .semibold, design: .rounded)
        }
    }

    @ViewBuilder
    private var visualIndicator: some View {
        switch viewModel.visualState {
        case .recording:
            MonochromeWaveformView(levels: viewModel.waveformLevels)
                .frame(width: 120, height: 28)
        case .processing, .preparing:
            ProcessingOrbView(accent: processingAccentColor)
                .frame(width: 22, height: 22)
                .frame(width: 120, height: 28, alignment: .leading)
        case .error:
            ErrorOrbView()
                .frame(width: 22, height: 22)
                .frame(width: 120, height: 28, alignment: .leading)
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

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color(nsColor: .controlBackgroundColor)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var labelColor: Color {
        Color(nsColor: .labelColor)
    }

    private var borderColor: Color {
        Color(nsColor: .separatorColor).opacity(0.4)
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

            // Draw bars right-aligned: newest bar flush with right edge.
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
        .animation(.linear(duration: 0.06), value: levels.count)
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
