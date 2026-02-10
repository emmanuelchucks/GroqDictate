import Cocoa

// MARK: - Floating HUD Panel

class FloatingPanel: NSPanel {
    let waveformView: WaveformView

    init() {
        waveformView = WaveformView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.nonactivatingPanel, .hudWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        contentView = waveformView
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.maxY - 140
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFront(nil)
    }

    func dismiss() {
        waveformView.stopAnimating()
        waveformView.setIdle()
        orderOut(nil)
    }
}

// MARK: - Waveform View

class WaveformView: NSView {
    enum DisplayState {
        case idle
        case recording
        case processing
        case error(String)
    }

    private(set) var displayState: DisplayState = .idle

    private var barHeights: [CGFloat] = Array(repeating: 0, count: 48)
    private let barCount = 48
    private var animTimer: Timer?

    private var processingProgress: CGFloat = 0
    private var processingForward = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    func setRecording() {
        displayState = .recording
        barHeights = Array(repeating: 0, count: barCount)
        startAnimating()
    }

    func setProcessing() {
        displayState = .processing
        processingProgress = 0
        processingForward = true
        startAnimating()
    }

    func setIdle() {
        displayState = .idle
        stopAnimating()
        barHeights = Array(repeating: 0, count: barCount)
        needsDisplay = true
    }

    func showError(_ message: String) {
        displayState = .error(message)
        stopAnimating()
        needsDisplay = true
    }

    func pushLevel(_ level: CGFloat) {
        guard case .recording = displayState else { return }
        barHeights.removeFirst()
        barHeights.append(level)
    }

    func startAnimating() {
        stopAnimating()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            guard let self = self else { return }
            if case .processing = self.displayState {
                if self.processingForward {
                    self.processingProgress += 0.015
                    if self.processingProgress >= 1.0 {
                        self.processingProgress = 1.0
                        self.processingForward = false
                    }
                } else {
                    self.processingProgress -= 0.015
                    if self.processingProgress <= 0 {
                        self.processingProgress = 0
                        self.processingForward = true
                    }
                }
            }
            self.needsDisplay = true
        }
    }

    func stopAnimating() {
        animTimer?.invalidate()
        animTimer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bounds = self.bounds
        ctx.clear(bounds)

        // Background
        ctx.setFillColor(NSColor(white: 0.08, alpha: 0.94).cgColor)
        let bgPath = CGPath(
            roundedRect: bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ctx.addPath(bgPath)
        ctx.fillPath()

        let waveArea = NSRect(
            x: 16, y: 30,
            width: bounds.width - 32, height: bounds.height - 46
        )

        switch displayState {
        case .idle:
            drawIdleLine(in: waveArea, ctx: ctx)
        case .recording:
            drawWaveformBars(in: waveArea, ctx: ctx)
        case .processing:
            drawProcessingAnimation(in: waveArea, ctx: ctx)
        case .error(let message):
            drawError(message, in: waveArea, ctx: ctx)
        }

        // Status label
        let statusText: String
        let statusColor: NSColor
        switch displayState {
        case .idle:
            statusText = ""
            statusColor = .clear
        case .recording:
            statusText = "● Recording"
            statusColor = .systemRed
        case .processing:
            statusText = "⟳ Transcribing…"
            statusColor = .systemOrange
        case .error:
            statusText = "⚠ Error"
            statusColor = .systemRed
        }

        if !statusText.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: statusColor,
            ]
            NSAttributedString(string: statusText, attributes: attrs)
                .draw(at: NSPoint(x: 16, y: 8))
        }

        // Esc hint
        if case .error = displayState {
            // no hint for errors
        } else {
            let hintAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor(white: 0.5, alpha: 1),
            ]
            let hint = NSAttributedString(string: "esc to cancel", attributes: hintAttrs)
            let hintSize = hint.size()
            hint.draw(at: NSPoint(x: bounds.width - hintSize.width - 16, y: 8))
        }
    }

    // MARK: - Drawing States

    private func drawIdleLine(in rect: NSRect, ctx: CGContext) {
        ctx.setStrokeColor(NSColor(white: 0.3, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: rect.minX, y: rect.midY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        ctx.strokePath()
    }

    private func drawWaveformBars(in rect: NSRect, ctx: CGContext) {
        let barWidth = rect.width / CGFloat(barCount)
        let barGap: CGFloat = 1.5
        let centerY = rect.midY

        for i in 0..<barCount {
            let h = barHeights[i]
            let barH = max(CGFloat(h) * rect.height, 2)
            let x = rect.minX + CGFloat(i) * barWidth
            let alpha = 0.5 + CGFloat(h) * 0.5

            ctx.setFillColor(NSColor(white: 1, alpha: alpha).cgColor)

            let barRect = CGRect(
                x: x + barGap / 2, y: centerY - barH / 2,
                width: barWidth - barGap, height: barH
            )
            let r = min((barWidth - barGap) / 2, barH / 2)
            ctx.addPath(
                CGPath(roundedRect: barRect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        }
    }

    private func drawProcessingAnimation(in rect: NSRect, ctx: CGContext) {
        let barWidth = rect.width / CGFloat(barCount)
        let barGap: CGFloat = 1.5
        let centerY = rect.midY

        for i in 0..<barCount {
            let x = rect.minX + CGFloat(i) * barWidth
            let barFraction = CGFloat(i) / CGFloat(barCount)

            let seed = sin(Double(i) * 1.7 + 0.5) * 0.5 + 0.5
            let barH = CGFloat(seed) * rect.height * 0.7 + rect.height * 0.1

            let lit = barFraction <= processingProgress
            let color: NSColor
            if lit {
                let shimmer = sin(Double(i) * 0.4 + processingProgress * 8) * 0.15 + 0.85
                color = NSColor(white: CGFloat(shimmer), alpha: 0.9)
            } else {
                color = NSColor(white: 0.25, alpha: 0.6)
            }

            ctx.setFillColor(color.cgColor)
            let barRect = CGRect(
                x: x + barGap / 2, y: centerY - barH / 2,
                width: barWidth - barGap, height: barH
            )
            let r = min((barWidth - barGap) / 2, barH / 2)
            ctx.addPath(
                CGPath(roundedRect: barRect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        }
    }

    private func drawError(_ message: String, in rect: NSRect, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.systemRed.withAlphaComponent(0.9),
        ]
        let str = NSAttributedString(string: message, attributes: attrs)
        let size = str.size()
        let x = rect.midX - size.width / 2
        let y = rect.midY - size.height / 2
        str.draw(at: NSPoint(x: x, y: y))
    }
}
