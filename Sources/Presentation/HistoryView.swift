import AppKit
import Domain
import Foundation
import SwiftUI

public struct HistoryView: View {
    @ObservedObject private var viewModel: HistoryViewModel

    public init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if viewModel.isLoading {
                loadingState
            } else if viewModel.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.entries) { entry in
                            historyCard(for: entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            footer
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(screenBackground)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("History")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))

                Text("Saved dictations, failures, and copied text live here. Deletions are local and permanent.")
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

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading saved dictations...")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)

            Text("No history yet")
                .font(.headline)

            Text("Dictations will appear here after you speak and stop the hotkey.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    @ViewBuilder
    private func historyCard(for entry: DictationHistoryEntry) -> some View {
        let transcript = entry.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(timestampText(for: entry.startedAt))
                        .font(.headline)

                    Text(metaText(for: entry))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                statusBadge(for: entry)
            }

            if transcript.isEmpty {
                Text(errorText(for: entry))
                    .font(.subheadline)
                    .foregroundStyle(entry.status == .failed ? .red : .secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(transcript)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if entry.status == .failed, let detail = entry.statusDetail, !detail.isEmpty {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }

            HStack {
                if entry.isRetryable {
                    Button("Retry") {
                        viewModel.retry(entry)
                    }
                    .disabled(viewModel.actionEntryID == entry.id)
                }

                Button("Copy") {
                    viewModel.copyTranscript(for: entry)
                }
                .disabled(transcript.isEmpty)

                Button(role: .destructive) {
                    viewModel.delete(entry)
                } label: {
                    Text("Delete")
                }
                .disabled(viewModel.actionEntryID == entry.id)

                Spacer()
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var footer: some View {
        HStack {
            if let message = viewModel.statusMessage ?? viewModel.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(minHeight: 22)
    }

    private func timestampText(for date: Date) -> String {
        date.formatted(
            .dateTime
                .weekday(.abbreviated)
                .month(.abbreviated)
                .day()
                .hour()
                .minute()
        )
    }

    private func metaText(for entry: DictationHistoryEntry) -> String {
        let duration = formattedDuration(entry.duration)
        let wordLabel = entry.wordCount == 1 ? "word" : "words"
        let status = statusLabel(for: entry.status)
        var parts = ["\(duration)", "\(entry.wordCount) \(wordLabel)", status]
        if let backend = entry.transcriptionBackend {
            parts.append(backendLabel(for: backend))
        }
        if let transcriptionDuration = entry.transcriptionDuration, transcriptionDuration > 0 {
            parts.append(String(format: "%.1fs", transcriptionDuration))
        }
        return parts.joined(separator: " • ")
    }

    private func backendLabel(for backend: TranscriptionBackend) -> String {
        switch backend {
        case .cloud:
            return "Cloud"
        case .local:
            return "Local"
        case .cloudWithLocalFallback:
            return "Cloud → Local"
        }
    }

    private func errorText(for entry: DictationHistoryEntry) -> String {
        if let detail = entry.statusDetail, !detail.isEmpty {
            return detail
        }

        return entry.status == .failed ? "Transcription failed." : "No transcript captured."
    }

    private func statusLabel(for status: DictationHistoryStatus) -> String {
        switch status {
        case .inserted:
            return "Inserted"
        case .clipboardFallback:
            return "Clipboard fallback"
        case .savedWithoutInsertion:
            return "Saved"
        case .emptyTranscript:
            return "Empty transcript"
        case .failed:
            return "Failed"
        }
    }

    @ViewBuilder
    private func statusBadge(for entry: DictationHistoryEntry) -> some View {
        Text(statusLabel(for: entry.status))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(badgeBackground(for: entry.status))
            .foregroundStyle(badgeForeground(for: entry.status))
            .clipShape(Capsule(style: .continuous))
    }

    private func badgeBackground(for status: DictationHistoryStatus) -> Color {
        switch status {
        case .inserted:
            return Color(nsColor: .selectedContentBackgroundColor).opacity(0.35)
        case .clipboardFallback:
            return Color(nsColor: .selectedContentBackgroundColor).opacity(0.35)
        case .savedWithoutInsertion:
            return Color(nsColor: .selectedContentBackgroundColor).opacity(0.35)
        case .emptyTranscript:
            return Color(nsColor: .quaternaryLabelColor).opacity(0.16)
        case .failed:
            return Color.red.opacity(0.12)
        }
    }

    private func badgeForeground(for status: DictationHistoryStatus) -> Color {
        switch status {
        case .failed:
            return .red
        default:
            return Color.primary
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: duration) ?? "0s"
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
    }

    private var screenBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}
