import Cocoa
import QuartzCore

final class FloatingPanel: NSPanel {
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isExcludedFromWindowsMenu = true
        contentView = waveformView
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let x = screen.visibleFrame.midX - frame.width / 2
        let y = screen.visibleFrame.maxY - 140
        setFrameOrigin(NSPoint(x: x, y: y))
        alphaValue = 1
        orderFront(nil)
    }

    func dismiss() {
        waveformView.stopAnimating()
        waveformView.setIdle()
        orderOut(nil)
    }
}

final class WaveformView: NSView {
    enum ErrorAction {
        case retry
        case newRecording
        case settings
        case dismissOnly
    }

    private enum DisplayState {
        case idle
        case recording
        case processing
        case notice(String)
        case error(String, ErrorAction)
    }

    private var displayState: DisplayState = .idle
    private let barCount = 48
    private var barHeights: [CGFloat] = Array(repeating: 0, count: 48)
    private var barWriteHead = 0

    private var animationDisplayLink: CADisplayLink?
    private var lastTickTime: CFTimeInterval?

    private var frameCount = 0
    private var lateFrameCount = 0
    private var maxFrameGapMs: Double = 0
    private var activeAnimationState: DisplayState = .idle

    private let processingSpeedPerSecond: CGFloat = 0.66
    private var processingProgress: CGFloat = 0
    private var processingForward = true
    private weak var levelSource: AudioRecorder?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setRecording(levelSource: AudioRecorder) {
        self.levelSource = levelSource
        displayState = .recording
        barHeights = Array(repeating: 0, count: barCount)
        barWriteHead = 0
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
        barWriteHead = 0
        needsDisplay = true
    }

    func showNotice(_ message: String) {
        displayState = .notice(message)
        stopAnimating()
        needsDisplay = true
    }

    func showError(_ message: String, action: ErrorAction) {
        displayState = .error(message, action)
        stopAnimating()
        needsDisplay = true
    }

    func startAnimating() {
        stopAnimating()

        frameCount = 0
        lateFrameCount = 0
        maxFrameGapMs = 0
        lastTickTime = nil
        activeAnimationState = displayState

        let link = displayLink(target: self, selector: #selector(handleDisplayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        animationDisplayLink = link
    }

    func stopAnimating() {
        if frameCount > 0 {
            AppLog.debug(
                String(
                    format: "animation summary state=%@ frames=%d late=%d max_gap=%.1fms",
                    describe(activeAnimationState),
                    frameCount,
                    lateFrameCount,
                    maxFrameGapMs
                ),
                category: .animation
            )
        }

        animationDisplayLink?.invalidate()
        animationDisplayLink = nil
        lastTickTime = nil
        frameCount = 0
        lateFrameCount = 0
        maxFrameGapMs = 0
        activeAnimationState = .idle
    }

    @objc private func handleDisplayLinkTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt: CFTimeInterval

        if let lastTickTime {
            dt = max(0, min(now - lastTickTime, 0.2))
        } else {
            dt = 1.0 / 60.0
        }

        self.lastTickTime = now
        frameCount += 1

        let dtMs = dt * 1000
        maxFrameGapMs = max(maxFrameGapMs, dtMs)
        if dtMs > 40 {
            lateFrameCount += 1
        }
        if dtMs > 120 {
            AppLog.debug(
                String(format: "animation gap state=%@ dt=%.1fms", describe(displayState), dtMs),
                category: .animation
            )
        }

        switch displayState {
        case .recording:
            barHeights[barWriteHead] = CGFloat(levelSource?.currentLevel ?? 0)
            barWriteHead = (barWriteHead + 1) % barCount
        case .processing:
            let delta = processingSpeedPerSecond * CGFloat(dt)
            processingProgress += processingForward ? delta : -delta

            if processingProgress >= 1 {
                processingProgress = 1
                processingForward = false
            } else if processingProgress <= 0 {
                processingProgress = 0
                processingForward = true
            }
        case .idle, .notice, .error:
            break
        }

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        ctx.clear(bounds)

        ctx.setFillColor(NSColor(white: 0.08, alpha: 0.94).cgColor)
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.fillPath()

        let topRect = NSRect(x: 16, y: 30, width: bounds.width - 32, height: bounds.height - 46)

        switch displayState {
        case .idle:
            drawCenterLine(in: topRect, ctx: ctx)
        case .recording:
            drawBars(in: topRect, ctx: ctx)
        case .processing:
            drawProcessing(in: topRect, ctx: ctx)
        case .notice(let message):
            drawNoticeText(message, in: topRect)
        case .error(let message, _):
            drawErrorText(message, in: topRect)
        }

        drawStatusLabels(in: bounds)
    }

    private func drawStatusLabels(in bounds: NSRect) {
        let y: CGFloat = 8

        switch displayState {
        case .idle:
            break
        case .recording:
            drawLabel(AppStrings.Panel.recording, color: .systemRed, at: NSPoint(x: 16, y: y))
            drawHint(AppStrings.Panel.escCancel, in: bounds, y: y)
        case .processing:
            drawLabel(AppStrings.Panel.transcribing, color: .systemOrange, at: NSPoint(x: 16, y: y))
            drawHint(AppStrings.Panel.escCancel, in: bounds, y: y)
        case .notice:
            drawHint(AppStrings.Panel.escDismiss, in: bounds, y: y)
        case .error(_, let action):
            let actionLabel: String? = switch action {
            case .retry: AppStrings.Panel.retry
            case .newRecording: AppStrings.Panel.newRecording
            case .settings: AppStrings.Panel.settings
            case .dismissOnly: nil
            }

            if let actionLabel {
                drawLabel(actionLabel, color: .secondaryLabelColor, at: NSPoint(x: 16, y: y))
            }
            drawHint(AppStrings.Panel.escDismiss, in: bounds, y: y)
        }
    }

    private func drawLabel(_ text: String, color: NSColor, at point: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color
        ]
        NSAttributedString(string: text, attributes: attrs).draw(at: point)
    }

    private func drawHint(_ text: String, in bounds: NSRect, y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor(white: 0.5, alpha: 1)
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        string.draw(at: NSPoint(x: bounds.width - string.size().width - 16, y: y))
    }

    private func drawCenterLine(in rect: NSRect, ctx: CGContext) {
        ctx.setStrokeColor(NSColor(white: 0.3, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: rect.minX, y: rect.midY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        ctx.strokePath()
    }

    private func drawBars(in rect: NSRect, ctx: CGContext) {
        let width = rect.width / CGFloat(barCount)
        let gap: CGFloat = 1.5

        for i in 0..<barCount {
            let index = (barWriteHead + i) % barCount
            let heightScale = barHeights[index]
            let barHeight = max(heightScale * rect.height, 2)
            let x = rect.minX + CGFloat(i) * width
            let alpha = 0.5 + heightScale * 0.5
            ctx.setFillColor(NSColor(white: 1, alpha: alpha).cgColor)

            let barRect = CGRect(x: x + gap / 2, y: rect.midY - barHeight / 2, width: width - gap, height: barHeight)
            let corner = min((width - gap) / 2, barHeight / 2)
            ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.fillPath()
        }
    }

    private func drawProcessing(in rect: NSRect, ctx: CGContext) {
        let width = rect.width / CGFloat(barCount)
        let gap: CGFloat = 1.5

        for i in 0..<barCount {
            let frac = CGFloat(i) / CGFloat(barCount)
            let seed = sin(Double(i) * 1.7 + 0.5) * 0.5 + 0.5
            let barHeight = CGFloat(seed) * rect.height * 0.7 + rect.height * 0.1
            let lit = frac <= processingProgress
            let brightness: CGFloat = lit
                ? CGFloat(sin(Double(i) * 0.4 + processingProgress * 8.0) * 0.15 + 0.85)
                : 0.25
            let alpha: CGFloat = lit ? 0.9 : 0.6

            ctx.setFillColor(NSColor(white: brightness, alpha: alpha).cgColor)
            let x = rect.minX + CGFloat(i) * width
            let barRect = CGRect(x: x + gap / 2, y: rect.midY - barHeight / 2, width: width - gap, height: barHeight)
            let corner = min((width - gap) / 2, barHeight / 2)
            ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.fillPath()
        }
    }

    private func drawNoticeText(_ message: String, in rect: NSRect) {
        drawCenteredText(message, color: .secondaryLabelColor, in: rect)
    }

    private func drawErrorText(_ message: String, in rect: NSRect) {
        drawCenteredText("⚠ \(message)", color: .systemOrange, in: rect)
    }

    private func drawCenteredText(_ text: String, color: NSColor, in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let size = string.size()
        string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func describe(_ state: DisplayState) -> String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .processing: return "processing"
        case .notice: return "notice"
        case .error: return "error"
        }
    }
}
