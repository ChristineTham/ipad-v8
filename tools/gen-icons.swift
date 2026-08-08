// Render the Edition app icon: the DMD 5620's portrait screen in phosphor
// green on black, with a cursor block. Reproducible — no binary art to
// maintain, and the shape stays legible at 16 pt.
//
//   swiftc -O -o /tmp/gen-icons tools/gen-icons.swift
//   /tmp/gen-icons app/Edition/Assets.xcassets/AppIcon.appiconset
//
// Contents.json in that directory lists the files this writes; if you change
// the set of sizes, update it too.
import AppKit
import CoreGraphics
import Foundation

let phosphor = CGColor(red: 0.45, green: 1.0, blue: 0.60, alpha: 1.0)
let dim = CGColor(red: 0.45, green: 1.0, blue: 0.60, alpha: 0.55)

func drawIcon(size: CGFloat, macStyle: Bool) -> CGImage {
    let s = Int(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // macOS icons carry their own rounded shape and margin; iOS is masked for us.
    let inset: CGFloat = macStyle ? size * 0.085 : 0
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner: CGFloat = macStyle ? plate.width * 0.22 : 0

    let body = CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner,
                      transform: nil)
    ctx.addPath(body)
    ctx.clip()

    // Cabinet: near-black with a slight lift toward the top.
    let grad = CGGradient(colorsSpace: cs,
                          colors: [CGColor(red: 0.09, green: 0.10, blue: 0.09, alpha: 1),
                                   CGColor(red: 0.02, green: 0.03, blue: 0.02, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0),
                           options: [])

    // The screen itself: the 5620 is 800x1024, a portrait tube.
    let screenH = plate.height * 0.62
    let screenW = screenH * 800.0 / 1024.0
    let screen = CGRect(x: plate.midX - screenW / 2, y: plate.midY - screenH / 2,
                        width: screenW, height: screenH)
    ctx.setStrokeColor(phosphor)
    ctx.setLineWidth(max(1, size * 0.016))
    let screenPath = CGPath(roundedRect: screen, cornerWidth: size * 0.02,
                            cornerHeight: size * 0.02, transform: nil)
    ctx.addPath(screenPath)
    ctx.strokePath()

    // Two text rules and a cursor block — reads as "terminal" even at 16 px.
    let pad = screen.width * 0.16
    let lineH = max(1, screen.height * 0.035)
    let gap = screen.height * 0.085
    var y = screen.maxY - gap * 1.5
    ctx.setFillColor(dim)
    for width in [0.62, 0.42] as [CGFloat] {
        ctx.fill(CGRect(x: screen.minX + pad, y: y,
                        width: (screen.width - pad * 2) * width, height: lineH))
        y -= gap
    }
    ctx.setFillColor(phosphor)
    let cursor = CGRect(x: screen.minX + pad, y: y - lineH * 0.4,
                        width: screen.width * 0.13, height: gap * 0.62)
    ctx.fill(cursor)

    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// iOS: one 1024 full-bleed image (Xcode 14+ single-size app icon).
write(drawIcon(size: 1024, macStyle: false), to: "\(out)/icon-ios-1024.png")

// macOS: the classic ten-image set.
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let px = pt * scale
        let name = scale == 1 ? "icon-mac-\(pt).png" : "icon-mac-\(pt)@2x.png"
        write(drawIcon(size: CGFloat(px), macStyle: true), to: "\(out)/\(name)")
    }
}
print("icons written to \(out)")
