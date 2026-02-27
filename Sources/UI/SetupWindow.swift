import Cocoa

final class SetupWindow: NSWindow, NSWindowDelegate {
    private static let systemDefaultMicToken = "__system_default__"

    private let apiKeyField = NSSecureTextField()
    private let micPopup = NSPopUpButton()
    private let gainSlider = NSSlider()
    private let gainLabel = NSTextField(labelWithString: "5.0x")
    private let statusLabel = NSTextField(labelWithString: "")

    var onSave: (() -> Void)?
    var onClose: ((Bool) -> Void)?

    private var didSave = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = AppStrings.Setup.title
        isReleasedWhenClosed = false
        delegate = self
        buildUI()
        center()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        contentView?.window?.makeFirstResponder(apiKeyField)
    }

    private func buildUI() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
        contentView = container

        var y: CGFloat = 280

        addLabel(AppStrings.Setup.apiKeyLabel, at: &y, in: container, bold: true)
        y -= 4
        apiKeyField.frame = NSRect(x: 24, y: y, width: 412, height: 22)
        apiKeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        apiKeyField.placeholderString = "sk-..."
        apiKeyField.usesSingleLineMode = true
        apiKeyField.lineBreakMode = .byTruncatingTail
        apiKeyField.cell?.wraps = false
        apiKeyField.cell?.isScrollable = true
        if let existing = KeychainHelper.load(key: Config.KeychainKey.apiKey) {
            apiKeyField.stringValue = existing
        }
        container.addSubview(apiKeyField)
        y -= 16

        let hint = NSTextField(labelWithString: AppStrings.Setup.keyHint)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 24, y: y, width: 412, height: 14)
        container.addSubview(hint)
        y -= 28

        addLabel(AppStrings.Setup.micLabel, at: &y, in: container, bold: true)
        y -= 4
        micPopup.frame = NSRect(x: 24, y: y, width: 412, height: 26)
        micPopup.addItem(withTitle: AppStrings.Setup.systemDefaultMic)
        micPopup.item(at: 0)?.representedObject = Self.systemDefaultMicToken

        let savedMic = UserDefaults.standard.string(forKey: Config.DefaultsKey.micUID) ?? ""
        var selectedIndex = 0
        for device in AudioRecorder.availableInputDevices() {
            if device.uid.contains("CADefaultDeviceAggregate") || device.name.contains("CADefaultDevice") {
                continue
            }
            let idx = micPopup.numberOfItems
            micPopup.addItem(withTitle: device.name)
            micPopup.item(at: idx)?.representedObject = device.uid
            if device.uid == savedMic { selectedIndex = idx }
        }
        micPopup.selectItem(at: selectedIndex)
        container.addSubview(micPopup)
        y -= 34

        addLabel(AppStrings.Setup.inputGainLabel, at: &y, in: container, bold: true)
        y -= 4

        let savedGain = UserDefaults.standard.float(forKey: Config.DefaultsKey.inputGain)
        let currentGain = savedGain > 0 ? savedGain : Config.DefaultValue.inputGain

        gainSlider.frame = NSRect(x: 24, y: y, width: 346, height: 22)
        gainSlider.minValue = 1.0
        gainSlider.maxValue = 5.0
        gainSlider.doubleValue = Double(currentGain)
        gainSlider.target = self
        gainSlider.action = #selector(gainChanged)
        container.addSubview(gainSlider)

        gainLabel.frame = NSRect(x: 378, y: y, width: 60, height: 22)
        gainLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        gainLabel.stringValue = String(format: "%.1fx", currentGain)
        container.addSubview(gainLabel)

        statusLabel.frame = NSRect(x: 24, y: 20, width: 280, height: 20)
        statusLabel.font = .systemFont(ofSize: 11)
        container.addSubview(statusLabel)

        let doneButton = NSButton(title: AppStrings.Setup.done, target: self, action: #selector(save))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.frame = NSRect(x: 336, y: 14, width: 104, height: 32)
        container.addSubview(doneButton)
    }

    private func addLabel(_ text: String, at y: inout CGFloat, in container: NSView, bold: Bool) {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
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
            showStatus(AppStrings.Setup.keyEmpty, isError: true)
            return
        }

        do {
            try Config.saveAPIKey(key)
        } catch {
            showStatus(AppStrings.Setup.keychainError(error.localizedDescription), isError: true)
            return
        }

        let selectedMicUID = (micPopup.selectedItem?.representedObject as? String).flatMap { $0 == Self.systemDefaultMicToken ? nil : $0 }
        Config.savePreferences(micUID: selectedMicUID, inputGain: Float(gainSlider.doubleValue))

        didSave = true
        close()
    }

    private func showStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    func windowWillClose(_ notification: Notification) {
        if didSave { onSave?() }
        onClose?(didSave)
    }
}
