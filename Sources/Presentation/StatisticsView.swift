import AppKit
import Charts
import Foundation
import SwiftUI

public struct StatisticsView: View {
    @ObservedObject private var viewModel: StatisticsViewModel

    public init(viewModel: StatisticsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if viewModel.isLoading {
                loadingState
            } else {
                metricsGrid
                wordsChart
            }

            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(screenBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Statistics")
                .font(.system(size: 23, weight: .semibold, design: .rounded))

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
        HStack(spacing: 10) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var wordsChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Words per day")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("Last 30 days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart(viewModel.dailyWordCounts) { item in
                BarMark(
                    x: .value("Day", item.date, unit: .day),
                    y: .value("Words", item.words)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { value in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisTick()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel()
                }
            }
            .frame(height: 190)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }

    private func metricCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))

            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)

            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
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
