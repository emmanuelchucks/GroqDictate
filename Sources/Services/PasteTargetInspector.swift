import Cocoa

final class PasteTargetInspector {
    func canAutoPaste(into targetApp: NSRunningApplication?) -> Bool {
        guard let targetApp, !targetApp.isTerminated else {
            return false
        }

        guard AXIsProcessTrusted() else {
            AppLog.debug("accessibility not trusted; skipping auto paste", category: .focus)
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard status == .success, let focusedValue else {
            AppLog.debug("focused element unavailable (status=\(status.rawValue))", category: .focus)
            return false
        }
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            AppLog.debug("focused element returned unexpected type", category: .focus)
            return false
        }

        let focusedElement = focusedValue as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(focusedElement, &pid)

        guard pid == targetApp.processIdentifier else {
            AppLog.debug(
                "focused element pid mismatch expected=\(targetApp.processIdentifier) actual=\(pid)",
                category: .focus
            )
            return false
        }

        if isAttributeSettable(focusedElement, attribute: kAXValueAttribute as CFString) {
            return true
        }

        let role = stringAttribute(focusedElement, attribute: kAXRoleAttribute as CFString)
        if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String || role == kAXComboBoxRole as String {
            return true
        }

        if role == "AXWebArea",
           isAttributeSettable(focusedElement, attribute: kAXSelectedTextRangeAttribute as CFString) {
            return true
        }

        AppLog.debug("focused element role not editable role=\(role ?? "n/a")", category: .focus)
        return false
    }

    private func isAttributeSettable(_ element: AXUIElement, attribute: CFString) -> Bool {
        var isSettable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute, &isSettable)
        return status == .success && isSettable.boolValue
    }

    private func stringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
        guard status == .success, let rawValue else { return nil }
        return rawValue as? String
    }
}
