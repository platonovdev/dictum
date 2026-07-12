import AppKit
import Combine
import SwiftUI

@MainActor
public final class OverlayWindowController {
    private let panel: NSPanel
    private let viewModel: OverlayViewModel
    private var cancellables: Set<AnyCancellable> = []
    private var isEnabled = true

    public init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.worksWhenModal = true
        let hostingView = NSHostingView(rootView: OverlayView(viewModel: viewModel))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.sceneBridgingOptions = []
        panel.contentView = hostingView

        viewModel.$visualState
            .receive(on: RunLoop.main)
            .sink { [weak self] visualState in
                self?.updatePanelSize(for: visualState)
            }
            .store(in: &cancellables)

        viewModel.$isVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] isVisible in
                isVisible ? self?.show() : self?.hide()
            }
            .store(in: &cancellables)
    }

    public func show() {
        guard isEnabled else {
            return
        }
        updatePanelSize(for: viewModel.visualState)
        positionPanel()
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel.orderOut(nil)
    }

    public func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        if !isEnabled {
            hide()
        } else if viewModel.isVisible {
            show()
        }
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else {
            return
        }

        let frame = panel.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 34
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func updatePanelSize(for visualState: OverlayVisualState) {
        let size: NSSize
        switch visualState {
        case .recording:
            size = NSSize(width: 280, height: 60)
        case .processing, .error:
            size = NSSize(width: 280, height: 60)
        }

        guard panel.frame.size != size else {
            return
        }

        panel.setContentSize(size)
        if panel.isVisible {
            positionPanel()
        }
    }
}
