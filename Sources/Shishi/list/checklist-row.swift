import AppKit
import ShishiCore

@MainActor final class ChecklistRow: NSView {
    let item: ChecklistItem
    let check = ChecklistCompletionButton()
    let field = ChecklistTextField()
    private let handle: ChecklistDragHandle
    var onSelect: (() -> Void)?
    var onToggle: (() -> Void)?
    var onMove: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered = false
    var isSelected = false { didSet { updateHandle(); needsDisplay = true } }

    init(item: ChecklistItem, sourceID: UUID, textSize: Int = 14) {
        self.item = item
        handle = ChecklistDragHandle(payload: ChecklistDragPayload(sourceID: sourceID, itemID: item.id))
        super.init(frame: .zero)
        check.title = ""; check.setButtonType(.switch)
        check.state = item.completed ? .on : .off
        check.target = self; check.action = #selector(toggle)
        check.setAccessibilityLabel("勾选检查列表项")
        field.stringValue = item.title
        field.placeholderString = "检查列表项"
        field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none; field.textColor = .labelColor
        field.font = .systemFont(ofSize: CGFloat(textSize))
        field.cell?.wraps = false; field.cell?.isScrollable = true
        field.setAccessibilityLabel("检查列表项")
        field.onFocus = { [weak self] in self?.onSelect?() }
        handle.onSelect = { [weak self] in self?.onSelect?() }
        for view in [check, field, handle] { addSubview(view) }
        updateHandle()
        let menu = NSMenu()
        for (title, action) in [("上移", #selector(up)), ("下移", #selector(down))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        self.menu = menu; field.menu = menu
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        check.frame = NSRect(x: 2, y: 4, width: 20, height: 20)
        let height = min(bounds.height - 4, max(20, (field.font?.pointSize ?? 14) + 4))
        field.frame = NSRect(x: 26, y: (bounds.height - height) / 2, width: max(0, bounds.width - 54), height: height)
        handle.frame = NSRect(x: max(26, bounds.width - 24), y: 3, width: 22, height: 22)
    }
    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Appearance.selectionBackground.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8).fill()
            // 选中时是一整块浅蓝圆角底，不再画分隔线。
            return
        }
        Appearance.listSeparator.setFill()
        NSRect(x: 2, y: bounds.height - 0.5, width: max(0, bounds.width - 4), height: 0.5).fill()
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateHandle() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateHandle() }
    private func updateHandle() { handle.alphaValue = isSelected || hovered ? 1 : 0 }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        if window?.makeFirstResponder(field) == true { onSelect?() }
    }
    @objc private func toggle() { onToggle?() }
    @objc private func up() { onSelect?(); onMove?(-1) }
    @objc private func down() { onSelect?(); onMove?(1) }
}

@MainActor final class ChecklistTextField: NSTextField {
    var onFocus: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = ChecklistTextFieldCell(textCell: "")
        isEditable = true; isSelectable = true
    }
    required init?(coder: NSCoder) { nil }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocus?()
        }
        return accepted
    }
}

/// 独立编辑器与选中行共用底色，避免表格重配共享编辑器时出现白色矩形。
@MainActor private final class ChecklistTextFieldCell: NSTextFieldCell {
    private let checklistEditor = ChecklistFieldEditor()
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        checklistEditor.isFieldEditor = true
        checklistEditor.isRichText = false
        checklistEditor.allowsUndo = true
        return checklistEditor
    }
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        editor.drawsBackground = false
        if let text = editor as? NSTextView { text.insertionPointColor = Appearance.blue }
        return editor
    }
}

@MainActor private final class ChecklistFieldEditor: NSTextView {
    /// 编辑器底色与选中行一致，避免共享编辑器出现白色矩形；深色模式底色半透明，
    /// 行已经画过一层，这里再叠会变深，所以只在不透明时填充。
    override func drawBackground(in rect: NSRect) {
        guard let color = Appearance.selectionBackground.usingColorSpace(.sRGB), color.alphaComponent == 1 else { return }
        color.setFill()
        rect.fill()
    }
}

/// 清单专用圆形勾选框，父卡片继续使用原来的方形按钮。
@MainActor final class ChecklistCompletionButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 5, dy: 5)
        Appearance.blue.setStroke()
        let outline = NSBezierPath(ovalIn: circle)
        outline.lineWidth = 1.4; outline.stroke()
        if state == .on {
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: circle.minX + 2, y: circle.midY))
            tick.line(to: NSPoint(x: circle.midX - 1, y: isFlipped ? circle.maxY - 2 : circle.minY + 2))
            tick.line(to: NSPoint(x: circle.maxX - 2, y: isFlipped ? circle.minY + 2 : circle.maxY - 2))
            tick.lineWidth = 1.2; tick.lineCapStyle = .round; tick.stroke()
        }
    }
}
