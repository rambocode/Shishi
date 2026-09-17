import AppKit

/// 底部按钮的悬停轮廓与说明；提示不接管键盘焦点。
final class BottomToolbarButton: NSButton {
    static func headingImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.black.setStroke()
            let outline = NSBezierPath()
            // 横向圆角标签：右端为短尖角，整体比例与旁边的系统图标保持一致。
            outline.move(to: NSPoint(x: 6, y: 19.5))
            outline.line(to: NSPoint(x: 14.5, y: 19.5))
            outline.curve(to: NSPoint(x: 17.1, y: 18.3), controlPoint1: NSPoint(x: 15.7, y: 19.5), controlPoint2: NSPoint(x: 16.4, y: 19.1))
            outline.line(to: NSPoint(x: 21.2, y: 13.6))
            outline.curve(to: NSPoint(x: 21.2, y: 10.4), controlPoint1: NSPoint(x: 22.1, y: 12.6), controlPoint2: NSPoint(x: 22.1, y: 11.4))
            outline.line(to: NSPoint(x: 17.1, y: 5.7))
            outline.curve(to: NSPoint(x: 14.5, y: 4.5), controlPoint1: NSPoint(x: 16.4, y: 4.9), controlPoint2: NSPoint(x: 15.7, y: 4.5))
            outline.line(to: NSPoint(x: 6, y: 4.5))
            outline.curve(to: NSPoint(x: 2.5, y: 8), controlPoint1: NSPoint(x: 3.8, y: 4.5), controlPoint2: NSPoint(x: 2.5, y: 5.8))
            outline.line(to: NSPoint(x: 2.5, y: 16))
            outline.curve(to: NSPoint(x: 6, y: 19.5), controlPoint1: NSPoint(x: 2.5, y: 18.2), controlPoint2: NSPoint(x: 3.8, y: 19.5))
            outline.close()
            outline.lineWidth = 1.45; outline.lineJoinStyle = .round; outline.stroke()
            let plus = NSBezierPath()
            plus.move(to: NSPoint(x: 6.7, y: 12)); plus.line(to: NSPoint(x: 13.3, y: 12))
            plus.move(to: NSPoint(x: 10, y: 8.7)); plus.line(to: NSPoint(x: 10, y: 15.3))
            plus.lineWidth = 1.8; plus.lineCapStyle = .round; plus.stroke()
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = "新建标题"
        return image
    }
    var hintShortcut = ""
    var hintDetail = ""
    var hintTitle = ""
    private var hovered = false
    private var tracking: NSTrackingArea?
    private var hint: NSPopover?
    private var pendingHint: DispatchWorkItem?

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        hovered = true; needsDisplay = true
        guard !hintTitle.isEmpty else { return }
        pendingHint?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showHint() }
        pendingHint = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
    override func mouseExited(with event: NSEvent) { clearHint() }
    override func mouseDown(with event: NSEvent) {
        clearHint(); super.mouseDown(with: event)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { clearHint() } }
    private func clearHint() {
        hovered = false; pendingHint?.cancel(); pendingHint = nil
        hint?.performClose(nil); hint = nil; needsDisplay = true
    }
    private func showHint() {
        guard hovered, isEnabled, !isHidden, window?.isKeyWindow == true else { return }
        let pane = NSViewController()
        let title = NSTextField(labelWithString: hintTitle); title.font = .systemFont(ofSize: 13, weight: .semibold)
        let shortcut = NSTextField(labelWithString: hintShortcut); shortcut.font = .systemFont(ofSize: 13, weight: .semibold)
        shortcut.textColor = .secondaryLabelColor
        let header = NSStackView(views: [title, NSView(), shortcut]); header.distribution = .fill; header.spacing = 12
        let detail = NSTextField(wrappingLabelWithString: hintDetail); detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor; detail.preferredMaxLayoutWidth = 250
        let stack = NSStackView(views: [header, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        let root = NSView(); root.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), root.widthAnchor.constraint(equalToConstant: 275)
        ])
        pane.view = root; pane.preferredContentSize = root.fittingSize
        let popup = NSPopover(); popup.behavior = .applicationDefined; popup.animates = false; popup.contentViewController = pane
        hint = popup; popup.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted || state == .on) {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: (bounds.height - 4) / 2, yRadius: (bounds.height - 4) / 2)
            NSColor.textBackgroundColor.setFill(); shape.fill()
            NSColor.secondaryLabelColor.withAlphaComponent(0.8).setStroke(); shape.lineWidth = 1; shape.stroke()
        }
        super.draw(dirtyRect)
    }
}
