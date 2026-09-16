import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Shishi.iconset")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let box = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 196, yRadius: 196)
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.99, green: 0.62, blue: 0.38, alpha: 1), ending: NSColor(calibratedRed: 0.90, green: 0.31, blue: 0.30, alpha: 1))!
        gradient.draw(in: box, angle: -90)
        NSColor.white.withAlphaComponent(0.94).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 76; line.lineCapStyle = .round; line.lineJoinStyle = .round
        line.move(to: NSPoint(x: 290, y: 505)); line.line(to: NSPoint(x: 447, y: 345)); line.line(to: NSPoint(x: 748, y: 679)); line.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
