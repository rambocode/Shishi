import AppKit
import ShishiCore

/// 一级待办卡片；清单、标签、日期均只修改草稿，保存由列表事务协调。
final class InlineTaskEditorView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    let original: Todo
    let isNew: Bool
    private(set) var draft: Todo
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDetails: (() -> Void)?
    var onHeightChanged: (() -> Void)?
    var onChecklistSelectionChanged: (() -> Void)?
    var selectedChecklistItemID: UUID? { checklist.selectedItemID }
    private let titleField = NSTextField()
    private let completion = CardCompletionButton()
    private let notes = CardNotesView()
    private let checklist: InlineChecklistView
    private let status = NSTextField(labelWithString: "")
    private let error = NSTextField(wrappingLabelWithString: "")
    private let actions = NSStackView()
    private let paper = CardPaperView()
    private let suggestions: [String]
    private var checklistHeight: NSLayoutConstraint!
    private var noteHeight: NSLayoutConstraint!
    private var popover: NSPopover?
    private var notesHeight: CGFloat = 40
    private var titleHeight: CGFloat { max(24, (titleField.font?.pointSize ?? 14) + 8) }
    var rowHeight: CGFloat { 156 + titleHeight - 24 + notesHeight - 40 + checklist.preferredHeight }

    init(todo: Todo, isNew: Bool, tagSuggestions: [String] = [], textSize: Int = 14) {
        original = todo; draft = todo; self.isNew = isNew; suggestions = tagSuggestions
        checklist = InlineChecklistView(items: todo.checklist, textSize: textSize)
        super.init(frame: .zero)
        paper.translatesAutoresizingMaskIntoConstraints = false; addSubview(paper)
        titleField.stringValue = todo.title; titleField.placeholderString = "新建待办事项"
        titleField.font = .systemFont(ofSize: CGFloat(textSize), weight: .medium); titleField.textColor = .labelColor
        titleField.isBordered = false; titleField.drawsBackground = false; titleField.focusRingType = .none
        titleField.delegate = self; titleField.setAccessibilityLabel("任务标题")
        completion.title = ""; completion.setButtonType(.switch)
        completion.state = todo.status == .completed ? .on : .off
        completion.target = self; completion.action = #selector(completeParent)
        completion.setAccessibilityLabel("完成父待办")
        notes.string = todo.notes; notes.font = .systemFont(ofSize: CGFloat(textSize)); notes.textColor = .labelColor
        notes.drawsBackground = false; notes.isRichText = false; notes.allowsUndo = true
        notes.isAutomaticQuoteSubstitutionEnabled = false; notes.delegate = self; notes.setAccessibilityLabel("任务备注")
        notes.isVerticallyResizable = true; notes.isHorizontallyResizable = false; notes.autoresizingMask = [.width]
        notes.textContainer?.widthTracksTextView = true; notes.textContainer?.lineFragmentPadding = 0
        notes.textContainerInset = NSSize(width: 0, height: 2)
        let noteScroll = NSScrollView()
        noteScroll.drawsBackground = false; noteScroll.hasVerticalScroller = true; noteScroll.autohidesScrollers = true
        noteScroll.borderType = .noBorder; noteScroll.documentView = notes
        checklist.onChange = { [weak self] in self?.error.stringValue = "" }
        checklist.onSelectionChange = { [weak self] in self?.onChecklistSelectionChanged?() }
        checklist.onHeightChange = { [weak self] in self?.updateHeight() }
        checklist.onExit = { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self.titleField) }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        error.font = .systemFont(ofSize: 11); error.textColor = .systemRed; error.maximumNumberOfLines = 2
        actions.orientation = .horizontal; actions.spacing = 8; actions.alignment = .centerY
        let definitions: [(String, String, Selector)] = [
            ("calendar", "安排日期", #selector(showSchedule(_:))), ("repeat", "重复", #selector(showRepeat(_:))),
            ("tag", "添加标签", #selector(showTags(_:))),
            ("checklist", "添加检查列表", #selector(addChecklist)), ("flag", "设置截止日期", #selector(showDeadline(_:)))
        ]
        for definition in definitions {
            let button = CardToolButton(symbol: definition.0, title: definition.1)
            button.target = self; button.action = definition.2; actions.addArrangedSubview(button)
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        for child in [completion, titleField, noteScroll, checklist, status, error, actions] {
            child.translatesAutoresizingMaskIntoConstraints = false; paper.addSubview(child)
        }
        noteHeight = noteScroll.heightAnchor.constraint(equalToConstant: notesHeight)
        checklistHeight = checklist.heightAnchor.constraint(equalToConstant: checklist.preferredHeight)
        NSLayoutConstraint.activate([
            paper.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7), paper.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            paper.topAnchor.constraint(equalTo: topAnchor, constant: 7), paper.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            completion.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 12), completion.topAnchor.constraint(equalTo: paper.topAnchor, constant: 13),
            completion.widthAnchor.constraint(equalToConstant: 22), completion.heightAnchor.constraint(equalToConstant: 24),
            titleField.leadingAnchor.constraint(equalTo: completion.trailingAnchor, constant: 4), titleField.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -20),
            titleField.centerYAnchor.constraint(equalTo: completion.centerYAnchor), titleField.heightAnchor.constraint(equalToConstant: titleHeight),
            noteScroll.leadingAnchor.constraint(equalTo: titleField.leadingAnchor), noteScroll.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            noteScroll.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4), noteHeight,
            checklist.leadingAnchor.constraint(equalTo: titleField.leadingAnchor), checklist.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            checklist.topAnchor.constraint(equalTo: noteScroll.bottomAnchor, constant: 4), checklistHeight,
            actions.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -16), actions.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: titleField.leadingAnchor), status.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -10),
            error.leadingAnchor.constraint(equalTo: titleField.leadingAnchor), error.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            error.topAnchor.constraint(equalTo: checklist.bottomAnchor, constant: 3), error.bottomAnchor.constraint(lessThanOrEqualTo: actions.topAnchor, constant: -2)
        ])
        updateSummary()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    /// 已展开卡片是编辑区域，文本框点击不应继续交由 NSTableView 延迟焦点或执行父行双击。
    /// 仅放行本卡片内部的可编辑文字控件，普通列表行仍采用表格默认行为。
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let field = responder as? NSTextField, field.isDescendant(of: self), field.isEditable { return true }
        if let text = responder as? NSTextView {
            if text.isDescendant(of: self), text.isEditable { return true }
            if text.isFieldEditor, let field = text.delegate as? NSTextField,
               field.isDescendant(of: self), field.isEditable { return true }
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }
    func collect() -> Todo {
        draft.title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.notes = notes.string; draft.checklist = checklist.items
        return draft
    }
    func collectForSaving() -> Todo? {
        guard checklist.commitPendingInput() else { showError("检查列表输入尚未提交，请重试。"); return nil }
        if activeControl() != nil, let window {
            if let text = window.firstResponder as? NSTextView { text.unmarkText() }
            guard window.makeFirstResponder(nil) else { showError("当前输入未能提交，请完成输入后重试。"); return nil }
        }
        return collect()
    }
    func focusTitle() { window?.makeFirstResponder(titleField); if !isNew { titleField.selectText(nil) } }
    func activeControl() -> NSView? {
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) { return responder }
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSTextField, field.isDescendant(of: self) { return field }
        return nil
    }
    func showError(_ message: String) { error.stringValue = message }
    func controlTextDidBeginEditing(_ obj: Notification) { if (obj.object as? NSTextField) === titleField { checklist.clearSelection() } }
    func textDidBeginEditing(_ notification: Notification) { checklist.clearSelection() }
    @discardableResult func removeSelectedChecklistItem() -> Bool {
        guard checklist.commitPendingInput() else { return false }
        return checklist.removeSelectedItem()
    }
    func canMoveSelectedChecklistItem(by delta: Int) -> Bool { checklist.canMoveSelectedItem(by: delta) }
    @discardableResult func moveSelectedChecklistItem(by delta: Int) -> Bool {
        guard checklist.commitPendingInput() else { return false }
        return checklist.moveSelectedItem(by: delta)
    }
    func controlTextDidChange(_ obj: Notification) { draft.title = titleField.stringValue; error.stringValue = "" }
    func textDidChange(_ notification: Notification) { draft.notes = notes.string; notes.needsDisplay = true; updateHeight() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { onSave?(); return true }
        return false
    }
    override func layout() { super.layout(); updateHeight() }
    private func updateHeight() {
        guard checklistHeight != nil else { return }
        var desired: CGFloat = 40
        if let container = notes.textContainer, let manager = notes.layoutManager, !notes.string.isEmpty {
            manager.ensureLayout(for: container)
            desired = min(180, max(40, ceil(manager.usedRect(for: container).height) + 8))
        }
        let change = abs(notesHeight - desired) > 0.5 || abs(checklistHeight.constant - checklist.preferredHeight) > 0.5
        notesHeight = desired; noteHeight.constant = desired; checklistHeight.constant = checklist.preferredHeight
        if change { onHeightChanged?() }
    }
    @objc func addChecklist() { checklist.addItemAndFocus(); updateHeight() }
    @objc private func completeParent() {
        guard !titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion.state = .off; showError("请先填写待办标题。"); focusTitle(); return
        }
        draft.status = completion.state == .on ? .completed : .open
        draft.completedAt = draft.status == .completed ? Date() : nil; onSave?()
    }
    @objc private func showSchedule(_ sender: NSButton) {
        let controller = CardDatePopover(date: draft.startDate, isDeadline: false)
        controller.onChoice = { [weak self] choice in self?.applySchedule(choice); self?.popover?.performClose(nil) }
        show(controller, from: sender)
    }
    @objc private func showDeadline(_ sender: NSButton) {
        let controller = CardDatePopover(date: draft.deadline, isDeadline: true)
        controller.onChoice = { [weak self] choice in
            switch choice { case .date(let date): self?.draft.deadline = date; case .clear: self?.draft.deadline = nil; default: break }
            self?.draft.deadlineSuppressionDate = nil; self?.updateSummary(); self?.popover?.performClose(nil)
        }
        show(controller, from: sender)
    }
    /// 卡片内的重复设置只改草稿；保存仍由卡片统一提交，取消草稿时重复设置一并作废。
    @objc private func showRepeat(_ sender: NSButton) {
        let controller = TaskRepeatPopover(settings: TaskRepeatSettings.from(draft))
        controller.onSave = { [weak self] settings in
            guard let self else { return }
            self.draft = settings.applied(to: self.draft)
            self.updateSummary()
            self.popover?.performClose(nil)
        }
        controller.onCancel = { [weak self] in self?.popover?.performClose(nil) }
        show(controller, from: sender)
    }
    @objc private func showTags(_ sender: NSButton) {
        let controller = CardTagsPopover(tags: draft.tags, suggestions: suggestions)
        controller.onChange = { [weak self] values in self?.draft.tags = values; self?.updateSummary(); self?.popover?.performClose(nil) }
        show(controller, from: sender)
    }
    private func show(_ controller: NSViewController, from sender: NSView) {
        popover?.performClose(nil)
        let panel = NSPopover(); panel.behavior = .transient; panel.contentViewController = controller
        popover = panel; panel.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
    func applySchedule(_ choice: CardDateChoice) {
        draft.evening = false
        switch choice {
        case .today, .evening:
            draft.schedule = .dated; draft.startDate = Calendar.current.startOfDay(for: Date())
            if case .evening = choice { draft.evening = true }
        case .tomorrow: draft.schedule = .dated; draft.startDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
        case .date(let date): draft.schedule = .dated; draft.startDate = Calendar.current.startOfDay(for: date)
        case .someday: draft.schedule = .someday; draft.startDate = nil
        case .anytime, .clear: draft.schedule = .anytime; draft.startDate = nil
        }
        updateSummary()
    }
    private func updateSummary() {
        var parts: [String] = []
        if draft.schedule == .dated, let date = draft.startDate { parts.append(draft.evening ? "今晚" : Calendar.current.isDateInToday(date) ? "今天" : date.formatted(.dateTime.month().day())) }
        else if draft.schedule == .someday { parts.append("某天") }
        if let rule = draft.repeatRule { parts.append("↻ " + RepeatText.summary(rule)) }
        if let reminder = draft.reminderDate { parts.append("⏰ " + reminder.formatted(date: .omitted, time: .shortened)) }
        parts += draft.tags.map { "#" + $0 }
        if let deadline = draft.deadline { parts.append("⚑ " + deadline.formatted(.dateTime.month().day())) }
        status.stringValue = parts.joined(separator: "  "); status.toolTip = status.stringValue
    }
}
