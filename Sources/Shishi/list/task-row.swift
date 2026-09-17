import AppKit
import ShishiCore

final class TaskRowView: NSTableCellView {
    private let check = TaskCheckButton()
    private let title = NSTextField(labelWithString: "")
    private let badges = NSTextField(labelWithString: "")
    var onToggle: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        check.setButtonType(.switch)
        check.title = ""
        check.isBordered = false
        check.target = self
        check.action = #selector(toggle)
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        badges.font = .systemFont(ofSize: 11)
        badges.textColor = .secondaryLabelColor
        badges.alignment = .right
        badges.lineBreakMode = .byTruncatingTail
        for v in [check, title, badges] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            badges.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            badges.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badges.centerYAnchor.constraint(equalTo: centerYAnchor),
            badges.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4)
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func configure(_ todo: Todo, textSize: Int = 14, toggle: @escaping () -> Void) {
        title.font = .systemFont(ofSize: CGFloat(textSize))
        onToggle = toggle
        check.state = todo.status == .completed ? .on : .off
        check.isEnabled = todo.deletedAt == nil
        check.setAccessibilityLabel("完成任务：\(todo.title)")
        title.stringValue = todo.title
        title.textColor = todo.status == .open ? .labelColor : .secondaryLabelColor
        var parts: [String] = []
        if todo.status == .canceled { parts.append("已取消") }
        if !todo.notes.isEmpty { parts.append("≡") }
        if !todo.checklist.isEmpty { parts.append("\(todo.checklist.filter { $0.completed }.count)/\(todo.checklist.count)") }
        if todo.repeatRule != nil { parts.append("↻") }
        if let reminder = todo.reminderDate { parts.append("提醒 " + reminder.formatted(.dateTime.month().day().hour().minute())) }
        parts.append(contentsOf: todo.tags.prefix(2).map { "#" + $0 })
        if let date = todo.deadline {
            parts.append("截止 " + date.formatted(.dateTime.month().day()))
            badges.textColor = date < Calendar.current.startOfDay(for: Date()) ? .systemRed : .secondaryLabelColor
        } else { badges.textColor = .secondaryLabelColor }
        badges.stringValue = parts.joined(separator: "  ")
        toolTip = ([todo.title, todo.notes] + todo.tags).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    @objc private func toggle() {
        // NSButton 已切换 state；先绘制反馈，避免同步持久化和观察者刷新阻塞勾号显示。
        check.needsDisplay = true
        check.displayIfNeeded()
        onToggle?()
    }
}

final class ListTableView: NSTableView {
    var headingDropBoundary: Int? {
        didSet { if oldValue != headingDropBoundary { needsDisplay = true } }
    }
    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        drawHeadingDropGap(in: clipRect)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        headingDropBoundary = nil
        super.draggingExited(sender)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        headingDropBoundary = nil
        super.draggingEnded(sender)
    }

    /// 宿主在 reload/行高变更后同步全文高度；不创建额外 row，也不重建编辑控件。
    var onContentHeightChanged: (() -> Void)?
    override func reloadData() {
        super.reloadData()
        onContentHeightChanged?()
    }
    override func noteHeightOfRows(withIndexesChanged indexSet: IndexSet) {
        super.noteHeightOfRows(withIndexesChanged: indexSet)
        onContentHeightChanged?()
    }
    override func scrollRowToVisible(_ row: Int) {
        if superview is ListScrollDocumentView { revealRowInDocument(row) }
        else { super.scrollRowToVisible(row) }
    }
    var editSelection: (() -> Void)?
    var deleteSelection: (() -> Void)?
    var clearSelection: (() -> Void)?
    var menuForRow: ((Int) -> NSMenu?)?
    var beforeMouseDown: ((Int, NSEvent) -> Bool)?
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        var candidate: NSView?
        if let field = responder as? NSTextField, field.isEditable { candidate = field }
        if let text = responder as? NSTextView, text.isEditable {
            candidate = text.isFieldEditor ? text.delegate as? NSTextField : text
        }
        if let field = candidate as? InlineTitleField, field.isEditingTitle { return true }
        if let view = candidate, view.isDescendant(of: self) {
            var parent: NSView? = view
            while let current = parent, current !== self {
                if current is InlineTaskEditorView { return true }
                parent = current.superview
            }
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }
    override func mouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard beforeMouseDown?(index, event) != false else { return }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { editSelection?() }
        else if event.keyCode == 51 || event.keyCode == 117 { deleteSelection?() }
        else if event.keyCode == 53 { clearSelection?() }
        else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { return nil }
        // 右键命中已选中的行时保留整个多选，否则批量菜单会被悄悄缩成单条。
        if !selectedRowIndexes.contains(index) { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        return menuForRow?(index)
    }
}

/// 内容始终使用普通语义文字色，避免系统强调选择将行内控件文字改为白色。
final class TaskListRowView: NSTableRowView {
    var isEditingCard = false
    /// 标题分组行选中时画整块浅蓝圆角底，并让标题视图收起分隔线和“＋”。
    var isHeadingRow = false
    override var isSelected: Bool { didSet { syncHeadingSelection() } }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func didAddSubview(_ subview: NSView) { super.didAddSubview(subview); syncHeadingSelection() }
    private func syncHeadingSelection() {
        for case let heading as ListHeadingView in subviews { heading.isRowSelected = isSelected }
        // 分隔线画在每个标题的底部；选中行（标题或待办）上方那条线属于上一行，要一起隐藏。
        guard let table = superview as? NSTableView else { return }
        let row = table.row(for: self)
        guard row >= 0 else { return }
        if row > 0, let above = table.rowView(atRow: row - 1, makeIfNecessary: false) {
            for case let heading as ListHeadingView in above.subviews { heading.isNextRowSelected = isSelected && !isEditingCard }
        }
        // 本行重建时，也要按下一行的选中状态决定自己的分隔线。
        if row + 1 < table.numberOfRows, let below = table.rowView(atRow: row + 1, makeIfNecessary: false) as? TaskListRowView {
            for case let heading as ListHeadingView in subviews { heading.isNextRowSelected = below.isSelected && !below.isEditingCard }
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, !isEditingCard else { return }
        if isHeadingRow {
            Appearance.selectionBackground.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 8, yRadius: 8).fill()
            return
        }
        // 待办行选中与标题分组、检查项一致：整块浅蓝圆角底，无描边。
        Appearance.selectionBackground.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class ListHeadingView: NSTableCellView {
    private var cachedDragPreview: (title: String, size: NSSize, image: NSImage)?
    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard onMore != nil else { return super.draggingImageComponents }
        let image: NSImage
        if let cached = cachedDragPreview, cached.title == titleField.stringValue, cached.size == bounds.size {
            image = cached.image
        } else {
            image = HeadingDragPreview.image(title: titleField.stringValue, size: bounds.size,
                                             textSize: Int(titleField.font?.pointSize ?? 14))
            cachedDragPreview = (titleField.stringValue, bounds.size, image)
        }
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = bounds.insetBy(dx: -HeadingDragPreview.margin, dy: -HeadingDragPreview.margin)
        return [component]
    }

    /// 所在行被选中：隐藏底部分隔线，与浅蓝选中底一致。
    var isRowSelected = false { didSet { if isRowSelected != oldValue { needsDisplay = true } } }
    /// 紧挨着的下一行是被选中的标题分组：本行底部分隔线正好在浅蓝底上方，需要隐藏。
    var isNextRowSelected = false { didSet { if isNextRowSelected != oldValue { needsDisplay = true } } }
    /// 项目内的标题分组可双击原地改名；其它分组标题（今天、日期等）只读。
    let titleField: InlineTitleField
    private var label: InlineTitleField { titleField }
    /// 「…」按钮：弹出标题操作菜单（存档、移动、转换为项目、删除），参数为菜单锚点。
    private let onMore: ((NSView) -> Void)?
    init(_ title: String, textSize: Int = 14, onMore: ((NSView) -> Void)? = nil,
         onTitleSave: ((String) -> Bool)? = nil) {
        self.onMore = onMore
        titleField = InlineTitleField(title: title)
        titleField.onSave = onTitleSave
        titleField.isRenameEnabled = onTitleSave != nil
        titleField.forwardsSelectionToTable = onTitleSave != nil
        titleField.setAccessibilityLabel("标题分组名称")
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: CGFloat(textSize), weight: .semibold)
        label.textColor = Appearance.blue
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        var titleEnd = trailingAnchor
        // 项目标题分组只保留「…」；新建待办用空格或底部「新建任务」按钮。
        if onMore != nil {
            let more = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "标题操作")!, target: self, action: #selector(showMore(_:)))
            more.isBordered = false
            more.contentTintColor = Appearance.blue
            more.setAccessibilityLabel("标题“\(title)”更多操作")
            more.toolTip = "更多操作"
            addSubview(more); more.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), more.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
                more.widthAnchor.constraint(equalToConstant: 24), more.heightAnchor.constraint(equalToConstant: 26)
            ])
            titleEnd = more.leadingAnchor
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: titleEnd, constant: -8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
        ])
        if onMore == nil { setAccessibilityElement(true); setAccessibilityLabel(title); setAccessibilityRole(.staticText) }
    }
    @objc private func showMore(_ sender: NSButton) { onMore?(sender) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !isRowSelected, !isNextRowSelected else { return }
        Appearance.listSeparator.setFill()
        NSRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: 0.5).fill()
    }
}

/// 保留NSButton的键盘和辅助功能行为，仅绘制轻量圆角复选框。
private final class TaskCheckButton: NSButton {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        if state == .on {
            (isEnabled ? Appearance.blue : NSColor.tertiaryLabelColor).setFill()
            outline.fill()
            NSColor.white.setStroke()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: rect.minX + 3, y: rect.midY))
            // NSButton 使用翻转坐标时 y 向下增长，勾号低点和右上端需要同步翻转。
            tick.line(to: NSPoint(x: rect.minX + 6, y: isFlipped ? rect.maxY - 4 : rect.minY + 4))
            tick.line(to: NSPoint(x: rect.maxX - 3, y: isFlipped ? rect.minY + 4 : rect.maxY - 4))
            tick.lineWidth = 1.4; tick.lineCapStyle = .round; tick.lineJoinStyle = .round; tick.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(isEnabled ? 0.32 : 0.16).setStroke()
            outline.lineWidth = 1; outline.stroke()
        }
    }
}

class ListBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.textBackgroundColor.setFill(); bounds.fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class ListToolbarView: ListBackgroundView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
    }
}
