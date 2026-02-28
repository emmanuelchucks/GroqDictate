import Cocoa

final class HotkeyMonitor {
    enum StartStatus: Equatable {
        case ready
        case listenDenied
        case fallback
        case failed
    }

    private enum KeyCode {
        static let escape: Int = 53
        static let rightCommand: Int = 54
    }

    var onRightCommandPress: (() -> Void)?
    var onEscapePress: (() -> Void)?
    var shouldConsumeEscape: (() -> Bool)?

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

    @discardableResult
    func start() -> StartStatus {
        AppLog.debug("starting hotkey monitor", category: .hotkey)
        let status = installEventTapOrFallback()
        AppLog.event("hotkey monitor start status=\(describe(status))", category: .hotkey)
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
            AppLog.event("listen-event access denied; skipping event tap and using fallback", category: .hotkey)
            let fallbackInstalled = installNSEventFallback()
            if !fallbackInstalled {
                AppLog.error("fallback monitor installation failed", category: .hotkey)
                return .failed
            }
            AppLog.event("fallback active with listen-event access denied", category: .hotkey)
            return .listenDenied
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
            AppLog.event("event tap unavailable, attempting NSEvent fallback", category: .hotkey)
            let fallbackInstalled = installNSEventFallback()

            if !fallbackInstalled {
                AppLog.error("fallback monitor installation failed", category: .hotkey)
                return .failed
            }

            AppLog.event("fallback monitors active", category: .hotkey)
            return .fallback
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
            self?.handleNSEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleNSEvent(event)
            return event
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

        if type == .keyDown, keyCode == KeyCode.escape, consumeEscape(logSuffix: "") {
            return nil
        }

        if type == .flagsChanged, keyCode == KeyCode.rightCommand {
            let consumed = handleRightCommand(isDown: event.flags.contains(.maskCommand), logSuffix: "")
            return consumed ? nil : Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleNSEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == KeyCode.escape {
            _ = consumeEscape(logSuffix: " (fallback)")
            return
        }

        guard event.type == .flagsChanged else { return }

        if event.keyCode == KeyCode.rightCommand {
            _ = handleRightCommand(isDown: event.modifierFlags.contains(.command), logSuffix: " (fallback)")
            return
        }

        if !event.modifierFlags.contains(.command), rightCommandDown {
            rightCommandDown = false
        }
    }

    private func consumeEscape(logSuffix: String) -> Bool {
        guard shouldConsumeEscape?() ?? false else { return false }
        AppLog.debug("escape consumed\(logSuffix)", category: .hotkey)
        DispatchQueue.main.async { [weak self] in self?.onEscapePress?() }
        return true
    }

    private func handleRightCommand(isDown: Bool, logSuffix: String) -> Bool {
        if isDown && !rightCommandDown {
            rightCommandDown = true
            AppLog.debug("right command pressed\(logSuffix)", category: .hotkey)
            DispatchQueue.main.async { [weak self] in self?.onRightCommandPress?() }
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

    private func describe(_ status: StartStatus) -> String {
        switch status {
        case .ready:
            return "ready"
        case .listenDenied:
            return "listenDenied"
        case .fallback:
            return "fallback"
        case .failed:
            return "failed"
        }
    }
}
