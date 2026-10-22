// Draws app/AppIcon.icns, the manager app's own icon: four profile-color
// tiles. The release ships it instead of an icon derived from Claude's.
//   swift scripts/make-icon.swift app/AppIcon.icns
import AppKit

let out = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Same swatches as ProfileColor in app/ClaudeProfiles.swift, in the old grid's
// order: orange, blue (top), green, purple (bottom).
let tiles: [NSColor] = [
    NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1),
    NSColor(red: 0.33, green: 0.56, blue: 0.83, alpha: 1),
    NSColor(red: 0.36, green: 0.69, blue: 0.42, alpha: 1),
    NSColor(red: 0.62, green: 0.47, blue: 0.83, alpha: 1),
]

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: an 824pt rounded square centered on a 1024 canvas.
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    NSColor(white: 0.97, alpha: 1).setFill()
    NSBezierPath(roundedRect: plate, xRadius: 185 * s, yRadius: 185 * s).fill()
    let gap = 36 * s, inset = 92 * s
    let side = (plate.width - 2 * inset - gap) / 2
    for (i, color) in tiles.enumerated() {
        let col = CGFloat(i % 2), row = CGFloat(1 - i / 2)
        let r = NSRect(x: plate.minX + inset + col * (side + gap),
                       y: plate.minY + inset + row * (side + gap),
                       width: side, height: side)
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: 64 * s, yRadius: 64 * s).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(p.terminationStatus)
