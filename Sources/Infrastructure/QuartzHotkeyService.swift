import Application
import AppKit
import Domain
import Foundation

@MainActor
public final class QuartzHotkeyService: GlobalHotkeyService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var spaceLatchTap: CFMachPort?
    private var spaceLatchTapSource: CFRunLoopSource?
    private let eventTapState = HotkeyEventTapState()
    private var isPressed = false

    public init() {}

    public func startListening(
        configuration: HotkeyConfiguration,
        handler: @escaping @Sendable (HotkeyEvent) -> Void
    ) throws {
        stopListening()
        eventTapState.configure(
            capturesSpace: configuration.kind == .rightCommandHold,
            handler: { handler(.lockRecording) }
        )

        let monitor: (NSEvent) -> Void = { [weak self] event in
            self?.handle(event: event, configuration: configuration, handler: handler)
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp], handler: monitor)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { event in
            monitor(event)
            return event
        }
        installSpaceLatchTap()
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
        if let spaceLatchTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), spaceLatchTapSource, .commonModes)
        }
        spaceLatchTapSource = nil
        spaceLatchTap = nil
        eventTapState.reset()
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

        // Fallback for systems where macOS does not allow an event tap. It
        // cannot suppress the physical Space key outside Dictum, so the tap
        // installed above is preferred whenever permissions allow it.
        if spaceLatchTap == nil,
           configuration.kind == .rightCommandHold,
           isPressed,
           event.type == .keyDown,
           event.keyCode == 49,
           !event.isARepeat {
            handler(.lockRecording)
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
            eventTapState.setRightCommandHeld(true)
            handler(.pressedAt(event.timestamp))
        } else if !pressedNow, isPressed {
            isPressed = false
            eventTapState.setRightCommandHeld(false)
            handler(.releasedAt(event.timestamp))
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
            handler(.pressedAt(event.timestamp))
        case .keyUp where isPressed:
            isPressed = false
            handler(.releasedAt(event.timestamp))
        default:
            break
        }
    }

    private func installSpaceLatchTap() {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let statePointer = Unmanaged.passUnretained(eventTapState).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard type == .keyDown, let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let state = Unmanaged<HotkeyEventTapState>.fromOpaque(userInfo).takeUnretainedValue()
                return state.consumeSpaceLatchIfNeeded(event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: statePointer
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        spaceLatchTap = tap
        spaceLatchTapSource = source
    }
}

private final class HotkeyEventTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var capturesSpace = false
    private var rightCommandHeld = false
    private var lockHandler: (@Sendable () -> Void)?

    func configure(capturesSpace: Bool, handler: @escaping @Sendable () -> Void) {
        lock.lock()
        self.capturesSpace = capturesSpace
        rightCommandHeld = false
        lockHandler = handler
        lock.unlock()
    }

    func setRightCommandHeld(_ isHeld: Bool) {
        lock.lock()
        rightCommandHeld = isHeld
        lock.unlock()
    }

    func reset() {
        lock.lock()
        capturesSpace = false
        rightCommandHeld = false
        lockHandler = nil
        lock.unlock()
    }

    func consumeSpaceLatchIfNeeded(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventKeycode) == 49 else {
            return false
        }

        lock.lock()
        let handler = capturesSpace && rightCommandHeld ? lockHandler : nil
        lock.unlock()
        guard let handler else {
            return false
        }
        handler()
        return true
    }
}
