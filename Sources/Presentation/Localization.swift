import Domain
import Foundation

enum L10n {
    static var isRussian: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") == true
    }

    static func text(_ english: String, _ russian: String) -> String {
        isRussian ? russian : english
    }

    static func count(_ value: Int, one: String, few: String, many: String) -> String {
        guard isRussian else {
            return value == 1 ? one : many
        }

        let mod10 = value % 10
        let mod100 = value % 100
        if mod10 == 1, mod100 != 11 {
            return one
        }
        if (2...4).contains(mod10), !(12...14).contains(mod100) {
            return few
        }
        return many
    }

    static func historyDetail(for entry: DictationHistoryEntry) -> String? {
        guard isRussian else {
            return entry.statusDetail
        }
        if entry.status == .emptyTranscript {
            return "Текст не распознан. Аудиозапись сохранена."
        }
        guard entry.status == .failed else {
            return entry.statusDetail
        }
        switch entry.failureStage {
        case .audioCapture:
            return "Запись была прервана. Сохранённое аудио можно обработать повторно."
        case .transcription:
            return "Не удалось распознать запись. Сохранённое аудио можно обработать повторно."
        case .insertion:
            return "Не удалось вставить текст. Распознанный текст сохранён в истории."
        case .persistence:
            return "Не удалось полностью сохранить результат."
        case nil:
            return "Не удалось завершить диктовку."
        }
    }
}
