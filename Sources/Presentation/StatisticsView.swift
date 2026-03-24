import AppKit
import Foundation
import SwiftUI

public struct StatisticsView: View {
    @ObservedObject private var viewModel: StatisticsViewModel

    public init(viewModel: StatisticsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if viewModel.isLoading {
                loadingState
            } else {
                metricsGrid
            }

            footer
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(screenBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Statistics")
                .font(.system(size: 28, weight: .semibold, design: .rounded))

            Text("Calculated from successful dictations only so the numbers stay stable across relaunches.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Calculating totals...")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
    }

    private var metricsGrid: some View {
        VStack(spacing: 14) {
            metricCard(
                title: "Total dictated time",
                value: formattedDuration(viewModel.totalDuration),
                detail: "\(viewModel.entryCount) successful sessions"
            )

            metricCard(
                title: "Total words",
                value: "\(viewModel.totalWords)",
                detail: "Words captured from saved dictations"
            )
        }
    }

    private var footer: some View {
        HStack {
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Refresh") {
                Task { @MainActor in
                    await viewModel.reload()
                }
            }
        }
    }

    private func metricCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)

            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: duration) ?? "0s"
    }

    private var screenBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}
