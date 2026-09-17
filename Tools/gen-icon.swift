// gen-icon: draws the app icon with CoreGraphics and packs it into an .icns.
//
//   swift Tools/gen-icon.swift Tools/thock.icns
//
// A dark rounded tile with a light keycap and three sound arcs. No assets,
// no fonts, fully deterministic.

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    print("usage: swift Tools/gen-icon.swift OUT.icns")
    exit(64)
}
let outPath = CommandLine.arguments[1]

func render(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    let s = CGFloat(size)

    // Tile: macOS-style rounded square with a slight inset so it sits like
    // other icons in the Dock/Finder.
    let inset = s * 0.05
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let colors = [CGColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1), CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    }
    ctx.restoreGState()

    // Keycap: light rounded square, left of centre, with a shadow.
    let capSize = s * 0.46
    let cap = CGRect(x: s * 0.17, y: (s - capSize) / 2 - s * 0.02, width: capSize, height: capSize)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.05, color: CGColor(gray: 0, alpha: 0.6))
    ctx.addPath(CGPath(roundedRect: cap, cornerWidth: s * 0.08, cornerHeight: s * 0.08, transform: nil))
    ctx.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.90, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    // Keycap top face (slightly smaller, lighter) for the dished look.
    let face = cap.insetBy(dx: s * 0.05, dy: s * 0.05).offsetBy(dx: 0, dy: s * 0.015)
    ctx.addPath(CGPath(roundedRect: face, cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil))
    ctx.setFillColor(CGColor(red: 0.99, green: 0.99, blue: 0.97, alpha: 1))
    ctx.fillPath()

    // Sound arcs to the right of the keycap.
    let origin = CGPoint(x: cap.maxX + s * 0.02, y: cap.midY)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 1))
    ctx.setLineCap(.round)
    for (i, radius) in [0.10, 0.17, 0.24].enumerated() {
        ctx.setLineWidth(s * (0.045 - CGFloat(i) * 0.006))
        ctx.addArc(center: origin, radius: s * CGFloat(radius), startAngle: -.pi / 3.2, endAngle: .pi / 3.2, clockwise: false)
        ctx.strokePath()
    }
    image.unlockFocus()
    return image
}

func png(_ image: NSImage, size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("thock.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! png(render(size: px), size: px).write(to: tmp.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", tmp.path, "-o", outPath]
try! task.run()
task.waitUntilExit()
try! png(render(size: 512), size: 512).write(to: URL(fileURLWithPath: outPath).deletingPathExtension().appendingPathExtension("png"))
print("gen-icon: wrote \(outPath) (iconutil exit \(task.terminationStatus))")
