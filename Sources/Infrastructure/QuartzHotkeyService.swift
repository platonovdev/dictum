import Application
import AppKit
import Domain
import Foundation

@MainActor
public final class QuartzHotkeyService: GlobalHotkeyService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isPressed = false

    public init() {}

    public func startListening(
        configuration: HotkeyConfiguration,
        handler: @escaping @Sendable (HotkeyEvent) -> Void
    ) throws {
        stopListening()

        let monitor: (NSEvent) -> Void = { [weak self] event in
            self?.handle(event: event, configuration: configuration, handler: handler)
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp], handler: monitor)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { event in
            monitor(event)
            return event
        }
    }

    public func stopListening() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        globalMonitor = nil
        localMonitor = nil
        isPressed = false
    }

    private func handle(
        event: NSEvent,
        configuration: HotkeyConfiguration,
        handler: @escaping @Sendable (HotkeyEvent) -> Void
    ) {
        if event.type == .keyDown, event.keyCode == 53 {
            handler(.escapePressed)
            return
        }

        switch configuration.kind {
        case .rightCommandHold:
            handleRightCommand(event: event, handler: handler)
        case .optionSpaceHold:
            handleOptionSpace(event: event, handler: handler)
        }
    }

    private func handleRightCommand(event: NSEvent, handler: @escaping @Sendable (HotkeyEvent) -> Void) {
        guard event.type == .flagsChanged, event.keyCode == 54 else {
            return
        }

        let pressedNow = event.modifierFlags.contains(.command)
        if pressedNow, !isPressed {
            isPressed = true
            handler(.pressed)
        } else if !pressedNow, isPressed {
            isPressed = false
            handler(.released)
        }
    }

    private func handleOptionSpace(event: NSEvent, handler: @escaping @Sendable (HotkeyEvent) -> Void) {
        guard event.keyCode == 49 else {
            return
        }

        let isOption = event.modifierFlags.contains(.option)
        switch event.type {
        case .keyDown where isOption && !isPressed:
            isPressed = true
            handler(.pressed)
        case .keyUp where isPressed:
            isPressed = false
            handler(.released)
        default:
            break
        }
    }
}
