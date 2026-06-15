#!/usr/bin/env swift
//
//  make_appicon.swift
//  WhisprSoft — reproducible app-icon generator
//
//  Renders a 1024×1024 master (indigo→violet gradient rounded square with a
//  white vertical-bar waveform echoing the menu glyph), then downscales it to
//  the macOS icon sizes and writes the PNGs into the AppIcon.appiconset.
//
//  Kept at repo root under Tools/ — OUTSIDE the WhisprSoft/ synchronized source
//  group — so it is never compiled into the app. Re-run after a design change:
//
//      swift Tools/make_appicon.swift
//
//  Uses CoreGraphics/AppKit (both present with the Xcode toolchain).
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Output location

let fm = FileManager.default
let scriptPath = URL(fileURLWithPath: CommandLine.arguments[0])
// repoRoot/Tools/make_appicon.swift → repoRoot
let repoRoot = scriptPath.deletingLastPathComponent().deletingLastPathComponent()
let outDir = repoRoot
    .appendingPathComponent("WhisprSoft")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

guard fm.fileExists(atPath: outDir.path) else {
    FileHandle.standardError.write("AppIcon.appiconset not found at \(outDir.path)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Colors

func srgb(_ hex: UInt32) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255.0
    let g = CGFloat((hex >> 8) & 0xFF) / 255.0
    let b = CGFloat(hex & 0xFF) / 255.0
    return CGColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
}

let indigo = srgb(0x4F46E5)   // gradient stop 0.0 (top-left)
let violet = srgb(0x9333EA)   // gradient stop 1.0 (bottom-right)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

// MARK: - Master render (1024×1024)

let masterSize = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

guard let ctx = CGContext(
    data: nil,
    width: masterSize,
    height: masterSize,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("Failed to create master CGContext\n".data(using: .utf8)!)
    exit(1)
}

// Transparent background (context starts cleared).

// Rounded-square background: 824×824 centered, corner radius 186.
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

// Diagonal linear gradient: indigo at top-left → violet at bottom-right.
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [indigo, violet] as CFArray,
    locations: [0.0, 1.0]
)!
// CoreGraphics origin is bottom-left → top-left corner is (minX, maxY),
// bottom-right is (maxX, minY).
let startPoint = CGPoint(x: bgRect.minX, y: bgRect.maxY)
let endPoint = CGPoint(x: bgRect.maxX, y: bgRect.minY)
ctx.drawLinearGradient(gradient, start: startPoint, end: endPoint, options: [])
ctx.restoreGState()

// Waveform: 5 white vertical capsule bars, group centered on (512, 512).
let barWidth: CGFloat = 90
let gap: CGFloat = 56
let radius: CGFloat = 45
let heights: [CGFloat] = [319, 580, 418, 580, 319]
let groupLeft: CGFloat = 175   // (512 - 674/2)

ctx.setFillColor(white)
for (i, h) in heights.enumerated() {
    let x = groupLeft + CGFloat(i) * (barWidth + gap)
    let y = 512 - h / 2
    let barRect = CGRect(x: x, y: y, width: barWidth, height: h)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(barPath)
    ctx.fillPath()
}

guard let masterImage = ctx.makeImage() else {
    FileHandle.standardError.write("Failed to make master image\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - PNG export helpers

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("PNG encode failed for \(url.lastPathComponent)\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        try data.write(to: url)
    } catch {
        FileHandle.standardError.write("Write failed for \(url.lastPathComponent): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Downscale the master to an exact square size, preserving alpha.
func scaled(_ source: CGImage, to size: Int) -> CGImage {
    guard let sctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        FileHandle.standardError.write("Failed to create scale context for \(size)\n".data(using: .utf8)!)
        exit(1)
    }
    sctx.interpolationQuality = .high
    sctx.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let out = sctx.makeImage() else {
        FileHandle.standardError.write("Failed to scale to \(size)\n".data(using: .utf8)!)
        exit(1)
    }
    return out
}

// MARK: - Emit all sizes

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    let image = (size == masterSize) ? masterImage : scaled(masterImage, to: size)
    let url = outDir.appendingPathComponent("icon_\(size).png")
    writePNG(image, to: url)
    print("wrote icon_\(size).png (\(image.width)×\(image.height))")
}

print("Done → \(outDir.path)")
