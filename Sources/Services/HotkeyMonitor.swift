import Cocoa

final class HotkeyMonitor {
    enum StartStatus: Equatable {
        case ready
        case degraded(DegradedReason)
        case failed

        enum DegradedReason: String, Equatable {
            case listenEventDenied
            case eventTapUnavailable
        }

        var startupDescription: String {
            switch self {
            case .ready:
                return "ready: event tap active"
            case .degraded(.listenEventDenied):
                return "degraded: Input Monitoring denied; NSEvent fallback monitors active"
            case .degraded(.eventTapUnavailable):
                return "degraded: event tap unavailable; NSEvent fallback monitors active"
            case .failed:
                return "failed: no hotkey monitor available"
            }
        }

        var limitationsDescription: String? {
            switch self {
            case .ready, .failed:
                return nil
            case .degraded(.listenEventDenied):
                return """
                degraded mode limitations: Input Monitoring is denied, so fallback monitors are best-effort only; Right Command and Esc may still reach the focused app, and Secure Input or other protected contexts can block detection entirely
                """
            case .degraded(.eventTapUnavailable):
                return """
                degraded mode limitations: the event tap is unavailable, so fallback monitors are best-effort only; Right Command and Esc may still reach the focused app, and Secure Input or other protected contexts can block detection entirely
                """
            }
        }
    }

    private enum KeyCode {
        static let escape: Int = 53
        static let rightCommand: Int = 54
    }

    var onRightCommandPress: (() -> Void)?
    var onEscapePress: (() -> Void)?
    var shouldConsumeEscape: (() -> Bool)?

    private let dispatchToMain: (@escaping () -> Void) -> Void

    private enum ListenEventAccessStatus {
        case granted
        case denied
        case unavailable
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rightCommandDown = false

    init(dispatchToMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.dispatchToMain = dispatchToMain
    }

    @discardableResult
    func start() -> StartStatus {
        AppLog.debug("starting hotkey monitor", category: .hotkey)
        let status = installEventTapOrFallback()
        AppLog.event("hotkey monitor start status=\(status.startupDescription)", category: .hotkey)
        return status
    }

    func stop() {
        AppLog.debug("stopping hotkey monitor", category: .hotkey)
        removeAllMonitors()
    }

    private func installEventTapOrFallback() -> StartStatus {
        removeAllMonitors()

        let listenAccess = preflightListenEventAccess()
        switch listenAccess {
        case .granted:
            AppLog.debug("listen-event access granted", category: .hotkey)
        case .denied:
            let fallbackInstalled = installNSEventFallback()
            if !fallbackInstalled {
                AppLog.error("fallback monitor installation failed", category: .hotkey)
                return .failed
            }
            return .degraded(.listenEventDenied)
        case .unavailable:
            AppLog.debug("listen-event access API unavailable on this macOS version", category: .hotkey)
        }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return Unmanaged<HotkeyMonitor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                    .handleCGEvent(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            AppLog.event("event tap unavailable; attempting degraded NSEvent fallback monitors", category: .hotkey)
            let fallbackInstalled = installNSEventFallback()

            if !fallbackInstalled {
                AppLog.error("fallback monitor installation failed", category: .hotkey)
                return .failed
            }
            return .degraded(.eventTapUnavailable)
        }

        AppLog.debug("event tap installed", category: .hotkey)
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return .ready
    }

    private func installNSEventFallback() -> Bool {
        AppLog.debug("installing NSEvent fallback monitors", category: .hotkey)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleFallbackEvent(
                type: event.type,
                keyCode: event.keyCode,
                commandModifierActive: event.modifierFlags.contains(.command)
            )
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard
                let self,
                self.handleFallbackEvent(
                    type: event.type,
                    keyCode: event.keyCode,
                    commandModifierActive: event.modifierFlags.contains(.command)
                )
            else {
                return event
            }
            return nil
        }

        let installedGlobal = globalMonitor != nil
        let installedLocal = localMonitor != nil
        AppLog.debug("fallback monitor state global=\(installedGlobal) local=\(installedLocal)", category: .hotkey)
        return installedGlobal || installedLocal
    }

    private func removeAllMonitors() {
        AppLog.debug("removing monitors", category: .hotkey)
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            AppLog.event("event tap disabled by system, re-enabling", category: .hotkey)
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown, keyCode == KeyCode.escape, consumeEscapeIfNeeded(isFallback: false) {
            return nil
        }

        if type == .flagsChanged, keyCode == KeyCode.rightCommand {
            let consumed = handleRightCommandTransition(isDown: event.flags.contains(.maskCommand), isFallback: false)
            return consumed ? nil : Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    @discardableResult
    func handleFallbackEvent(type: NSEvent.EventType, keyCode: UInt16, commandModifierActive: Bool) -> Bool {
        if type == .keyDown, keyCode == KeyCode.escape {
            return consumeEscapeIfNeeded(isFallback: true)
        }

        guard type == .flagsChanged else { return false }

        if Int(keyCode) == KeyCode.rightCommand {
            return handleRightCommandTransition(isDown: commandModifierActive, isFallback: true)
        }

        if !commandModifierActive, rightCommandDown {
            rightCommandDown = false
        }

        return false
    }

    @discardableResult
    func consumeEscapeIfNeeded(isFallback: Bool) -> Bool {
        guard shouldConsumeEscape?() ?? false else { return false }
        if isFallback {
            AppLog.debug(
                "escape handled in degraded hotkey mode; fallback monitors cannot suppress the key globally",
                category: .hotkey
            )
        } else {
            AppLog.debug("escape consumed", category: .hotkey)
        }
        dispatchToMain { [weak self] in self?.onEscapePress?() }
        return true
    }

    @discardableResult
    func handleRightCommandTransition(isDown: Bool, isFallback: Bool) -> Bool {
        if isDown && !rightCommandDown {
            rightCommandDown = true
            if isFallback {
                AppLog.debug(
                    "right command observed in degraded hotkey mode; fallback monitors cannot suppress the key globally",
                    category: .hotkey
                )
            } else {
                AppLog.debug("right command pressed", category: .hotkey)
            }
            dispatchToMain { [weak self] in self?.onRightCommandPress?() }
            return true
        }

        if !isDown && rightCommandDown {
            rightCommandDown = false
            return true
        }

        return false
    }

    private func preflightListenEventAccess() -> ListenEventAccessStatus {
        guard #available(macOS 10.15, *) else { return .unavailable }
        return CGPreflightListenEventAccess() ? .granted : .denied
    }
}
