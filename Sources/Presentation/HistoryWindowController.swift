import AppKit
import SwiftUI

@MainActor
public final class HistoryWindowController {
    private let window: NSWindow

    public init(viewModel: HistoryViewModel) {
        let rootView = HistoryView(viewModel: viewModel)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("Dictator History", "История — Диктатор")
        window.isReleasedWhenClosed = false
        window.center()
        window.contentMinSize = NSSize(width: 620, height: 420)
        window.contentView = NSHostingView(rootView: rootView)
    }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
