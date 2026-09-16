import AppKit

final class CardNotesView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("备注" as NSString).draw(at: NSPoint(x: 0, y: 2), withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
}
final class CardPaperView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 5; shadow.shadowOffset = NSSize(width: 0, height: -2); shadow.set()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        NSColor.textBackgroundColor.setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.withAlphaComponent(0.14).setStroke(); shape.lineWidth = 0.5; shape.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
final class CardCompletionButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: (bounds.width - 13) / 2, y: (bounds.height - 13) / 2, width: 13, height: 13)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        if state == .on {
            Appearance.blue.setFill(); path.fill(); NSColor.white.setStroke()
            let tick = NSBezierPath(); tick.move(to: NSPoint(x: rect.minX + 3, y: rect.midY))
            tick.line(to: NSPoint(x: rect.minX + 5, y: rect.minY + 3)); tick.line(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 3))
            tick.lineWidth = 1.5; tick.stroke()
        } else { NSColor.tertiaryLabelColor.setStroke(); path.lineWidth = 1; path.stroke() }
    }
}
final class CardToolButton: NSButton {
    private var area: NSTrackingArea?
    private var hovered = false
    private let expandsChecklist: Bool
    private var toolWidth: NSLayoutConstraint!
    init(symbol: String, title: String) {
        expandsChecklist = symbol == "checklist"
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        self.title = ""; toolTip = title; isBordered = false
        contentTintColor = .secondaryLabelColor; imagePosition = .imageOnly; focusRingType = .none
        setAccessibilityLabel(title)
        font = .systemFont(ofSize: 13)
        toolWidth = widthAnchor.constraint(equalToConstant: 26); toolWidth.isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateHover() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateHover() }
    private func updateHover() {
        if expandsChecklist {
            title = hovered ? "检查列表" : ""
            imagePosition = hovered ? .imageLeading : .imageOnly
            toolWidth.constant = hovered ? 104 : 26
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if hovered { NSColor.quaternaryLabelColor.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill() }
        super.draw(dirtyRect)
    }
}
