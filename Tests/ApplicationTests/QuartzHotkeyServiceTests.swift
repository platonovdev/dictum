#if canImport(Testing)
import CoreGraphics
import Foundation
@testable import Infrastructure
import Testing

@Test
func quartzEventTapCallbackIsSafeOutsideTheMainActor() async {
    let state = HotkeyEventTapState()
    let invocationCounter = LockedInvocationCounter()
    state.configure(capturesSpace: true) {
        invocationCounter.increment()
    }
    state.setRightCommandHeld(true)

    let stateAddress = UInt(bitPattern: Unmanaged.passUnretained(state).toOpaque())
    let callbackCount = 1_000
    let consumedEveryTime = await Task.detached { () -> Bool in
        guard
            let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: 49,
                keyDown: true
            ),
            let proxy = CGEventTapProxy(bitPattern: 1),
            let statePointer = UnsafeMutableRawPointer(bitPattern: stateAddress)
        else {
            return false
        }

        return (0..<callbackCount).allSatisfy { _ in
            dictatorSpaceLatchEventTapCallback(
                proxy,
                .keyDown,
                event,
                statePointer
            ) == nil
        }
    }.value

    withExtendedLifetime(state) {}
    #expect(consumedEveryTime)
    #expect(invocationCounter.value == callbackCount)
}

private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
#endif
