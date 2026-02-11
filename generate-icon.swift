#!/usr/bin/env swift
import Cocoa
import Foundation

struct IconGenerator {
    let canvasSize: Int
    let outputDirectory: URL
    let appIconOutputURL: URL?

    private let iconsetName = "GroqDictate.iconset"

    func run() throws {
        let image = try makeBaseImage(size: canvasSize)
        let iconsetURL = outputDirectory.appendingPathComponent(iconsetName)

        try removeIfExists(iconsetURL)
        try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

        try writeIconset(from: image, to: iconsetURL)

        if let appIconOutputURL {
            try convertIconsetToICNS(iconsetURL: iconsetURL, outputURL: appIconOutputURL)
            print("✅ Icon installed at \(appIconOutputURL.path)")
        } else {
            print("✅ Iconset generated at \(iconsetURL.path)")
            print("Use: iconutil -c icns \"\(iconsetURL.path)\" -o /path/to/AppIcon.icns")
        }
    }

    private func makeBaseImage(size: Int) throws -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else {
            throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create graphics context"])
        }

        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let insetBounds = bounds.insetBy(dx: 40, dy: 40)

        context.addPath(CGPath(roundedRect: insetBounds, cornerWidth: 200, cornerHeight: 200, transform: nil))
        context.clip()

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let bgGradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    CGColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1),
                    CGColor(red: 0.10, green: 0.08, blue: 0.10, alpha: 1)
                ] as CFArray,
                locations: [0, 1]
            ),
            let glowGradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    CGColor(red: 0.92, green: 0.20, blue: 0.0, alpha: 0.12),
                    CGColor(red: 0.92, green: 0.20, blue: 0.0, alpha: 0)
                ] as CFArray,
                locations: [0, 1]
            )
        else {
            throw NSError(domain: "IconGenerator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create gradients"])
        }

        context.drawLinearGradient(
            bgGradient,
            start: CGPoint(x: 0, y: CGFloat(size)),
            end: CGPoint(x: 0, y: 0),
            options: []
        )

        let center = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        context.drawRadialGradient(
            glowGradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: CGFloat(size) * 0.45,
            options: []
        )

        drawWaveform(in: context, size: CGFloat(size))
        return image
    }

    private func drawWaveform(in context: CGContext, size: CGFloat) {
        let barCount = 28
        let waveAreaX = size * 0.15
        let waveAreaWidth = size * 0.7
        let barWidth = waveAreaWidth / CGFloat(barCount)
        let barGap = barWidth * 0.2
        let maxBarHeight = size * 0.4
        let centerY = size * 0.5

        let pattern: [CGFloat] = [
            0.15, 0.25, 0.18, 0.45, 0.65, 0.85, 0.95, 1.0, 0.88, 0.72,
            0.55, 0.38, 0.50, 0.68, 0.82, 0.92, 0.98, 0.85, 0.70, 0.52,
            0.35, 0.48, 0.62, 0.45, 0.30, 0.20, 0.12, 0.08
        ]

        for index in 0..<barCount {
            let height = max(pattern[index] * maxBarHeight, 8)
            let x = waveAreaX + CGFloat(index) * barWidth
            let t = CGFloat(index) / CGFloat(barCount)
            let intensity = 1.0 - abs(t - 0.5) * 0.6

            let red: CGFloat = 0.922 * intensity + 0.6 * (1 - intensity)
            let green: CGFloat = 0.200 * intensity + 0.08 * (1 - intensity)
            let blue: CGFloat = 0.000 * intensity + 0.02 * (1 - intensity)

            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 0.95))

            let rect = CGRect(
                x: x + barGap / 2,
                y: centerY - height / 2,
                width: barWidth - barGap,
                height: height
            )
            let corner = min((barWidth - barGap) / 2, height / 2)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
            context.fillPath()
        }
    }

    private func writeIconset(from image: NSImage, to iconsetURL: URL) throws {
        let sizes = [16, 32, 64, 128, 256, 512]
        for size in sizes {
            try writeResizedPNG(from: image, size: size, to: iconsetURL.appendingPathComponent("icon_\(size)x\(size).png"))

            let retina = size * 2
            if retina <= 1024 {
                try writeResizedPNG(from: image, size: retina, to: iconsetURL.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
            }
        }
    }

    private func writeResizedPNG(from image: NSImage, size: Int, to url: URL) throws {
        let resized = NSImage(size: NSSize(width: size, height: size))
        resized.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        resized.unlockFocus()

        guard
            let tiff = resized.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw NSError(domain: "IconGenerator", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to render PNG for \(size)x\(size)"])
        }

        try png.write(to: url)
    }

    private func convertIconsetToICNS(iconsetURL: URL, outputURL: URL) throws {
        try removeIfExists(outputURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "IconGenerator", code: 4, userInfo: [NSLocalizedDescriptionKey: "iconutil failed with status \(process.terminationStatus)"])
        }
    }

    private func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

func parseArguments() -> (Int, URL, URL?) {
    let args = CommandLine.arguments

    let size = args.dropFirst().first.flatMap(Int.init) ?? 1024
    let outputDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)

    let appIconPath = "/Applications/GroqDictate.app/Contents/Resources/AppIcon.icns"
    let appIconURL = FileManager.default.fileExists(atPath: "/Applications/GroqDictate.app")
        ? URL(fileURLWithPath: appIconPath)
        : nil

    return (size, outputDirectory, appIconURL)
}

do {
    let (size, outputDirectory, appIconURL) = parseArguments()
    let generator = IconGenerator(canvasSize: size, outputDirectory: outputDirectory, appIconOutputURL: appIconURL)
    try generator.run()
} catch {
    fputs("❌ \(error.localizedDescription)\n", stderr)
    exit(1)
}
