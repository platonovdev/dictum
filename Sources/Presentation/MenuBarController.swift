import AppKit

@MainActor
public final class MenuBarController: NSObject {
    public var onOpenSettings: (() -> Void)?
    public var onOpenHistory: (() -> Void)?
    public var onOpenStatistics: (() -> Void)?
    public var onRequestPermissions: (() -> Void)?
    public var onResetSession: (() -> Void)?
    public var onRestartApp: (() -> Void)?
    public var onQuit: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    public override init() {
        super.init()

        if let button = statusItem.button {
            button.title = "1BV"
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

        let permissionsItem = NSMenuItem(title: "Request Permissions", action: #selector(requestPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        let resetItem = NSMenuItem(title: "Reset Session", action: #selector(resetSession), keyEquivalent: "r")
        resetItem.target = self
        menu.addItem(resetItem)

        let restartItem = NSMenuItem(title: "Restart App", action: #selector(restartApp), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit OneBtnVoice", action: #selector(quit), keyEquivalent: "q")
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

    @objc private func requestPermissions() {
        onRequestPermissions?()
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
