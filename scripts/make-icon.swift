#!/usr/bin/env swift
//
// Renders the app icon (AppIcon.icns) from the same asterisk mark and colors
// the popover uses, so the icon never drifts from MenuView.Style.
//
//   swift scripts/make-icon.swift <output.icns>
//
import AppKit
import Foundation

// Mirrors MenuView.Style.background / .accent.
let base = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.21, alpha: 1)
let highlight = NSColor(srgbRed: 0.19, green: 0.19, blue: 0.30, alpha: 1)
let accent = NSColor(srgbRed: 0.85, green: 0.35, blue: 0.22, alpha: 1)

/// Apple's icon grid: on a 1024 canvas the artwork body is 824pt, leaving a
/// 100pt margin so the shape doesn't collide with neighbors in the Dock/Finder.
let bodyFraction: CGFloat = 824.0 / 1024.0
/// The macOS icon silhouette is a continuous-curvature rounded square. A
/// superellipse (|x|^n + |y|^n = 1, n ~= 5) is a close, cheap approximation --
/// and unlike a circular-corner roundRect it stays smooth at 1024pt.
func squircle(in rect: NSRect, exponent: CGFloat = 5, samples: Int = 720) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    for i in 0..<samples {
        let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(samples)
        let c = cos(t), s = sin(t)
        // Signed superellipse parameterization.
        let x = cx + a * copysign(pow(abs(c), 2 / exponent), c)
        let y = cy + b * copysign(pow(abs(s), 2 / exponent), s)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

/// The menu bar and popover both use SF Symbol "asterisk" at bold weight;
/// reusing it here keeps the icon and the running UI the same mark.
func asterisk(pointSize: CGFloat) -> NSImage? {
    guard let symbol = NSImage(systemSymbolName: "asterisk", accessibilityDescription: "Claude") else {
        return nil
    }
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
    guard let sized = symbol.withSymbolConfiguration(config) else { return nil }

    // Tint by compositing accent over the glyph's own alpha -- more reliable
    // across macOS versions than palette symbol configurations.
    let tinted = NSImage(size: sized.size)
    tinted.lockFocus()
    sized.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    accent.set()
    NSRect(origin: .zero, size: sized.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

func render(pixels: Int) -> Data? {
    let side = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let body = NSRect(
        x: side * (1 - bodyFraction) / 2,
        y: side * (1 - bodyFraction) / 2,
        width: side * bodyFraction,
        height: side * bodyFraction
    )

    let shape = squircle(in: body)
    NSGradient(starting: highlight, ending: base)?.draw(in: shape, angle: -90)

    // Glyph sized against the body, not the canvas, so the optical weight is
    // identical at every export size.
    if let glyph = asterisk(pointSize: body.width * 0.60) {
        let size = glyph.size
        let origin = NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2)
        glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Emit an .iconset and convert it

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "dist/AppIcon.icns"

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// (point size, scale) pairs iconutil expects.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]

for (points, scale) in variants {
    guard let png = render(pixels: points * scale) else {
        FileHandle.standardError.write(Data("failed to render \(points)@\(scale)x\n".utf8))
        exit(1)
    }
    let suffix = scale == 1 ? "" : "@\(scale)x"
    try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}

let outputURL = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }

try? FileManager.default.removeItem(at: iconset)
print("Wrote \(output)")
