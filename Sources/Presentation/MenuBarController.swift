import AppKit

@MainActor
public final class MenuBarController: NSObject {
    public var onOpenSettings: (() -> Void)?
    public var onOpenHistory: (() -> Void)?
    public var onOpenStatistics: (() -> Void)?
    public var onCopyLastTranscription: (() -> Void)?
    public var onResetSession: (() -> Void)?
    public var onRestartApp: (() -> Void)?
    public var onQuit: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    public override init() {
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "mic",
                accessibilityDescription: L10n.text("Dictator", "Диктатор")
            )
        }

        let menu = NSMenu()
        let settingsItem = menuItem(title: L10n.text("Settings…", "Настройки…"), symbol: "gearshape", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let historyItem = menuItem(title: L10n.text("Show History", "Показать историю"), symbol: "text.badge.clock", action: #selector(openHistory))
        historyItem.target = self
        menu.addItem(historyItem)

        let statisticsItem = menuItem(title: L10n.text("Show Statistics", "Показать статистику"), symbol: "chart.bar", action: #selector(openStatistics))
        statisticsItem.target = self
        menu.addItem(statisticsItem)

        menu.addItem(.separator())

        let copyItem = menuItem(title: L10n.text("Copy Last Transcription", "Скопировать последний текст"), symbol: "doc.on.doc", action: #selector(copyLastTranscription), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        let resetItem = menuItem(title: L10n.text("Reset Dictation", "Сбросить запись"), symbol: "arrow.counterclockwise", action: #selector(resetSession), keyEquivalent: "r")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let restartItem = menuItem(title: L10n.text("Restart Dictator", "Перезапустить Диктатор"), symbol: "arrow.clockwise", action: #selector(restartApp))
        restartItem.target = self
        menu.addItem(restartItem)

        let quitItem = menuItem(title: L10n.text("Quit Dictator", "Выйти из Диктатора"), symbol: "power", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func menuItem(title: String, symbol: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func openHistory() {
        onOpenHistory?()
    }

    @objc private func openStatistics() {
        onOpenStatistics?()
    }

    @objc private func copyLastTranscription() {
        onCopyLastTranscription?()
    }

    @objc private func resetSession() {
        onResetSession?()
    }

    @objc private func restartApp() {
        onRestartApp?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
