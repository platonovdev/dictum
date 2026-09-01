import ApplicationServices
import CoreGraphics
import Foundation

/// Reads the insertion caret without activating Dictator or changing focus.
/// Some apps (notably canvas-based editors) don't expose text geometry; callers
/// must treat nil as a normal signal to use their fallback position.
public final class AccessibilityCaretAnchorProvider: @unchecked Sendable {
    private let messagingTimeout: Float

    public init(messagingTimeout: Float = 0.08) {
        self.messagingTimeout = messagingTimeout
    }

    public func currentCaretFrame() -> CGRect? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        var focusedElementReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementReference
        ) == .success,
            let focusedElementReference
        else {
            return nil
        }

        let element = focusedElementReference as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        guard !isSecure(element), let selection = selectedTextRange(on: element) else {
            return nil
        }

        guard selection.location >= 0, selection.length >= 0 else {
            return nil
        }
        let (selectionEnd, didOverflow) = selection.location.addingReportingOverflow(
            selection.length
        )
        guard !didOverflow else {
            return nil
        }

        var caretRange = CFRange(location: selectionEnd, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &caretRange) else {
            return nil
        }

        var boundsReference: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsReference
        ) == .success,
            let boundsReference,
            CFGetTypeID(boundsReference) == AXValueGetTypeID()
        else {
            return nil
        }

        let boundsValue = unsafeDowncast(boundsReference as AnyObject, to: AXValue.self)
        guard AXValueGetType(boundsValue) == .cgRect else {
            return nil
        }

        var bounds = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &bounds),
              bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width >= 0,
              bounds.height > 0 else {
            return nil
        }
        return bounds
    }

    private func selectedTextRange(on element: AXUIElement) -> CFRange? {
        var rangeReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeReference
        ) == .success,
            let rangeReference,
            CFGetTypeID(rangeReference) == AXValueGetTypeID()
        else {
            return nil
        }

        let rangeValue = unsafeDowncast(rangeReference as AnyObject, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else {
            return nil
        }
        var range = CFRange()
        return AXValueGetValue(rangeValue, .cfRange, &range) ? range : nil
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        var roleReference: CFTypeRef?
        var subroleReference: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleReference)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleReference)
        let role = (roleReference as? String) ?? ""
        let subrole = (subroleReference as? String) ?? ""
        return "\(role) \(subrole)".lowercased().contains("secure")
    }
}
