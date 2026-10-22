// Draws app/AppIcon.icns, the manager app's own icon: three profile cards
// with Clawd's eyes, the back two peeking over the front one. Holds up in a
// single color: overlaps are separated by a gap in the plate color.
//   swift scripts/make-icon.swift app/AppIcon.icns
import AppKit

let out = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Same swatches as ProfileColor in app/ClaudeProfiles.swift.
let orange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
let blue   = NSColor(red: 0.33, green: 0.56, blue: 0.83, alpha: 1)
let green  = NSColor(red: 0.36, green: 0.69, blue: 0.42, alpha: 1)
let plateColor = NSColor(red: 0.15, green: 0.15, blue: 0.14, alpha: 1)

func moved(_ p: NSBezierPath, _ t: AffineTransform) -> NSBezierPath {
    let q = p.copy() as! NSBezierPath
    q.transform(using: t)
    return q
}

func eyes(_ c: NSPoint) -> NSBezierPath {
    let p = NSBezierPath(rect: NSRect(x: c.x - 110, y: c.y - 60, width: 52, height: 120))
    p.append(NSBezierPath(rect: NSRect(x: c.x + 58, y: c.y - 60, width: 52, height: 120)))
    return p
}

// Back to front, in a 1024 space with a bottom-left origin.
let cards: [(card: NSBezierPath, eyes: NSBezierPath, color: NSColor)] = {
    let card = NSBezierPath(roundedRect: NSRect(x: 322, y: 230, width: 380, height: 520), xRadius: 64, yRadius: 64)
    // A back card tilts 12° outward about the front card's bottom, then slides
    // out and up so its eyes clear the front card.
    func back(_ side: CGFloat, _ color: NSColor) -> (NSBezierPath, NSBezierPath, NSColor) {
        var t = AffineTransform(translationByX: 512, byY: 200)
        t.rotate(byDegrees: -side * 12)
        t.translate(x: -512, y: -200)
        t.append(AffineTransform(translationByX: side * 190, byY: 230))
        return (moved(card, t), moved(eyes(NSPoint(x: 512 + side * 30, y: 640)), t), color)
    }
    let all = [back(-1, blue), back(1, green), (card, eyes(NSPoint(x: 512, y: 520)), orange)]
    // Fit the group into the plate.
    let union = NSBezierPath()
    all.forEach { union.append($0.0) }
    let b = union.bounds
    var fit = AffineTransform(translationByX: 512, byY: 512)
    fit.scale(700 / max(b.width, b.height))
    fit.translate(x: -b.midX, y: -b.midY)
    return all.map { (moved($0.0, fit), moved($0.1, fit), $0.2) }
}()

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: s, y: s)
    // macOS icon grid: an 824pt rounded square centered on a 1024 canvas.
    plateColor.setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
    for c in cards {
        plateColor.setStroke()
        c.card.lineWidth = 30
        c.card.stroke()
        c.color.setFill()
        c.card.fill()
        plateColor.setFill()
        c.eyes.fill()
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
