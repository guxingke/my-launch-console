// Draws the app icon: a console window listing jobs with status dots, on an indigo tile.
//   swift scripts/make-icon.swift <out.png> [size]
// scripts/make-icon.sh turns the PNG into Resources/AppIcon.icns.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.png> [size]\n".utf8))
    exit(2)
}
let size = arguments.count >= 3 ? Int(arguments[2]) ?? 1024 : 1024

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// Draw in a 1024-point space whatever the output size. AppKit's origin is bottom-left.
let scale = CGFloat(size) / 1024
NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)

// Tile on Apple's macOS icon grid: 824 pt square, inset 100 pt, with a soft drop shadow.
let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0, 0, 0, 0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
color(0.13, 0.15, 0.42).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [color(0.36, 0.42, 0.98), color(0.20, 0.23, 0.72), color(0.09, 0.10, 0.32)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: tile, angle: -90)

// A faint highlight across the top half, like light on glass.
NSGraphicsContext.saveGraphicsState()
tile.addClip()
NSGradient(starting: color(1, 1, 1, 0.16), ending: color(1, 1, 1, 0))!
    .draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// The console window.
let windowRect = NSRect(x: 196, y: 236, width: 632, height: 532)
let window = NSBezierPath(roundedRect: windowRect, xRadius: 60, yRadius: 60)
NSGraphicsContext.saveGraphicsState()
let windowShadow = NSShadow()
windowShadow.shadowColor = color(0, 0, 0, 0.35)
windowShadow.shadowBlurRadius = 30
windowShadow.shadowOffset = NSSize(width: 0, height: -14)
windowShadow.set()
color(0.05, 0.06, 0.15, 0.92).setFill()
window.fill()
NSGraphicsContext.restoreGraphicsState()
color(1, 1, 1, 0.14).setStroke()
window.lineWidth = 3
window.stroke()

// Title bar: traffic lights and a divider.
for (index, light) in [color(1.0, 0.37, 0.34), color(1.0, 0.75, 0.22), color(0.25, 0.80, 0.33)].enumerated() {
    light.setFill()
    NSBezierPath(ovalIn: NSRect(x: 246 + CGFloat(index) * 52, y: 694, width: 30, height: 30)).fill()
}
color(1, 1, 1, 0.10).setFill()
NSRect(x: 196, y: 660, width: 632, height: 3).fill()

// Job rows: status dot plus a label bar, in the app's own colours.
enum Dot { case running, idle, failing }
let rows: [(Dot, CGFloat)] = [(.running, 380), (.idle, 300), (.failing, 340)]
for (index, row) in rows.enumerated() {
    let centerY = 580 - CGFloat(index) * 118
    let dotRect = NSRect(x: 252, y: centerY - 27, width: 54, height: 54)
    switch row.0 {
    case .running:
        color(0.30, 0.86, 0.46).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    case .idle:
        let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 4, dy: 4))
        ring.lineWidth = 8
        color(1, 1, 1, 0.55).setStroke()
        ring.stroke()
    case .failing:
        color(1.0, 0.36, 0.36).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }
    let bar = NSBezierPath(roundedRect: NSRect(x: 344, y: centerY - 17, width: row.1, height: 34), xRadius: 17, yRadius: 17)
    color(1, 1, 1, row.0 == .idle ? 0.45 : 0.85).setFill()
    bar.fill()
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: arguments[1]))
