import AppKit
import SwiftUI

@MainActor
public final class MainAppWindowController {
    private let window: NSWindow
    private let viewModel: MainAppViewModel

    public init(viewModel: MainAppViewModel) {
        self.viewModel = viewModel

        let rootView = MainAppView(viewModel: viewModel)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictum"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentMinSize = NSSize(width: 680, height: 480)
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: rootView)
    }

    public func show(section: MainAppSection) {
        Task { @MainActor in
            await viewModel.open(section: section)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}
