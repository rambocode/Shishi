import AppKit

/// 拖动开始时只绘制一次浮起的标题，鼠标移动交给系统拖动窗口，不反复截图或重建列表。
@MainActor enum HeadingDragPreview {
    static let margin: CGFloat = 16

    static func image(title: String, size: NSSize, textSize: Int) -> NSImage {
        let canvas = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
        return NSImage(size: canvas, flipped: true) { _ in
            let body = NSRect(origin: NSPoint(x: margin + 2, y: margin + 3),
                              size: NSSize(width: max(0, size.width - 4), height: max(0, size.height - 6)))
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
            shadow.shadowBlurRadius = 14; shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.set()
            Appearance.selectionBackground.setFill()
            NSBezierPath(roundedRect: body, xRadius: 8, yRadius: 8).fill()
            NSGraphicsContext.restoreGraphicsState()
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            let font = NSFont.systemFont(ofSize: CGFloat(textSize), weight: .semibold)
            let lineHeight = font.ascender - font.descender + font.leading
            (title as NSString).draw(in: NSRect(x: margin + 8, y: margin + size.height - 7 - lineHeight,
                                               width: max(0, size.width - 24), height: lineHeight + 2),
                                    withAttributes: [.font: font, .foregroundColor: Appearance.blue, .paragraphStyle: style])
            return true
        }
    }
}

extension ListTableView {
    /// 读取原生 gap 的几何并填充淡灰占位；不修改布局，不创建覆盖层。
    func drawHeadingDropGap(in clipRect: NSRect) {
        guard draggingDestinationFeedbackStyle == .gap, let boundary = headingDropBoundary,
              boundary >= 0, boundary <= numberOfRows else { return }
        let top = boundary == 0 ? CGFloat(0) : rect(ofRow: boundary - 1).maxY
        let bottom = boundary < numberOfRows ? rect(ofRow: boundary).minY : bounds.maxY
        guard bottom - top > 4 else { return }
        let gap = NSRect(x: 2, y: top + 3, width: max(0, bounds.width - 4), height: bottom - top - 6)
        guard gap.intersects(clipRect), gap.height > 0 else { return }
        NSColor.labelColor.withAlphaComponent(0.055).setFill()
        NSBezierPath(roundedRect: gap, xRadius: 8, yRadius: 8).fill()
    }
}
