import Application
import AppKit
import ApplicationServices
import Domain
import Foundation

private struct PasteboardSnapshot: Sendable {
    let items: [[String: Data]]
}

public final class AccessibilityTextInsertionService: TextInsertionService, @unchecked Sendable {
    private let messagingTimeout: Float = 0.35

    public init() {}

    public func insert(text: String) async -> InsertionResult {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        var focusedElementRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )

        guard focusedResult == .success, let focusedElementRef else {
            return .failure(.insertionFailed("No focused text element was found."))
        }

        let element = focusedElementRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        if isSecure(element: element) {
            return .failure(.secureInputField)
        }

        if let directInsertionResult = insertIntoSelectionIfPossible(text: text, element: element) {
            return directInsertionResult
        }

        var isSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        )

        guard settableResult == .success, isSettable.boolValue else {
            return .failure(.insertionFailed("Focused element does not allow AX value updates."))
        }

        let updateResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            text as CFString
        )

        return updateResult == .success
            ? .success
            : .failure(.insertionFailed("AX value update returned \(updateResult.rawValue)."))
    }

    private func insertIntoSelectionIfPossible(text: String, element: AXUIElement) -> InsertionResult? {
        guard let currentValue = stringAttribute(kAXValueAttribute as CFString, on: element),
              let selectedRange = selectedTextRange(on: element) else {
            return nil
        }

        let nsValue = currentValue as NSString
        let safeLocation = min(max(selectedRange.location, 0), nsValue.length)
        let maxLength = nsValue.length - safeLocation
        let safeLength = min(max(selectedRange.length, 0), maxLength)
        let safeRange = NSRange(location: safeLocation, length: safeLength)
        let updatedValue = nsValue.replacingCharacters(in: safeRange, with: text)

        let updateResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFString
        )

        guard updateResult == .success else {
            return .failure(.insertionFailed("AX selected-range insertion returned \(updateResult.rawValue)."))
        }

        let insertionEnd = safeLocation + (text as NSString).length
        var updatedSelection = CFRange(location: insertionEnd, length: 0)
        guard let updatedSelectionValue = AXValueCreate(.cfRange, &updatedSelection) else {
            return .success
        }

        _ = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            updatedSelectionValue
        )

        return .success
    }

    private func stringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success else {
            return nil
        }

        return valueRef as? String
    }

    private func selectedTextRange(on element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        )
        guard result == .success,
              let rangeValue = rangeRef,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(rangeValue as AnyObject, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return range
    }

    private func isSecure(element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)

        let role = (roleRef as? String) ?? ""
        let subrole = (subroleRef as? String) ?? ""
        let composite = "\(role) \(subrole)".lowercased()
        return composite.contains("secure")
    }
}

public final class ClipboardPasteFallbackService: ClipboardFallbackService, ClipboardWriting, @unchecked Sendable {
    public init() {}

    public func insert(text: String) async -> InsertionResult {
        let snapshot = await MainActor.run {
            snapshotPasteboard()
        }
        let frontmostApplication = await MainActor.run {
            NSWorkspace.shared.frontmostApplication
        }

        await MainActor.run {
            copy(text: text)
        }

        _ = await MainActor.run {
            frontmostApplication?.activate(options: [])
        }

        try? await Task.sleep(for: .milliseconds(120))

        let didPostShortcut = await MainActor.run {
            postPasteShortcut()
        }

        guard didPostShortcut else {
            await MainActor.run {
                restorePasteboard(from: snapshot)
            }
            return .failure(.insertionFailed("Could not send Cmd+V paste event."))
        }

        try? await Task.sleep(for: .milliseconds(180))

        await MainActor.run {
            restorePasteboard(from: snapshot)
        }

        return .success
    }

    public func copyToClipboard(text: String) async -> InsertionResult {
        await MainActor.run {
            copy(text: text)
        }
        return .clipboardFallback
    }

    public func copy(text: String) async {
        _ = await copyToClipboard(text: text)
    }

    private func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func snapshotPasteboard() -> PasteboardSnapshot {
        let items: [[String: Data]] = NSPasteboard.general.pasteboardItems?.map { item in
            let serializedPairs: [(String, Data)] = item.types.compactMap { type in
                guard let data = item.data(forType: type) else {
                    return nil
                }
                return (type.rawValue, data)
            }
            return Dictionary(uniqueKeysWithValues: serializedPairs)
        } ?? []

        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboard(from snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else {
            return
        }

        let restoredItems = snapshot.items.map { serializedItem in
            let item = NSPasteboardItem()
            for (rawType, data) in serializedItem {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }

        pasteboard.writeObjects(restoredItems)
    }

    private func postPasteShortcut() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand

        guard let keyDown, let keyUp else {
            return false
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

public final class CompositeTextInsertionService: TextInsertionService, @unchecked Sendable {
    private let pasteboardInsertion: ClipboardFallbackService
    private let accessibilityInsertion: TextInsertionService

    public init(
        pasteboardInsertion: ClipboardFallbackService,
        accessibilityInsertion: TextInsertionService
    ) {
        self.pasteboardInsertion = pasteboardInsertion
        self.accessibilityInsertion = accessibilityInsertion
    }

    public func insert(text: String) async -> InsertionResult {
        let pasteResult = await pasteboardInsertion.insert(text: text)

        switch pasteResult {
        case .success:
            return .success
        case .clipboardFallback:
            return .success
        case .failure:
            let accessibilityResult = await withAccessibilityInsertionTimeout(text: text)
            switch accessibilityResult {
            case .success:
                return .success
            case .failure(.secureInputField):
                return await pasteboardInsertion.copyToClipboard(text: text)
            case .failure:
                return await pasteboardInsertion.copyToClipboard(text: text)
            case .clipboardFallback:
                return .success
            }
        }
    }

    private func withAccessibilityInsertionTimeout(text: String) async -> InsertionResult {
        await withTaskGroup(of: InsertionResult.self) { group in
            group.addTask { [accessibilityInsertion] in
                await accessibilityInsertion.insert(text: text)
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(450))
                return .failure(.insertionFailed("Accessibility insertion timed out."))
            }

            let firstResult = await group.next() ?? .failure(.insertionFailed("Insertion produced no result."))
            group.cancelAll()
            return firstResult
        }
    }
}
