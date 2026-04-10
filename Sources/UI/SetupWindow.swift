import Cocoa

final class SetupWindow: NSWindow, NSWindowDelegate {
    private static let systemDefaultMicToken = "__system_default__"
    private static let contentWidth: CGFloat = 460
    private static let contentHeight: CGFloat = 360

    private let configurationController: SetupConfigurationController
    private let initialState: SetupConfigurationState
    private let apiKeyField = NSSecureTextField()
    private let micPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let gainSlider = NSSlider()
    private let gainLabel = NSTextField(labelWithString: "2.0x")
    private let statusLabel = NSTextField(labelWithString: "")

    var onSave: (() -> Void)?
    var onClose: ((Bool) -> Void)?

    private var didSave = false

    init(configurationController: SetupConfigurationController = SetupConfigurationController()) {
        self.configurationController = configurationController
        self.initialState = configurationController.makeState()
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.contentHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = AppStrings.Setup.title
        isReleasedWhenClosed = false
        setContentSize(NSSize(width: Self.contentWidth, height: Self.contentHeight))
        delegate = self
        buildUI()
        center()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        contentView?.window?.makeFirstResponder(apiKeyField)
    }

    private func buildUI() {
        let container = NSView()
        contentView = container

        apiKeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        apiKeyField.placeholderString = "gsk_..."
        apiKeyField.usesSingleLineMode = true
        apiKeyField.lineBreakMode = .byTruncatingTail
        apiKeyField.cell?.wraps = false
        apiKeyField.cell?.isScrollable = true
        apiKeyField.stringValue = initialState.existingAPIKey

        let hint = NSTextField(labelWithString: AppStrings.Setup.keyHint)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor

        for (index, model) in initialState.modelOptions.enumerated() {
            modelPopup.addItem(withTitle: model.title)
            modelPopup.item(at: index)?.representedObject = model.id
            if model.id == initialState.selectedModelID { modelPopup.selectItem(at: index) }
        }

        micPopup.addItem(withTitle: AppStrings.Setup.systemDefaultMic)
        micPopup.item(at: 0)?.representedObject = Self.systemDefaultMicToken

        var selectedIndex = 0
        for option in initialState.microphoneOptions {
            let idx = micPopup.numberOfItems
            micPopup.addItem(withTitle: option.title)
            micPopup.item(at: idx)?.representedObject = option.id
            if option.id == initialState.selectedMicrophoneID { selectedIndex = idx }
        }
        micPopup.selectItem(at: selectedIndex)

        let currentGain = initialState.inputGain

        gainSlider.minValue = 1.0
        gainSlider.maxValue = 5.0
        gainSlider.doubleValue = Double(currentGain)
        gainSlider.target = self
        gainSlider.action = #selector(gainChanged)

        gainLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        gainLabel.stringValue = String(format: "%.1fx", currentGain)
        statusLabel.font = .systemFont(ofSize: 11)

        let doneButton = NSButton(title: AppStrings.Setup.done, target: self, action: #selector(save))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.setContentHuggingPriority(.required, for: .horizontal)
        doneButton.widthAnchor.constraint(equalToConstant: 104).isActive = true

        let gainRow = NSStackView(views: [gainSlider, gainLabel])
        gainRow.orientation = .horizontal
        gainRow.alignment = .centerY
        gainRow.spacing = 8
        gainLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footerRow = NSStackView(views: [statusLabel, spacer, doneButton])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 12

        let filler = NSView()
        filler.setContentHuggingPriority(.defaultLow, for: .vertical)
        filler.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let rootStack = NSStackView(views: [
            makeSection(
                title: AppStrings.Setup.apiKeyLabel,
                views: [apiKeyField, hint]
            ),
            makeSection(title: AppStrings.Setup.modelLabel, views: [modelPopup]),
            makeSection(title: AppStrings.Setup.micLabel, views: [micPopup]),
            makeSection(title: AppStrings.Setup.inputGainLabel, views: [gainRow]),
            filler,
            footerRow
        ])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 16
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(rootStack)

        for arrangedSubview in rootStack.arrangedSubviews {
            arrangedSubview.translatesAutoresizingMaskIntoConstraints = false
            arrangedSubview.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            rootStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            rootStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
    }

    private func makeSection(title: String, views: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor

        let stack = NSStackView(views: [label] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return stack
    }

    @objc private func gainChanged() {
        gainLabel.stringValue = String(format: "%.1fx", gainSlider.doubleValue)
    }

    @objc private func save() {
        let request = SetupSaveRequest(
            apiKey: apiKeyField.stringValue,
            selectedModelID: (modelPopup.selectedItem?.representedObject as? String) ?? Config.DefaultValue.model,
            selectedMicrophoneID: (micPopup.selectedItem?.representedObject as? String).flatMap {
                $0 == Self.systemDefaultMicToken ? nil : $0
            },
            inputGain: Float(gainSlider.doubleValue)
        )

        switch configurationController.save(request) {
        case .success:
            didSave = true
            close()
        case .failure(.emptyAPIKey):
            showStatus(AppStrings.Setup.keyEmpty, isError: true)
        case .failure(.invalidAPIKey):
            showStatus(AppStrings.Setup.keyInvalid, isError: true)
        case .failure(.keychainFailure(let message)):
            showStatus(AppStrings.Setup.keychainError(message), isError: true)
        }
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
