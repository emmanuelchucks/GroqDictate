import Cocoa

/// Settings window: API key, mic selection, model, input gain.
class SetupWindow: NSWindow, NSWindowDelegate {
    private let apiKeyField = NSTextField()
    private let micPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let gainSlider = NSSlider()
    private let gainLabel = NSTextField(labelWithString: "5.0x")
    private let statusLabel = NSTextField(labelWithString: "")
    var onComplete: (() -> Void)?
    private var previousApp: NSRunningApplication?

    init(previousApp: NSRunningApplication? = nil) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "GroqDictate Settings"
        isReleasedWhenClosed = false
        delegate = self
        self.previousApp = previousApp
        buildUI()
        center()
    }

    private func buildUI() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        contentView = container

        var y: CGFloat = 320

        // --- API Key ---
        addLabel("Groq API Key", at: &y, in: container, bold: true)
        y -= 4

        apiKeyField.frame = NSRect(x: 24, y: y, width: 412, height: 22)
        apiKeyField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        apiKeyField.placeholderString = "gsk_..."
        apiKeyField.usesSingleLineMode = true
        apiKeyField.lineBreakMode = .byTruncatingTail
        apiKeyField.cell?.wraps = false
        apiKeyField.cell?.isScrollable = true
        if let existing = KeychainHelper.load(key: "groq-api-key") {
            apiKeyField.stringValue = existing
        }
        container.addSubview(apiKeyField)
        y -= 16

        let hint = NSTextField(labelWithString: "Free from console.groq.com → Stored in Keychain")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = NSColor.tertiaryLabelColor
        hint.frame = NSRect(x: 24, y: y, width: 412, height: 14)
        container.addSubview(hint)
        y -= 28

        // --- Model ---
        addLabel("Model", at: &y, in: container, bold: true)
        y -= 4

        modelPopup.frame = NSRect(x: 24, y: y, width: 412, height: 26)
        let models = [
            ("whisper-large-v3-turbo", "Whisper Large V3 Turbo (fastest)"),
            ("whisper-large-v3", "Whisper Large V3 (most accurate)"),
        ]
        let savedModel =
            UserDefaults.standard.string(forKey: "groq-model") ?? "whisper-large-v3-turbo"
        for (i, (id, name)) in models.enumerated() {
            modelPopup.addItem(withTitle: name)
            modelPopup.item(at: i)?.representedObject = id
            if id == savedModel { modelPopup.selectItem(at: i) }
        }
        container.addSubview(modelPopup)
        y -= 34

        // --- Microphone ---
        addLabel("Microphone", at: &y, in: container, bold: true)
        y -= 4

        micPopup.frame = NSRect(x: 24, y: y, width: 412, height: 26)

        // Add "System Default" option first
        micPopup.addItem(withTitle: "System Default")
        micPopup.item(at: 0)?.representedObject = "__system_default__"

        let devices = AudioRecorder.availableInputDevices()
        let savedMic = UserDefaults.standard.string(forKey: "mic-uid") ?? ""

        var selectedIndex = 0  // default to System Default
        for device in devices {
            // Filter out macOS internal aggregate devices
            if device.uid.contains("CADefaultDeviceAggregate") { continue }
            if device.name.contains("CADefaultDevice") { continue }

            let idx = micPopup.numberOfItems
            micPopup.addItem(withTitle: device.name)
            micPopup.item(at: idx)?.representedObject = device.uid

            if device.uid == savedMic {
                selectedIndex = idx
            } else if savedMic.isEmpty && device.name.contains("External") {
                selectedIndex = idx
            }
        }
        micPopup.selectItem(at: selectedIndex)
        container.addSubview(micPopup)
        y -= 34

        // --- Input Gain ---
        addLabel("Input Gain", at: &y, in: container, bold: true)
        y -= 4

        let savedGain = UserDefaults.standard.float(forKey: "input-gain")
        let currentGain = savedGain > 0 ? savedGain : 5.0  // default to max

        gainSlider.frame = NSRect(x: 24, y: y, width: 346, height: 22)
        gainSlider.minValue = 1.0
        gainSlider.maxValue = 5.0
        gainSlider.doubleValue = Double(currentGain)
        gainSlider.target = self
        gainSlider.action = #selector(gainChanged)
        container.addSubview(gainSlider)

        gainLabel.frame = NSRect(x: 378, y: y, width: 60, height: 22)
        gainLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        gainLabel.stringValue = String(format: "%.1fx", currentGain)
        container.addSubview(gainLabel)
        y -= 36

        // --- Status + Save ---
        statusLabel.frame = NSRect(x: 24, y: 20, width: 280, height: 20)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        container.addSubview(statusLabel)

        let saveButton = NSButton(title: "Done", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 336, y: 14, width: 104, height: 32)
        container.addSubview(saveButton)
    }

    private func addLabel(
        _ text: String, at y: inout CGFloat, in container: NSView, bold: Bool
    ) {
        let label = NSTextField(labelWithString: text)
        label.font =
            bold
            ? NSFont.systemFont(ofSize: 13, weight: .semibold)
            : NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.frame = NSRect(x: 24, y: y, width: 412, height: 18)
        container.addSubview(label)
        y -= 20
    }

    @objc private func gainChanged() {
        gainLabel.stringValue = String(format: "%.1fx", gainSlider.doubleValue)
    }

    @objc private func save() {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !key.isEmpty else {
            showStatus("API key cannot be empty.", error: true)
            return
        }
        guard key.hasPrefix("gsk_") else {
            showStatus("Invalid key — should start with gsk_", error: true)
            return
        }

        do { try Config.saveAPIKey(key) } catch {
            showStatus("Keychain error: \(error.localizedDescription)", error: true)
            return
        }

        // Save model
        if let modelID = modelPopup.selectedItem?.representedObject as? String {
            UserDefaults.standard.set(modelID, forKey: "groq-model")
        }

        // Save mic
        if let uid = micPopup.selectedItem?.representedObject as? String {
            UserDefaults.standard.set(uid == "__system_default__" ? "" : uid, forKey: "mic-uid")
        }

        // Save gain
        UserDefaults.standard.set(Float(gainSlider.doubleValue), forKey: "input-gain")

        close()
        previousApp?.activate()
        onComplete?()
    }

    private func showStatus(_ text: String, error: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : NSColor.secondaryLabelColor
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Return focus to the previously active app when closed via X button
        previousApp?.activate()
    }
}
