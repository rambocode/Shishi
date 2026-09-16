import AppKit

final class DateToolbarButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        super.draw(dirtyRect)
    }
}
