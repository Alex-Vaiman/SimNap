#!/usr/bin/env swift
import AppKit

// Generates Resources/AppIcon.icns.
//
// The result is committed, so building the app does not depend on running
// this. Re-run it only to change the artwork:
//
//     swift Scripts/make-icon.swift
//
// Unlike the status-bar glyph, an app icon is not a template image, so this
// one can carry colour.

let root = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
} ?? ".")
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons sit on a rounded square inset from the canvas, with the
    // Big Sur corner radius of roughly 22.37% of the shape's width.
    let inset = size * 0.06
    let shape = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = shape.width * 0.2237
    let path = NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius)

    NSGradient(
        colors: [
            NSColor(srgbRed: 0.30, green: 0.56, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.11, green: 0.29, blue: 0.78, alpha: 1)
        ]
    )?.draw(in: path, angle: -90)

    // The same mark the status bar uses while offline, so the app and its
    // menu bar presence read as one thing.
    let glyphSize = shape.width * 0.56
    if let symbol = NSImage(
        systemSymbolName: "network.slash",
        accessibilityDescription: "SimNap"
    )?.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .medium)
    ) {
        // Tinted on its own transparent layer first. Filling `.sourceAtop`
        // straight onto the gradient would paint the whole rect, since every
        // pixel under it is already opaque.
        let white = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        white.draw(in: NSRect(
            x: shape.midX - symbol.size.width / 2,
            y: shape.midY - symbol.size.height / 2,
            width: symbol.size.width,
            height: symbol.size.height
        ))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// The set macOS expects; iconutil rejects an iconset missing any of them.
let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    let rep = drawIcon(size: variant.size)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

let icns = resources.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", icns.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
print("wrote \(icns.path)")
