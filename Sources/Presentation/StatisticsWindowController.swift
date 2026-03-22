import AppKit
import SwiftUI

@MainActor
public final class StatisticsWindowController {
    private let window: NSWindow

    public init(viewModel: StatisticsViewModel) {
        let rootView = StatisticsView(viewModel: viewModel)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OneBtnVoice Statistics"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: rootView)
    }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
