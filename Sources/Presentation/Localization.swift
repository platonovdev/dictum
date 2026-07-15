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
}
