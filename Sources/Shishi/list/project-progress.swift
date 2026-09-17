import AppKit
import QuartzCore
import ShishiCore

/// 共享项目进度图标；提供 onActivate 时作为可通过键盘和辅助功能操作的完成按钮。
final class ProjectProgressView: NSButton {
    var onActivate: (() -> Void)? {
        didSet {
            setAccessibilityRole(onActivate == nil ? .image : .button)
            toolTip = onActivate == nil ? nil : "完成或重新打开项目"
        }
    }

    private(set) var projectID: UUID?
    private(set) var showsCheckmark = false

    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }
    var summaryText: String = "项目完成进度" {
        didSet { setAccessibilityLabel(summaryText) }
    }

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        target = self
        action = #selector(activate)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(summaryText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    /// 侧栏、项目页和智能列表统一使用同一状态与统计口径。
    func configure(project: Project, summary: ProjectSummary) {
        projectID = project.id
        let completed = (project.completed || project.status == .completed) && project.status != .canceled
        showsCheckmark = completed
        isEnabled = project.deletedAt == nil
        fraction = completed ? 1 : summary.fraction
        if project.status == .canceled { summaryText = "项目已取消" }
        else { summaryText = completed ? "项目已完成" : "项目进度：已完成 \(summary.completedCount) / \(summary.openCount + summary.completedCount)" }
    }

    /// 点击完成的即时视觉反馈，不扫描任务；实际保存失败由控制器恢复快照状态。
    func showCompletionCheckmark() {
        showsCheckmark = true
        fraction = 1
        summaryText = "项目已完成"
        displayIfNeeded()
        window?.displayIfNeeded()
        CATransaction.flush()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { onActivate == nil ? nil : super.hitTest(point) }
    @objc private func activate() { onActivate?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
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

        if showsCheckmark {
            // 项目完成与“任务全部完成但项目尚未关闭”使用不同图形。
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: center.x - diameter * 0.23, y: center.y))
            tick.line(to: NSPoint(x: center.x - diameter * 0.05,
                                 y: center.y + diameter * (isFlipped ? 0.17 : -0.17)))
            tick.line(to: NSPoint(x: center.x + diameter * 0.24,
                                 y: center.y + diameter * (isFlipped ? -0.20 : 0.20)))
            Appearance.blue.setStroke()
            tick.lineWidth = max(1.4, diameter / 12)
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            tick.stroke()
            return
        }

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
