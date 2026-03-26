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
                accessibilityDescription: "Dictum"
            )
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let historyItem = NSMenuItem(title: "History", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        let statisticsItem = NSMenuItem(title: "Statistics", action: #selector(openStatistics), keyEquivalent: "")
        statisticsItem.target = self
        menu.addItem(statisticsItem)

        let copyItem = NSMenuItem(title: "Copy Last Transcription", action: #selector(copyLastTranscription), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        let resetItem = NSMenuItem(title: "Reset Session", action: #selector(resetSession), keyEquivalent: "r")
        resetItem.target = self
        menu.addItem(resetItem)

        let restartItem = NSMenuItem(title: "Restart App", action: #selector(restartApp), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Dictum", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
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
