import Cocoa

final class HotkeyMonitor {
    var onRightCommandPress: (() -> Void)?
    var onEscapePress: (() -> Void)?
    var shouldConsumeEscape: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rightCommandDown = false

    func start() {
        installEventTapOrFallback()
    }

    func stop() {
        removeAllMonitors()
    }

    private func installEventTapOrFallback() {
        removeAllMonitors()

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
            installNSEventFallback()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func installNSEventFallback() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleNSEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
    }

    private func removeAllMonitors() {
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
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown && keyCode == 53 {
            let shouldConsume = shouldConsumeEscape?() ?? false
            guard shouldConsume else {
                return Unmanaged.passUnretained(event)
            }

            DispatchQueue.main.async { [weak self] in self?.onEscapePress?() }
            return nil
        }

        if type == .flagsChanged && keyCode == 54 {
            let commandDown = event.flags.contains(.maskCommand)
            if commandDown && !rightCommandDown {
                rightCommandDown = true
                DispatchQueue.main.async { [weak self] in self?.onRightCommandPress?() }
                return nil
            }
            if !commandDown && rightCommandDown {
                rightCommandDown = false
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleNSEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {
            let shouldConsume = shouldConsumeEscape?() ?? false
            guard shouldConsume else { return }
            DispatchQueue.main.async { [weak self] in self?.onEscapePress?() }
            return
        }

        guard event.type == .flagsChanged else { return }
        let commandDown = event.modifierFlags.contains(.command)

        if commandDown && event.keyCode == 54 && !rightCommandDown {
            rightCommandDown = true
            DispatchQueue.main.async { [weak self] in self?.onRightCommandPress?() }
        } else if !commandDown && rightCommandDown {
            rightCommandDown = false
        }
    }
}
