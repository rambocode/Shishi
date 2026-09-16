import AppKit
import ShishiCore

/// 非交互的项目完成进度图像；外部通过 frame 或约束选择 16 / 28pt 等尺寸。
final class ProjectProgressView: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }
    var summaryText: String = "项目完成进度" {
        didSet { setAccessibilityLabel(summaryText) }
    }

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(summaryText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    /// 侧栏、项目页和智能列表统一使用同一状态与统计口径。
    func configure(project: Project, summary: ProjectSummary) {
        let completed = (project.completed || project.status == .completed) && project.status != .canceled
        fraction = completed ? 1 : summary.fraction
        summaryText = completed ? "项目已完成" : "项目进度：已完成 \(summary.completedCount) / \(summary.openCount + summary.completedCount)"
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let diameter = min(bounds.width, bounds.height)
        guard diameter > 0 else { return }
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let ringWidth = max(1, diameter / 14)
        let outer = NSRect(x: center.x - diameter / 2 + ringWidth / 2,
                           y: center.y - diameter / 2 + ringWidth / 2,
                           width: diameter - ringWidth, height: diameter - ringWidth)
        // 间隙随外观切换，避免深色模式下零进度被白色圆盘误读成满圆。
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(ovalIn: outer).fill()
        Appearance.blue.setStroke()
        let ring = NSBezierPath(ovalIn: outer)
        ring.lineWidth = ringWidth
        ring.stroke()

        let progress = fraction.isNaN ? 0 : min(1, max(0, fraction))
        guard progress > 0 else { return }
        let radius = max(0, diameter / 2 - ringWidth - max(1, diameter / 14))
        guard radius > 0 else { return }
        Appearance.blue.setFill()
        if progress == 1 {
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                      width: radius * 2, height: radius * 2)).fill()
        } else {
            let pie = NSBezierPath()
            pie.move(to: center)
            pie.line(to: NSPoint(x: center.x, y: center.y + radius))
            pie.appendArc(withCenter: center, radius: radius, startAngle: 90,
                          endAngle: CGFloat(90 - progress * 360), clockwise: true)
            pie.close()
            pie.fill()
        }
    }
}
