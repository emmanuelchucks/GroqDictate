import Cocoa

final class PasteTargetInspector {
    func canAutoPaste(into targetApp: NSRunningApplication?) -> Bool {
        guard let targetApp, !targetApp.isTerminated else {
            AppLog.audit("auto-paste target rejected reason=missing_or_terminated_app", category: .focus)
            return false
        }

        guard AXIsProcessTrusted() else {
            AppLog.audit("auto-paste target rejected reason=accessibility_not_trusted", category: .focus)
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard status == .success, let focusedValue else {
            AppLog.audit("auto-paste target rejected reason=focused_element_unavailable status=\(status.rawValue)", category: .focus)
            return false
        }
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            AppLog.audit("auto-paste target rejected reason=focused_element_unexpected_type", category: .focus)
            return false
        }

        let focusedElement = focusedValue as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(focusedElement, &pid)

        guard pid == targetApp.processIdentifier else {
            AppLog.audit(
                "auto-paste target rejected reason=focused_element_pid_mismatch expected=\(targetApp.processIdentifier) actual=\(pid)",
                category: .focus
            )
            return false
        }

        if isAttributeSettable(focusedElement, attribute: kAXValueAttribute as CFString) {
            AppLog.audit("auto-paste target accepted mode=settable_value role=\(stringAttribute(focusedElement, attribute: kAXRoleAttribute as CFString) ?? "n/a")", category: .focus)
            return true
        }

        let role = stringAttribute(focusedElement, attribute: kAXRoleAttribute as CFString)
        if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String || role == kAXComboBoxRole as String {
            AppLog.audit("auto-paste target accepted mode=text_role role=\(role ?? "n/a")", category: .focus)
            return true
        }

        if role == "AXWebArea",
           isAttributeSettable(focusedElement, attribute: kAXSelectedTextRangeAttribute as CFString) {
            AppLog.audit("auto-paste target accepted mode=web_area_selected_text_range role=\(role ?? "n/a")", category: .focus)
            return true
        }

        AppLog.audit("auto-paste target rejected reason=role_not_editable role=\(role ?? "n/a")", category: .focus)
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
