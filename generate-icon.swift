#!/usr/bin/env swift
// Generates GroqDictate app icon using Groq's brand colors
// Groq Orange: #EB3300 (PMS 2028C) — dark background with orange waveform
import Cocoa

let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext
let bounds = CGRect(x: 0, y: 0, width: size, height: size)

// Background: rounded squircle
let bgPath = CGPath(roundedRect: bounds.insetBy(dx: 40, dy: 40), cornerWidth: 200, cornerHeight: 200, transform: nil)
ctx.addPath(bgPath)
ctx.clip()

// Dark gradient background (near-black with slight warm tint)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1),
        CGColor(red: 0.10, green: 0.08, blue: 0.10, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Subtle warm glow behind the waveform
let centerY = CGFloat(size) * 0.5
let glowCenter = CGPoint(x: CGFloat(size) / 2, y: centerY)
let glowGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.92, green: 0.20, blue: 0.0, alpha: 0.12),
        CGColor(red: 0.92, green: 0.20, blue: 0.0, alpha: 0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(glowGradient, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: CGFloat(size) * 0.45, options: [])

// Draw waveform bars
let barCount = 28
let waveAreaX = CGFloat(size) * 0.15
let waveAreaWidth = CGFloat(size) * 0.7
let barWidth = waveAreaWidth / CGFloat(barCount)
let barGap: CGFloat = barWidth * 0.2
let maxBarHeight = CGFloat(size) * 0.4

// Speech-like waveform pattern
let pattern: [CGFloat] = [
    0.15, 0.25, 0.18, 0.45, 0.65, 0.85, 0.95, 1.0, 0.88, 0.72,
    0.55, 0.38, 0.50, 0.68, 0.82, 0.92, 0.98, 0.85, 0.70, 0.52,
    0.35, 0.48, 0.62, 0.45, 0.30, 0.20, 0.12, 0.08,
]

for i in 0..<barCount {
    let h = pattern[i]
    let barH = max(h * maxBarHeight, 8)
    let x = waveAreaX + CGFloat(i) * barWidth

    // Groq Orange gradient: brighter in the center, slightly darker at edges
    let t = CGFloat(i) / CGFloat(barCount)
    let intensity = 1.0 - abs(t - 0.5) * 0.6  // brightest in middle

    // Base: #EB3300 = RGB(235, 51, 0) → normalized (0.922, 0.200, 0.000)
    let r: CGFloat = 0.922 * intensity + 0.6 * (1 - intensity)
    let g: CGFloat = 0.200 * intensity + 0.08 * (1 - intensity)
    let b: CGFloat = 0.000 * intensity + 0.02 * (1 - intensity)

    ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 0.95))

    let barRect = CGRect(
        x: x + barGap / 2,
        y: centerY - barH / 2,
        width: barWidth - barGap,
        height: barH
    )
    let cornerRadius = min((barWidth - barGap) / 2, barH / 2)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(barPath)
    ctx.fillPath()
}

image.unlockFocus()

// Save as PNG
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    print("Failed to create PNG")
    exit(1)
}

let outputPath = "/tmp/groqdictate_icon_1024.png"
try! png.write(to: URL(fileURLWithPath: outputPath))
print("Icon saved to \(outputPath)")

// Generate iconset
let iconsetPath = "/tmp/GroqDictate.iconset"
try? FileManager.default.removeItem(atPath: iconsetPath)
try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512]
for s in sizes {
    let resized = NSImage(size: NSSize(width: s, height: s))
    resized.lockFocus()
    image.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    resized.unlockFocus()

    guard let tiff2 = resized.tiffRepresentation,
          let bmp2 = NSBitmapImageRep(data: tiff2),
          let png2 = bmp2.representation(using: .png, properties: [:]) else { continue }
    try! png2.write(to: URL(fileURLWithPath: "\(iconsetPath)/icon_\(s)x\(s).png"))

    let s2 = s * 2
    if s2 <= 1024 {
        let resized2 = NSImage(size: NSSize(width: s2, height: s2))
        resized2.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: s2, height: s2))
        resized2.unlockFocus()

        guard let tiff3 = resized2.tiffRepresentation,
              let bmp3 = NSBitmapImageRep(data: tiff3),
              let png3 = bmp3.representation(using: .png, properties: [:]) else { continue }
        try! png3.write(to: URL(fileURLWithPath: "\(iconsetPath)/icon_\(s)x\(s)@2x.png"))
    }
}

// Convert to icns
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetPath, "-o", "/Applications/GroqDictate.app/Contents/Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print("✅ Icon installed")
