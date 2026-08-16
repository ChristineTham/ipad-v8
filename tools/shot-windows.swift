// List the on-screen windows of an application, with their CoreGraphics ids.
//
//     swift tools/shot-windows.swift ipnx
//
// Exists because `screencapture -l<id>` wants a CGWindowID and nothing in the
// shell hands you one: `osascript` sees accessibility elements, which are a
// different namespace, and `screencapture -w` is interactive. Capturing by
// window id rather than by screen rectangle is what makes the shots clean —
// no desktop behind, no neighbouring window clipped in at the edge, and
// correct even if the window is partly off-screen.
//
// Output is one window per line: id, size, and title.
import CoreGraphics
import Foundation

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ipnx"

guard
    let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("cannot read the window list\n".utf8))
    exit(1)
}

var found = 0
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == wanted,
        let id = w[kCGWindowNumber as String] as? Int,
        let bounds = w[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
    else { continue }

    // Skip the furniture: menu-bar items and other zero-area or tiny layers
    // that are technically windows and are never what you want a picture of.
    if width < 200 || height < 200 { continue }

    let title = (w[kCGWindowName as String] as? String) ?? ""
    print("\(id)\t\(Int(width))x\(Int(height))\t\(title)")
    found += 1
}

if found == 0 {
    FileHandle.standardError.write(Data("no windows for '\(wanted)'\n".utf8))
    exit(2)
}
