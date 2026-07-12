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
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: OverlayLayout.initialWidth,
                height: OverlayLayout.height
            ),
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
        panel.hasShadow = true
        panel.worksWhenModal = true
        let hostingView = NSHostingView(rootView: OverlayView(viewModel: viewModel))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.sceneBridgingOptions = []
        panel.contentView = hostingView

        Publishers.CombineLatest3(
            viewModel.$visualState,
            viewModel.$statusText,
            viewModel.$isLockedMode
        )
        .debounce(for: .milliseconds(10), scheduler: RunLoop.main)
        .sink { [weak self] visualState, statusText, isLockedMode in
            self?.updatePanelFrame(
                for: visualState,
                statusText: statusText,
                isLockedMode: isLockedMode,
                animated: self?.panel.isVisible == true
            )
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
        updatePanelFrame(
            for: viewModel.visualState,
            statusText: viewModel.statusText,
            isLockedMode: viewModel.isLockedMode,
            animated: false
        )
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

    private func targetFrame(width: CGFloat) -> NSRect? {
        guard let screen = NSScreen.main else {
            return nil
        }

        let visible = screen.visibleFrame
        let x = visible.midX - width / 2
        let y = visible.minY + 34
        return NSRect(x: x, y: y, width: width, height: OverlayLayout.height)
    }

    private func updatePanelFrame(
        for visualState: OverlayVisualState,
        statusText: String?,
        isLockedMode: Bool,
        animated: Bool
    ) {
        let width = preferredWidth(
            for: visualState,
            statusText: statusText,
            isLockedMode: isLockedMode
        )
        guard let frame = targetFrame(width: width), panel.frame != frame else {
            return
        }

        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func preferredWidth(
        for visualState: OverlayVisualState,
        statusText: String?,
        isLockedMode: Bool
    ) -> CGFloat {
        let horizontalPadding: CGFloat = 28
        let contentSpacing: CGFloat = 10

        switch visualState {
        case .recording:
            let timerWidth: CGFloat = 42
            let lockWidth: CGFloat = isLockedMode ? 22 : 0
            return horizontalPadding
                + OverlayLayout.waveformWidth
                + contentSpacing
                + timerWidth
                + lockWidth
        case .processing, .error:
            let text = statusText ?? "Transcribing..."
            let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
            let measuredTextWidth = ceil(
                (text as NSString).size(withAttributes: [.font: font]).width
            )
            let naturalWidth = horizontalPadding
                + OverlayLayout.compactIndicatorWidth
                + contentSpacing
                + measuredTextWidth
            return min(max(naturalWidth, 156), 420)
        }
    }
}
