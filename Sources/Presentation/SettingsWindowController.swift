import AppKit
import SwiftUI

@MainActor
public final class SettingsWindowController {
    private let window: NSWindow

    public init(
        settingsViewModel: SettingsViewModel,
        permissionsViewModel: PermissionsViewModel
    ) {
        let rootView = SettingsView(
            settingsViewModel: settingsViewModel,
            permissionsViewModel: permissionsViewModel
        )

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OneBtnVoice Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: rootView)
    }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
