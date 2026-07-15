import AppKit
import Domain
import Foundation
import SwiftUI

public struct HistoryView: View {
    @ObservedObject private var viewModel: HistoryViewModel
    @State private var entryPendingDeletion: DictationHistoryEntry? = nil

    public init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if viewModel.isLoading {
                loadingState
            } else if viewModel.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.entries) { entry in
                            historyCard(for: entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(screenBackground)
        .confirmationDialog(
            L10n.text("Delete this dictation?", "Удалить эту диктовку?"),
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { if !$0 { entryPendingDeletion = nil } }
            )
        ) {
            Button(L10n.text("Delete text and recording", "Удалить текст и запись"), role: .destructive) {
                if let entryPendingDeletion {
                    viewModel.delete(entryPendingDeletion)
                }
                entryPendingDeletion = nil
            }
            Button(L10n.text("Cancel", "Отмена"), role: .cancel) {
                entryPendingDeletion = nil
            }
        } message: {
            Text(L10n.text(
                "This permanently removes the recognized text and any retained audio from this Mac.",
                "Распознанный текст и сохранённая аудиозапись будут навсегда удалены с этого Mac."
            ))
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("History", "История"))
                    .font(.system(size: 23, weight: .semibold, design: .rounded))

                if !viewModel.entries.isEmpty {
                    Text(historySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(L10n.text("Refresh", "Обновить")) {
                Task { @MainActor in
                    await viewModel.reload()
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L10n.text("Loading saved dictations…", "Загружаем сохранённые диктовки…"))
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

            Text(L10n.text("No history yet", "История пока пуста"))
                .font(.headline)

            Text(L10n.text(
                "Dictations will appear here after you speak and release the hotkey.",
                "Диктовки появятся здесь после того, как вы закончите говорить и отпустите клавишу."
            ))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    @ViewBuilder
    private func historyCard(for entry: DictationHistoryEntry) -> some View {
        let transcript = entry.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(timestampText(for: entry.startedAt))
                        .font(.system(size: 13, weight: .semibold))

                    Text(metaText(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                statusBadge(for: entry)
            }

            if transcript.isEmpty {
                Text(errorText(for: entry))
                    .font(.system(size: 12))
                    .foregroundStyle(entry.status == .failed ? .red : .secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(transcript)
                        .font(.system(size: 13))
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
                if entry.audioArtifactPath != nil {
                    Button {
                        viewModel.togglePlayback(for: entry)
                    } label: {
                        Label(
                            viewModel.playingEntryID == entry.id
                                ? L10n.text("Stop", "Остановить")
                                : L10n.text("Play", "Воспроизвести"),
                            systemImage: viewModel.playingEntryID == entry.id ? "stop.fill" : "play.fill"
                        )
                    }
                    .disabled(!entry.isRetryable || viewModel.actionEntryID == entry.id)
                }

                if entry.isRetryable {
                    Button {
                        viewModel.retry(entry)
                    } label: {
                        Label(L10n.text("Retry", "Повторить"), systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.actionEntryID == entry.id)
                }

                Button {
                    viewModel.copyTranscript(for: entry)
                } label: {
                    Label(L10n.text("Copy", "Копировать"), systemImage: "doc.on.doc")
                }
                .disabled(transcript.isEmpty)

                Button(role: .destructive) {
                    entryPendingDeletion = entry
                } label: {
                    Label(L10n.text("Delete", "Удалить"), systemImage: "trash")
                }
                .disabled(viewModel.actionEntryID == entry.id)

                Spacer()
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
        }
        .padding(12)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var footer: some View {
        HStack {
            if let message = viewModel.errorMessage ?? viewModel.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(viewModel.errorMessage == nil ? Color.secondary : Color.red)
            }

            Spacer()
        }
        .frame(minHeight: 18)
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
        let wordLabel = L10n.count(entry.wordCount, one: L10n.text("word", "слово"), few: "слова", many: L10n.text("words", "слов"))
        let status = statusLabel(for: entry.status)
        var parts = ["\(duration)", "\(entry.wordCount) \(wordLabel)", status]
        if let backend = entry.transcriptionBackend {
            parts.append(backendLabel(for: backend))
        }
        if let transcriptionDuration = entry.transcriptionDuration, transcriptionDuration > 0 {
            parts.append(String(format: "%.1fs", transcriptionDuration))
        }
        if entry.audioArtifactPath != nil {
            parts.append(entry.isRetryable ? L10n.text("Audio saved", "Аудио сохранено") : L10n.text("Audio missing", "Аудио недоступно"))
        }
        if entry.retryCount > 0 {
            parts.append("\(L10n.text("Retried", "Повторов")) \(entry.retryCount)×")
        }
        return parts.joined(separator: " • ")
    }

    private var historySummary: String {
        let audioCount = viewModel.entries.filter(\.isRetryable).count
        let entryLabel = L10n.count(viewModel.entries.count, one: L10n.text("dictation", "диктовка"), few: "диктовки", many: L10n.text("dictations", "диктовок"))
        let audioLabel = L10n.count(audioCount, one: L10n.text("recording available", "запись доступна"), few: "записи доступны", many: L10n.text("recordings available", "записей доступно"))
        return "\(viewModel.entries.count) \(entryLabel) • \(audioCount) \(audioLabel)"
    }

    private func backendLabel(for backend: TranscriptionBackend) -> String {
        switch backend {
        case .cloud:
            return L10n.text("Cloud", "Облако")
        case .local:
            return L10n.text("Local", "Локально")
        case .cloudWithLocalFallback:
            return L10n.text("Cloud → Local", "Облако → локально")
        }
    }

    private func errorText(for entry: DictationHistoryEntry) -> String {
        if let detail = entry.statusDetail, !detail.isEmpty {
            return detail
        }

        return entry.status == .failed
            ? L10n.text("Recognition failed.", "Не удалось распознать речь.")
            : L10n.text("No text was recognized.", "Текст не распознан.")
    }

    private func statusLabel(for status: DictationHistoryStatus) -> String {
        switch status {
        case .inserted:
            return L10n.text("Inserted", "Вставлено")
        case .clipboardFallback:
            return L10n.text("Clipboard fallback", "Через буфер обмена")
        case .savedWithoutInsertion:
            return L10n.text("Saved", "Сохранено")
        case .emptyTranscript:
            return L10n.text("Empty text", "Пустой текст")
        case .failed:
            return L10n.text("Failed", "Ошибка")
        }
    }

    @ViewBuilder
    private func statusBadge(for entry: DictationHistoryEntry) -> some View {
        Text(statusLabel(for: entry.status))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
    }

    private var screenBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}
