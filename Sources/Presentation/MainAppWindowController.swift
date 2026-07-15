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
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("Dictator", "Диктатор")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        window.contentMinSize = NSSize(width: 720, height: 520)
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
