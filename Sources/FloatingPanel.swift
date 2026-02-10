import Cocoa

// MARK: - Floating HUD Panel (Superwhisper-style)

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
        orderOut(nil)
    }
}

// MARK: - Waveform View (draws the live audio visualizer)

class WaveformView: NSView {
    enum DisplayState {
        case idle           // flat line
        case recording      // live waveform from mic levels
        case processing     // sweeping fill animation
    }

    private(set) var displayState: DisplayState = .idle

    // Waveform data: array of bar heights (0.0 to 1.0)
    private var barHeights: [CGFloat] = Array(repeating: 0, count: 48)
    private let barCount = 48
    private var displayLink: CVDisplayLink?
    private var animTimer: Timer?

    // Processing animation state
    private var processingProgress: CGFloat = 0
    private var processingForward = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

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

    /// Push a new audio level sample (0.0 to 1.0) while recording
    func pushLevel(_ level: CGFloat) {
        guard displayState == .recording else { return }
        // Shift bars left, add new on the right
        barHeights.removeFirst()
        barHeights.append(level)
    }

    func startAnimating() {
        stopAnimating()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            guard let self = self else { return }
            if self.displayState == .processing {
                // Sweep animation
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
        let bgPath = CGPath(roundedRect: bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
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
        }

        // Status text
        let statusText: String
        let statusColor: NSColor
        switch displayState {
        case .idle:
            statusText = ""
            statusColor = .clear
        case .recording:
            statusText = "● Recording"
            statusColor = NSColor.systemRed
        case .processing:
            statusText = "⟳ Transcribing..."
            statusColor = NSColor.systemOrange
        }

        if !statusText.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: statusColor,
            ]
            let str = NSAttributedString(string: statusText, attributes: attrs)
            str.draw(at: NSPoint(x: 16, y: 8))
        }

        // Esc hint
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(white: 0.5, alpha: 1),
        ]
        let hint = NSAttributedString(string: "esc to cancel", attributes: hintAttrs)
        let hintSize = hint.size()
        hint.draw(at: NSPoint(x: bounds.width - hintSize.width - 16, y: 8))
    }

    private func drawIdleLine(in rect: NSRect, ctx: CGContext) {
        ctx.setStrokeColor(NSColor(white: 0.3, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        let y = rect.midY
        ctx.move(to: CGPoint(x: rect.minX, y: y))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
        ctx.strokePath()
    }

    private func drawWaveformBars(in rect: NSRect, ctx: CGContext) {
        let barWidth: CGFloat = rect.width / CGFloat(barCount)
        let barGap: CGFloat = 1.5
        let maxBarHeight = rect.height
        let centerY = rect.midY

        for i in 0..<barCount {
            let h = barHeights[i]
            // Minimum visible bar height so it never fully disappears
            let barH = max(CGFloat(h) * maxBarHeight, 2)
            let x = rect.minX + CGFloat(i) * barWidth

            // Color: white with slight opacity variation based on height
            let alpha = 0.5 + CGFloat(h) * 0.5
            ctx.setFillColor(NSColor(white: 1, alpha: alpha).cgColor)

            let barRect = CGRect(
                x: x + barGap / 2,
                y: centerY - barH / 2,
                width: barWidth - barGap,
                height: barH
            )
            let barPath = CGPath(
                roundedRect: barRect,
                cornerWidth: (barWidth - barGap) / 2,
                cornerHeight: min(barH / 2, (barWidth - barGap) / 2),
                transform: nil
            )
            ctx.addPath(barPath)
            ctx.fillPath()
        }
    }

    private func drawProcessingAnimation(in rect: NSRect, ctx: CGContext) {
        let barWidth: CGFloat = rect.width / CGFloat(barCount)
        let barGap: CGFloat = 1.5
        let maxBarHeight = rect.height
        let centerY = rect.midY

        for i in 0..<barCount {
            let x = rect.minX + CGFloat(i) * barWidth
            let barFraction = CGFloat(i) / CGFloat(barCount)

            // Generate a pseudo-random but stable height for each bar
            let seed = sin(Double(i) * 1.7 + 0.5) * 0.5 + 0.5
            let barH = CGFloat(seed) * maxBarHeight * 0.7 + maxBarHeight * 0.1

            // Color fill progress: bars up to processingProgress are lit
            let lit = barFraction <= processingProgress
            let color: NSColor
            if lit {
                // White with slight shimmer
                let shimmer = sin(Double(i) * 0.4 + processingProgress * 8) * 0.15 + 0.85
                color = NSColor(white: CGFloat(shimmer), alpha: 0.9)
            } else {
                color = NSColor(white: 0.25, alpha: 0.6)
            }

            ctx.setFillColor(color.cgColor)
            let barRect = CGRect(
                x: x + barGap / 2,
                y: centerY - barH / 2,
                width: barWidth - barGap,
                height: barH
            )
            let barPath = CGPath(
                roundedRect: barRect,
                cornerWidth: (barWidth - barGap) / 2,
                cornerHeight: min(barH / 2, (barWidth - barGap) / 2),
                transform: nil
            )
            ctx.addPath(barPath)
            ctx.fillPath()
        }
    }
}
