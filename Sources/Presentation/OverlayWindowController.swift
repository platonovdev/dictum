import AppKit
import Combine
import SwiftUI

@MainActor
public final class OverlayWindowController {
    private let panel: NSPanel
    private let viewModel: OverlayViewModel
    private var cancellables: Set<AnyCancellable> = []
    private var isEnabled = true
    private var lastRecordingWidth = OverlayLayout.initialWidth

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
        // The standard NSPanel shadow is intentionally disabled: it is much
        // broader than this compact overlay and makes the panel look blurred.
        panel.hasShadow = false
        panel.worksWhenModal = true
        let hostingView = NSHostingView(rootView: OverlayView(viewModel: viewModel))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.sceneBridgingOptions = []
        panel.contentView = hostingView

        Publishers.CombineLatest(
            viewModel.$visualState,
            viewModel.$statusText
        )
        .debounce(for: .milliseconds(10), scheduler: RunLoop.main)
        .sink { [weak self] visualState, statusText in
            self?.updatePanelFrame(
                for: visualState,
                statusText: statusText,
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
        let wasVisible = panel.isVisible
        updatePanelFrame(
            for: viewModel.visualState,
            statusText: viewModel.statusText,
            animated: false
        )
        if !wasVisible {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()

        guard !wasVisible else {
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            // Six frames at 60 Hz preserve a soft appearance without making
            // the already-ready microphone feel delayed.
            context.duration = 0.10
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
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
        let y = visible.minY + 18
        return NSRect(x: x, y: y, width: width, height: OverlayLayout.height)
    }

    private func updatePanelFrame(
        for visualState: OverlayVisualState,
        statusText: String?,
        animated: Bool
    ) {
        let width = preferredWidth(
            for: visualState,
            statusText: statusText
        )
        guard let frame = targetFrame(width: width), panel.frame != frame else {
            return
        }

        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func preferredWidth(
        for visualState: OverlayVisualState,
        statusText: String?
    ) -> CGFloat {
        let horizontalPadding: CGFloat = 20
        let contentSpacing: CGFloat = 7

        switch visualState {
        case .recording:
            // The lock slot is always reserved by OverlayView, so toggling
            // hands-free mode never changes the panel geometry.
            lastRecordingWidth = OverlayLayout.initialWidth
            return OverlayLayout.initialWidth
        case .processing:
            // Preserve the final recording geometry while the content crossfades.
            return lastRecordingWidth
        case .error:
            let text = statusText ?? "Something went wrong"
            let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let measuredTextWidth = ceil(
                (text as NSString).size(withAttributes: [.font: font]).width
            )
            let naturalWidth = horizontalPadding
                + OverlayLayout.compactIndicatorWidth
                + contentSpacing
                + measuredTextWidth
            return min(max(naturalWidth, lastRecordingWidth), 260)
        }
    }
}
