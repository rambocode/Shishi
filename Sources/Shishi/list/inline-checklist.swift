import AppKit
import ShishiCore

/// 卡片内的独立草稿清单；不写入存储，也不改变父任务的完成状态。
@MainActor final class InlineChecklistView: NSView, NSTextFieldDelegate {
    var onChange: (() -> Void)?
    var onHeightChange: (() -> Void)?
    var onExit: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    private(set) var selectedItemID: UUID?
    /// 每个父清单持有独立且生命周期内不变的拖拽来源。
    let sourceID = UUID()
    private var rows: [ChecklistRow] = []
    private let textSize: Int
    private let scroll = NSScrollView()
    private let document = ChecklistDocument()
    var preferredHeight: CGFloat { min(220, CGFloat(rows.count) * 28) }
    var hasRows: Bool { !rows.isEmpty }

    /// 返回实际文本（不裁剪用户输入），排除纯空白占位；读取不结束编辑。
    var items: [ChecklistItem] {
        rows.compactMap { row in
            var item = row.item
            item.title = (row.field.currentEditor() as? NSTextView)?.string ?? row.field.stringValue
            item.completed = row.check.state == .on
            return isBlank(item.title) ? nil : item
        }
    }

    init(items: [ChecklistItem], textSize: Int = 14) {
        self.textSize = textSize
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.onValidateDrop = { [weak self] payload in self?.canAcceptDrop(payload) == true }
        document.onDrop = { [weak self] payload, index in self?.acceptDrop(payload, at: index) == true }
        addSubview(scroll)
        for item in items where !isBlank(item.title) { insert(item, at: rows.count) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutRows()
    }
    private func layoutRows() {
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: CGFloat(rows.count) * 28)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * 28, width: document.bounds.width, height: 28)
            row.needsLayout = true
        }
    }
    private func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func insert(_ item: ChecklistItem, at index: Int) {
        let row = ChecklistRow(item: item, sourceID: sourceID, textSize: textSize)
        row.field.delegate = self
        row.onSelect = { [weak self] in self?.select(item.id) }
        row.onToggle = { [weak self] in self?.select(item.id); self?.onChange?() }
        row.onMove = { [weak self, weak row] delta in
            guard let self, let row, let index = self.rows.firstIndex(where: { $0 === row }) else { return }
            self.move(at: index, delta: delta)
        }
        rows.insert(row, at: index)
        document.addSubview(row)
    }
    private func changed(from oldHeight: CGFloat) {
        layoutRows()
        needsLayout = true
        if oldHeight != preferredHeight { onHeightChange?() }
        onChange?()
    }
    private func focus(_ row: ChecklistRow) {
        select(row.item.id)
        layoutRows()
        document.scrollToVisible(row.frame)
        window?.makeFirstResponder(row.field)
        if let editor = row.field.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
    }
    func addItemAndFocus() {
        if let last = rows.last, isBlank(last.field.stringValue) { focus(last); return }
        let height = preferredHeight
        insert(ChecklistItem(title: ""), at: rows.count)
        changed(from: height)
        if let last = rows.last { focus(last) }
    }
    /// 仅提交本组件持有的共享 field editor；拒绝结束编辑时返回 false，保留草稿。
    func commitPendingInput() -> Bool {
        for row in rows {
            guard let editor = row.field.currentEditor() as? NSTextView else { continue }
            editor.unmarkText()
            row.field.stringValue = editor.string
            if let window, !window.makeFirstResponder(nil) { return false }
        }
        // 保存前兜底处理未发出 change 通知的多行粘贴。
        for row in rows.reversed() { splitLines(in: row) }
        return true
    }
    private func select(_ id: UUID?) {
        guard selectedItemID != id else { return }
        selectedItemID = id
        for row in rows { row.isSelected = row.item.id == id }
        onSelectionChange?()
    }
    func clearSelection() { select(nil) }
    @discardableResult func removeSelectedItem() -> Bool {
        guard let id = selectedItemID, let index = rows.firstIndex(where: { $0.item.id == id }) else { return false }
        return remove(at: index, focusNeighbor: false)
    }
    func canMoveSelectedItem(by delta: Int) -> Bool {
        guard let id = selectedItemID, let index = rows.firstIndex(where: { $0.item.id == id }) else { return false }
        let (destination, overflow) = index.addingReportingOverflow(delta)
        return !overflow && delta != 0 && rows.indices.contains(destination)
    }
    @discardableResult func moveSelectedItem(by delta: Int) -> Bool {
        guard canMoveSelectedItem(by: delta), let index = rows.firstIndex(where: { $0.item.id == selectedItemID }) else { return false }
        move(at: index, delta: delta)
        return true
    }
    /// Drop 只接受本父清单中仍存在的稳定项 ID；插入位置为移动前的行间边界。
    func canAcceptDrop(_ payload: ChecklistDragPayload) -> Bool {
        payload.sourceID == sourceID && rows.contains { $0.item.id == payload.itemID }
    }
    @discardableResult func acceptDrop(_ payload: ChecklistDragPayload, at insertionIndex: Int) -> Bool {
        guard canAcceptDrop(payload), (0...rows.count).contains(insertionIndex),
              let index = rows.firstIndex(where: { $0.item.id == payload.itemID }) else { return false }
        let destination = insertionIndex > index ? insertionIndex - 1 : insertionIndex
        select(payload.itemID)
        if destination != index {
            let row = rows.remove(at: index)
            rows.insert(row, at: destination)
            layoutRows()
            onChange?()
        }
        return true
    }
    @discardableResult private func remove(at index: Int, focusNeighbor: Bool = true) -> Bool {
        let row = rows[index]
        if let editor = row.field.currentEditor() as? NSTextView {
            guard !editor.hasMarkedText(), window?.makeFirstResponder(nil) != false else { return false }
        }
        let height = preferredHeight
        rows.remove(at: index).removeFromSuperview()
        if selectedItemID == row.item.id { clearSelection() }
        changed(from: height)
        if focusNeighbor, !rows.isEmpty { focus(rows[max(0, index - 1)]) }
        return true
    }
    private func move(at index: Int, delta: Int) {
        let (destination, overflow) = index.addingReportingOverflow(delta)
        guard !overflow, rows.indices.contains(destination), destination != index else { return }
        let row = rows.remove(at: index)
        rows.insert(row, at: destination)
        layoutRows()
        onChange?()
        focus(rows[destination])
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let row = rows.first(where: { $0.field === field }) else { return }
        select(row.item.id)
        if let editor = field.currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.insertionPointColor = .labelColor
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let row = rows.first(where: { $0.field === field }) else { return }
        if let editor = field.currentEditor() as? NSTextView {
            guard !editor.hasMarkedText() else { return }
            field.stringValue = editor.string
        }
        if !splitLines(in: row) { onChange?() }
    }
    @discardableResult private func splitLines(in row: ChecklistRow) -> Bool {
        let text = row.field.stringValue
        guard text.rangeOfCharacter(from: .newlines) != nil,
              let index = rows.firstIndex(where: { $0 === row }) else { return false }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines).filter { !isBlank($0) }
        let height = preferredHeight
        row.field.stringValue = lines.first ?? ""
        if let editor = row.field.currentEditor() as? NSTextView { editor.string = row.field.stringValue }
        for (offset, line) in lines.dropFirst().enumerated() {
            insert(ChecklistItem(title: line), at: index + offset + 1)
        }
        changed(from: height)
        return true
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let index = rows.firstIndex(where: { $0.field === control }) else { return false }
        select(rows[index].item.id)
        // IME 候选确认留给 AppKit，不能变成新建行或删除行。
        guard !textView.hasMarkedText() else { return false }
        let row = rows[index]
        row.field.stringValue = textView.string
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if isBlank(textView.string) { remove(at: index); onExit?() }
            else {
                let height = preferredHeight
                insert(ChecklistItem(title: ""), at: index + 1)
                changed(from: height)
                focus(rows[index + 1])
            }
            return true
        }
        if commandSelector == #selector(NSResponder.deleteBackward(_:)), isBlank(textView.string) {
            remove(at: index)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) || commandSelector == #selector(NSResponder.moveDown(_:)),
           NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            move(at: index, delta: commandSelector == #selector(NSResponder.moveUp(_:)) ? -1 : 1)
            return true
        }
        return false
    }
}
