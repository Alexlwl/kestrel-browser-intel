#!/usr/bin/env swift
// Draw the Kestrel app icon and pack an .icns — CoreGraphics only, no rasterizer.
//
// Why not SVG + qlmanage: QuickLook renders an SVG onto an OPAQUE WHITE canvas,
// so the area outside the rounded square came out solid white and the icon grew
// a white border in the Dock and in Finder. Drawing directly with CoreGraphics
// keeps every pixel outside the rounded square fully transparent.
//
// Layout follows Apple's macOS icon grid: a 1024pt canvas with an 824pt rounded
// square centred in it (100pt padding) and a 185pt corner radius.
//
// Usage: swift tools/make_icon.swift AppIcon.icns

import AppKit
import CoreGraphics

let canvas: CGFloat = 1024
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185

func makeContext(_ px: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("cannot create bitmap context")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let s = CGFloat(px) / canvas
    ctx.scaleBy(x: s, y: s)
    return ctx
}

func platePath() -> CGPath {
    CGPath(roundedRect: plate, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
           transform: nil)
}

/// The kestrel mark: a downward chevron/arrowhead, white.
func markPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 512, y: 268))
    p.addLine(to: CGPoint(x: 756, y: 782))
    p.addLine(to: CGPoint(x: 512, y: 638))
    p.addLine(to: CGPoint(x: 268, y: 782))
    p.closeSubpath()
    return p
}

func drawIcon(_ ctx: CGContext) {
    let clip = platePath()

    // 1. Plate fill: vertical gradient, light at the top — reads as glass, not a flat slab.
    ctx.saveGState()
    ctx.addPath(clip)
    ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.235, green: 0.259, blue: 0.310, alpha: 1.0),   // #3C424F
        CGColor(red: 0.118, green: 0.133, blue: 0.165, alpha: 1.0),   // #1E222A
        CGColor(red: 0.047, green: 0.055, blue: 0.071, alpha: 1.0),   // #0C0E12
    ] as CFArray, locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 512, y: plate.maxY),
                           end: CGPoint(x: 512, y: plate.minY),
                           options: [])

    // 2. Soft top highlight, so the plate looks lit from above.
    let gloss = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.085),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(gloss,
                           start: CGPoint(x: 512, y: plate.maxY),
                           end: CGPoint(x: 512, y: plate.midY + 60),
                           options: [])
    ctx.restoreGState()

    // 3. Hairline rim: a crisp edge keeps the icon from dissolving into a dark Dock.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: 0.75, dy: 0.75),
                       cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                       transform: nil))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
    ctx.setLineWidth(1.5)
    ctx.strokePath()
    ctx.restoreGState()

    // 4. The mark, with a faint drop shadow so it sits above the plate.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
    ctx.addPath(markPath())
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
    ctx.fillPath()
    ctx.restoreGState()
}

func png(_ px: Int) -> Data {
    let ctx = makeContext(px)
    drawIcon(ctx)
    guard let image = ctx.makeImage() else { fatalError("no image") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: px, height: px)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed")
    }
    return data
}

// MARK: - main

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("kestrel-icon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

// (base points, scale) pairs that iconutil expects for a macOS app icon.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]
for (base, scale) in variants {
    let px = base * scale
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try! png(px).write(to: tmp.appendingPathComponent(name))
    print("  \(name)  \(px)px")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", tmp.path, "-o", out]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)

if iconutil.terminationStatus != 0 {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("==> \(out)")
