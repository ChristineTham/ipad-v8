// Render the ipnx app icon: a stylised licence plate reading "ipnx" over
// "LIVE FREE OR DIE".
//
// The joke is Armando Stettner's. In the mid-1980s he had DEC's New Hampshire
// plant issue vanity plates reading UNIX, and handed them out at USENIX; one
// hung in the Bell Labs UNIX room, and the plate became the tribe's badge. The
// state's own motto sitting under the word was the whole gag, and it lands
// differently now: the reason this project exists at all is that Editions 8-10
// were locked up for thirty years by the lawsuits the name attracted, until
// the 2017 covenant let them go. "Intellectual Property is not Unix."
//
//   swiftc -O -o /tmp/gen-icons tools/gen-icons.swift
//   /tmp/gen-icons app/ipnx/Assets.xcassets/AppIcon.appiconset
//
// DELIBERATELY NOT A REAL PLATE. No state name, no seal, no registration
// number, no jurisdiction of any kind — and proportions and colours that are
// ours rather than any issuing authority's. It should read as "licence plate",
// never as a document. Reproducible: no binary art to maintain, and the shape
// stays legible at 16 pt, where the motto drops out and "ipnx" grows to fill
// the plate.
//
// Contents.json in the output directory lists the files this writes; if you
// change the set of sizes, update it too.
import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Embossed plate green — dark enough to hold its own against the cream at
/// 16 px, where anti-aliasing eats thin strokes.
let plateGreen = CGColor(red: 0.07, green: 0.34, blue: 0.20, alpha: 1)
let plateGreenLift = CGColor(red: 0.12, green: 0.46, blue: 0.28, alpha: 1)
let creamTop = CGColor(red: 0.98, green: 0.97, blue: 0.93, alpha: 1)
let creamBottom = CGColor(red: 0.90, green: 0.88, blue: 0.81, alpha: 1)

// MARK: - Text helpers

func makeLine(_ text: String, points: CGFloat, weight: NSFont.Weight,
              color: CGColor, tracking: CGFloat) -> CTLine {
    let font = NSFont.systemFont(ofSize: points, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color)!,
        .kern: tracking,
    ]
    return CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attrs))
}

func inkBounds(_ line: CTLine) -> CGRect {
    CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
}

/// Draw `text` centred on `centre`, scaled so its glyphs are exactly
/// `targetWidth` wide. Measuring at a reference size and scaling is exact,
/// where guessing a point size from the string length is not — "ipnx" has no
/// ascenders to speak of and one descender, so its ink box is nothing like its
/// em box.
func drawFitted(_ ctx: CGContext, _ text: String, weight: NSFont.Weight,
                color: CGColor, tracking: CGFloat,
                targetWidth: CGFloat, centre: CGPoint) {
    let reference: CGFloat = 100
    let probe = makeLine(text, points: reference, weight: weight,
                         color: color, tracking: tracking * reference)
    let box = inkBounds(probe)
    guard box.width > 0 else { return }
    let scale = targetWidth / box.width
    let line = makeLine(text, points: reference * scale, weight: weight,
                        color: color, tracking: tracking * reference * scale)
    let ink = inkBounds(line)
    ctx.textPosition = CGPoint(x: centre.x - ink.midX,
                               y: centre.y - ink.midY)
    CTLineDraw(line, ctx)
}

// MARK: - The icon

func drawIcon(size: CGFloat, macStyle: Bool) -> CGImage {
    let px = Int(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // macOS icons carry their own rounded shape and margin; iOS is masked for
    // us, so it fills the square.
    let inset: CGFloat = macStyle ? size * 0.085 : 0
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner: CGFloat = macStyle ? body.width * 0.20 : size * 0.005

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner,
                       transform: nil))
    ctx.clip()

    // The plate itself: pressed steel catches more light along its top edge.
    let grad = CGGradient(colorsSpace: cs, colors: [creamTop, creamBottom] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY), options: [])

    // The rolled rim: a highlight sitting just above a shadow, which is what
    // makes a pressed edge read as pressed rather than drawn. Its radius is
    // its own — tied to the body's, it vanished on iOS, where the body is a
    // square that the system's own mask rounds afterwards.
    //
    // At 16 px the rim costs more than it earns: two strokes and their inset
    // eat five of the sixteen pixels, leaving nine for four glyphs, and "ipnx"
    // came out as a green smear. Below 32 px the plate is just its face, and
    // the name gets the room.
    let showsRim = size >= 32
    let rimInset = size * 0.070
    let rim = showsRim ? body.insetBy(dx: rimInset, dy: rimInset) : body
    if showsRim {
        let rimCorner = size * (macStyle ? 0.055 : 0.075)
        ctx.setLineWidth(max(1, size * 0.013))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.addPath(CGPath(roundedRect: rim.offsetBy(dx: 0, dy: -size * 0.007),
                           cornerWidth: rimCorner, cornerHeight: rimCorner, transform: nil))
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(red: 0.52, green: 0.50, blue: 0.44, alpha: 0.8))
        ctx.addPath(CGPath(roundedRect: rim, cornerWidth: rimCorner,
                           cornerHeight: rimCorner, transform: nil))
        ctx.strokePath()
    }

    // Below ~64 px the motto is smaller than a pixel is wide, so it would only
    // add grey mush along the bottom. Drop it and let the name have the plate.
    let showsMotto = size >= 64
    let showsBolts = size >= 128

    if showsBolts {
        let r = size * 0.017
        let y = body.maxY - body.height * 0.155
        for dx in [-1.0, 1.0] as [CGFloat] {
            let hole = CGRect(x: body.midX + dx * body.width * 0.255 - r, y: y - r,
                              width: r * 2, height: r * 2)
            ctx.setFillColor(CGColor(red: 0.58, green: 0.56, blue: 0.50, alpha: 0.85))
            ctx.fillEllipse(in: hole)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.55))
            ctx.fillEllipse(in: hole.insetBy(dx: r * 0.35, dy: r * 0.35)
                                .offsetBy(dx: 0, dy: r * 0.25))
        }
    }

    // "ipnx", embossed. Light comes from the top, so a raised face catches a
    // highlight along its upper edge and drops a shadow below it — both are
    // needed, and both have to stay quiet: a single hard white copy read as a
    // misregistered second printing rather than as relief. Below 64 px the
    // offsets are smaller than a pixel and the pair only smears the name, so
    // they come off entirely.
    //
    // The name is measured against the *rim's* inner width, not the icon's.
    // Against the icon it was a hair wider than the rim at 16 px, and green
    // ink touching the pressed edge is what made the small size look broken
    // rather than merely small.
    let showsRelief = size >= 64
    let nameWidth = rim.width * (showsMotto ? 0.88 : 0.80)
    let nameCentre = CGPoint(x: body.midX,
                             y: showsMotto ? body.midY + body.height * 0.035 : body.midY)
    if showsRelief {
        let relief = size * 0.005
        drawFitted(ctx, "ipnx", weight: .heavy, color: CGColor(gray: 0.35, alpha: 0.28),
                   tracking: -0.02, targetWidth: nameWidth,
                   centre: CGPoint(x: nameCentre.x, y: nameCentre.y - relief))
        drawFitted(ctx, "ipnx", weight: .heavy, color: CGColor(gray: 1, alpha: 0.6),
                   tracking: -0.02, targetWidth: nameWidth,
                   centre: CGPoint(x: nameCentre.x, y: nameCentre.y + relief))
    }
    drawFitted(ctx, "ipnx", weight: .heavy, color: plateGreen,
               tracking: -0.02, targetWidth: nameWidth, centre: nameCentre)

    if showsMotto {
        drawFitted(ctx, "LIVE FREE OR DIE", weight: .semibold, color: plateGreenLift,
                   tracking: 0.08, targetWidth: rim.width * 0.84,
                   centre: CGPoint(x: body.midX, y: body.minY + body.height * 0.195))
    }

    ctx.restoreGState()
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
