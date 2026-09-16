import AppKit

/// 开始安排与截止日期由调用方分别解释；clear 仅清除当前弹出框对应的日期。
enum CardDateChoice: Equatable {
    case today, evening, tomorrow, anytime, someday, date(Date), clear
}

/// 只返回草稿选择，不读写任务；展示及关闭 NSPopover 由父卡片负责。
@MainActor
final class CardDatePopover: NSViewController {
    var onChoice: ((CardDateChoice) -> Void)?
    private let initialDate: Date?
    private let isDeadline: Bool
    private let picker = NSDatePicker()

    init(date: Date?, isDeadline: Bool) {
        initialDate = date
        self.isDeadline = isDeadline
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let stack = cardPopoverStack()
        if !isDeadline {
            let shortcuts = NSStackView()
            shortcuts.spacing = 3
            for (index, title) in ["今天", "今晚", "明天", "随时", "某天"].enumerated() {
                let button = cardPopoverButton(title, target: self, action: #selector(shortcutChosen(_:)))
                button.tag = index
                shortcuts.addArrangedSubview(button)
            }
            stack.addArrangedSubview(shortcuts)
        }
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay]
        picker.font = .systemFont(ofSize: 13)
        // 初值先于 target/action 设置，加载或重开弹出框不会提交日期。
        picker.dateValue = initialDate ?? Date()
        picker.setAccessibilityLabel(isDeadline ? "截止日期" : "开始日期")
        picker.target = self
        picker.action = #selector(dateChosen(_:))
        stack.addArrangedSubview(picker)
        stack.addArrangedSubview(cardPopoverButton(isDeadline ? "清除截止" : "清除安排", target: self, action: #selector(clearChosen)))
        view = cardPopoverContainer(stack)
        preferredContentSize = view.fittingSize
    }

    @objc private func shortcutChosen(_ sender: NSButton) {
        let choices: [CardDateChoice] = [.today, .evening, .tomorrow, .anytime, .someday]
        guard choices.indices.contains(sender.tag) else { return }
        onChoice?(choices[sender.tag])
    }

    @objc private func dateChosen(_ sender: NSDatePicker) { onChoice?(.date(sender.dateValue)) }
    @objc private func clearChosen() { onChoice?(.clear) }
}

/// 标签勾选、删除、输入都只修改本地草稿；Return/完成提交，取消不通知调用方。
@MainActor
final class CardTagsPopover: NSViewController, NSTextFieldDelegate {
    var onChange: (([String]) -> Void)?
    private var draft: [String]
    private let suggestions: [String]
    private let input = NSTextField()
    private let tagRows = cardPopoverStack()
    private var finished = false

    init(tags: [String], suggestions: [String]) {
        draft = Self.normalized(tags)
        self.suggestions = Self.normalized(suggestions)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let stack = cardPopoverStack()
        input.font = .systemFont(ofSize: 13)
        input.placeholderString = "添加标签，以逗号分隔"
        input.setAccessibilityLabel("添加标签")
        input.delegate = self
        stack.addArrangedSubview(input)
        input.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(tagRows)
        tagRows.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let actions = NSStackView()
        actions.spacing = 6
        let cancel = cardPopoverButton("取消", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        actions.addArrangedSubview(cancel)
        actions.addArrangedSubview(cardPopoverButton("完成", target: self, action: #selector(submit)))
        stack.addArrangedSubview(actions)
        view = cardPopoverContainer(stack)
        rebuildTags()
    }

    private static func normalized(_ tags: [String]) -> [String] {
        var result: [String] = []
        for value in tags {
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty && !result.contains(tag) { result.append(tag) }
        }
        return result
    }

    private func rebuildTags() {
        for row in tagRows.arrangedSubviews {
            tagRows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for (index, tag) in draft.enumerated() {
            let row = NSStackView()
            row.spacing = 6
            let label = NSTextField(labelWithString: tag)
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let remove = cardPopoverButton("移除", target: self, action: #selector(removeTag(_:)))
            remove.tag = index
            remove.setAccessibilityLabel("移除标签：" + tag)
            row.addArrangedSubview(label)
            row.addArrangedSubview(remove)
            tagRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: tagRows.widthAnchor).isActive = true
        }
        for (index, tag) in suggestions.enumerated() {
            let button = NSButton(checkboxWithTitle: tag, target: self, action: #selector(toggleSuggestion(_:)))
            button.font = .systemFont(ofSize: 13)
            button.state = draft.contains(tag) ? .on : .off
            button.tag = index
            button.cell?.lineBreakMode = .byTruncatingTail
            tagRows.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: tagRows.widthAnchor).isActive = true
        }
        preferredContentSize = view.fittingSize
    }

    @objc private func removeTag(_ sender: NSButton) {
        guard !finished, draft.indices.contains(sender.tag) else { return }
        draft.remove(at: sender.tag)
        rebuildTags()
    }

    @objc private func toggleSuggestion(_ sender: NSButton) {
        guard !finished, suggestions.indices.contains(sender.tag) else { return }
        let tag = suggestions[sender.tag]
        if sender.state == .on {
            draft = Self.normalized(draft + [tag])
        } else {
            draft.removeAll { $0 == tag }
        }
        rebuildTags()
    }

    @objc private func submit() {
        guard !finished else { return }
        finished = true
        // 同时接受中文逗号；保留标签顺序并消除空项与重复项。
        let entered = input.stringValue.components(separatedBy: CharacterSet(charactersIn: ",，"))
        draft = Self.normalized(draft + entered)
        onChange?(draft)
        dismiss(nil)
    }

    @objc private func cancel() {
        finished = true
        dismiss(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === input else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }
}

@MainActor
private func cardPopoverButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.font = .systemFont(ofSize: 13)
    return button
}

@MainActor
private func cardPopoverStack() -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    return stack
}

@MainActor
private func cardPopoverContainer(_ stack: NSStackView) -> NSView {
    let container = NSView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalToConstant: 280),
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
        stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
    ])
    return container
}
