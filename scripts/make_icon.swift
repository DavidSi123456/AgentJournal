import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
func render(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let shape = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 220, yRadius: 220)
    NSGradient(colors: [NSColor(calibratedRed: 0.57, green: 0.35, blue: 0.91, alpha: 1),
                        NSColor(calibratedRed: 0.31, green: 0.18, blue: 0.61, alpha: 1)])!.draw(in: shape, angle: -65)
    let paper = NSBezierPath(roundedRect: NSRect(x: 248, y: 214, width: 548, height: 610), xRadius: 58, yRadius: 58)
    NSColor.white.withAlphaComponent(0.94).setFill(); paper.fill()
    let spine = NSBezierPath(roundedRect: NSRect(x: 248, y: 214, width: 63, height: 610), xRadius: 18, yRadius: 18)
    NSColor(calibratedRed: 0.86, green: 0.80, blue: 0.96, alpha: 1).setFill(); spine.fill()
    for y in [670, 518, 366] {
        let line = NSBezierPath(roundedRect: NSRect(x: 417, y: y, width: 260, height: 28), xRadius: 14, yRadius: 14)
        NSColor(calibratedRed: 0.70, green: 0.61, blue: 0.84, alpha: 0.6).setFill(); line.fill()
    }
    let timeline = NSBezierPath(); timeline.move(to: NSPoint(x: 369, y: 393)); timeline.line(to: NSPoint(x: 369, y: 697))
    timeline.lineWidth = 10; NSColor(calibratedRed: 0.78, green: 0.70, blue: 0.92, alpha: 1).setStroke(); timeline.stroke()
    for (y, color) in [(684, NSColor(calibratedRed: 0.20, green: 0.46, blue: 0.91, alpha: 1)),
                       (532, NSColor(calibratedRed: 0.96, green: 0.49, blue: 0.17, alpha: 1)),
                       (380, NSColor(calibratedRed: 0.20, green: 0.46, blue: 0.91, alpha: 1))] {
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: 349, y: y - 20, width: 40, height: 40)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for logical in [16, 32, 128, 256, 512] {
    try render(logical).write(to: folder.appendingPathComponent("icon_\(logical)x\(logical).png"))
    try render(logical * 2).write(to: folder.appendingPathComponent("icon_\(logical)x\(logical)@2x.png"))
}
