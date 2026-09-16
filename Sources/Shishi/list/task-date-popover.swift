import AppKit
import ShishiCore

/// 放入 transient NSPopover.contentViewController；onApply 仅在磁盘保存成功时返回 true。
/// 父级在成功回调内关闭 popover；外部关闭可调用 cancelDraft()，它永不提交任务。
@MainActor
final class TaskDatePopover: NSViewController, NSTextFieldDelegate {
    var onApply: ((Todo) -> Bool)?
    var onCancel: (() -> Void)?
    var onReminderCommit: (() -> Void)?
    private let original: Todo
    private var draft: Todo
    private var inputModel = TaskDateInput()
    private var pageIndex = 0
    private var finished = false
    private var expanded = false
    private let stack = NSStackView()
    private let grid = NSStackView()
    private let reminderRows = NSStackView()
    private let input = NSTextField()
    private let reminderDay = NSTextField()
    private let reminderTime = NSTextField()
    private let feedback = NSTextField(labelWithString: "")

    init(todo: Todo) {
        original = todo; draft = todo
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.28, alpha: 1).cgColor
        panel.layer?.cornerRadius = 12
        panel.appearance = NSAppearance(named: .darkAqua)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(equalToConstant: 300),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14)
        ])
        configure(input, placeholder: "时间", label: "任务日期")
        input.alignment = .center
        input.isBordered = false; input.drawsBackground = false
        add(input)
        add(symbolButton("今天", symbol: "star.fill", color: .systemYellow, action: #selector(todayChosen)))
        add(symbolButton("今晚", symbol: "moon.fill", color: NSColor(calibratedRed: 0.65, green: 0.78, blue: 1, alpha: 1), action: #selector(eveningChosen)))
        grid.orientation = .vertical; grid.spacing = 4
        add(grid)
        add(symbolButton("某天", symbol: "archivebox.fill", color: .systemYellow, action: #selector(somedayChosen)))
        // 与卡片弹窗保持同一套选项：没有「清除安排」就只能靠右键菜单取消日期。
        add(symbolButton("清除安排", symbol: "xmark.circle.fill", color: .secondaryLabelColor, action: #selector(clearChosen)))
        reminderRows.orientation = .vertical; reminderRows.alignment = .leading; reminderRows.spacing = 8
        add(reminderRows)
        feedback.font = .systemFont(ofSize: 11); feedback.textColor = .systemRed
        feedback.maximumNumberOfLines = 2
        feedback.setAccessibilityLabel("日期反馈")
        add(feedback)
        view = panel
        rebuildGrid(); rebuildReminder(); resize()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(input)
    }

    private func add(_ child: NSView) {
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func configure(_ field: NSTextField, placeholder: String, label: String) {
        field.placeholderString = placeholder; field.font = .systemFont(ofSize: 13)
        field.delegate = self; field.setAccessibilityLabel(label)
    }

    private func button(_ title: String, action: Selector, color: NSColor = .labelColor) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.isBordered = false; result.alignment = .left
        result.font = .systemFont(ofSize: 15, weight: .medium); result.contentTintColor = color
        result.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return result
    }

    private func symbolButton(_ title: String, symbol: String, color: NSColor, action: Selector) -> NSButton {
        let result = button(title, action: action)
        result.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [color]))
        result.imagePosition = .imageLeading
        result.contentTintColor = nil
        result.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13)
        ])
        result.setAccessibilityLabel(title)
        return result
    }

    private func clear(_ rows: NSStackView) {
        for child in rows.arrangedSubviews { rows.removeArrangedSubview(child); child.removeFromSuperview() }
    }

    private func rebuildGrid() {
        clear(grid)
        let dates = inputModel.page(pageIndex)
        guard dates.count == 28 else { return }
        let formatter = DateFormatter(); formatter.calendar = inputModel.calendar
        formatter.timeZone = inputModel.calendar.timeZone; formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        let heading = NSTextField(labelWithString: "\(inputModel.calendar.component(.month, from: dates[0]))月 · \(inputModel.calendar.component(.month, from: dates[27]))月")
        heading.font = .systemFont(ofSize: 11); heading.textColor = .secondaryLabelColor
        grid.addArrangedSubview(heading)
        for rowIndex in -1..<4 {
            let row = NSStackView(); row.distribution = .fillEqually; row.spacing = 2
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            for column in 0..<7 {
                if rowIndex == -1 {
                    let label = NSTextField(labelWithString: ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][column])
                    label.alignment = .center; label.font = .systemFont(ofSize: 10); label.textColor = .secondaryLabelColor
                    row.addArrangedSubview(label)
                } else {
                    let index = rowIndex * 7 + column; let date = dates[index]
                    let today = inputModel.calendar.isDate(date, inSameDayAs: inputModel.today)
                    let cell = button(today ? "★" : String(inputModel.calendar.component(.day, from: date)), action: #selector(dateChosen(_:)), color: today ? .systemYellow : .labelColor)
                    cell.alignment = .center; cell.tag = index
                    cell.isEnabled = date >= inputModel.today
                    cell.setAccessibilityLabel(formatter.string(from: date))
                    cell.wantsLayer = true; cell.layer?.cornerRadius = 5
                    if let selected = draft.startDate, draft.schedule == .dated, inputModel.calendar.isDate(date, inSameDayAs: selected) {
                        cell.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.25, blue: 0.43, alpha: 1).cgColor
                        cell.state = .on
                    }
                    row.addArrangedSubview(cell)
                }
            }
        }
        let navigation = NSStackView(); navigation.distribution = .fillEqually
        let back = button("‹", action: #selector(previousPage)); back.isEnabled = pageIndex > 0; back.setAccessibilityLabel("前四周")
        let next = button("›", action: #selector(nextPage)); next.alignment = .right; next.setAccessibilityLabel("后四周")
        navigation.addArrangedSubview(back); navigation.addArrangedSubview(next)
        grid.addArrangedSubview(navigation); navigation.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
    }

    private func rebuildReminder() {
        clear(reminderRows)
        if expanded {
            configure(reminderDay, placeholder: "yyyy-MM-dd", label: "提醒日期")
            configure(reminderTime, placeholder: "HH:mm", label: "提醒时间")
            reminderRows.addArrangedSubview(reminderDay); reminderRows.addArrangedSubview(reminderTime)
            let actions = NSStackView()
            actions.addArrangedSubview(button("取消", action: #selector(cancelReminder)))
            actions.addArrangedSubview(button("保存时间", action: #selector(saveReminder)))
            reminderRows.addArrangedSubview(actions)
        } else {
            let title = draft.reminderDate.map { "提醒：" + display($0, format: "M月d日 HH:mm") } ?? "添加提醒"
            reminderRows.addArrangedSubview(symbolButton(title, symbol: "plus", color: .secondaryLabelColor, action: #selector(expandReminder)))
            if draft.reminderDate != nil { reminderRows.addArrangedSubview(button("移除提醒", action: #selector(removeReminder))) }
        }
        for child in reminderRows.arrangedSubviews { child.widthAnchor.constraint(equalTo: reminderRows.widthAnchor).isActive = true }
        resize()
    }

    private func display(_ date: Date, format: String) -> String {
        let formatter = DateFormatter(); formatter.calendar = inputModel.calendar
        formatter.timeZone = inputModel.calendar.timeZone; formatter.dateFormat = format
        return formatter.string(from: date)
    }
    private func resize() { preferredContentSize = NSSize(width: 300, height: stack.fittingSize.height + 28) }
    private func fail(_ message: String) { feedback.stringValue = message; resize() }

    private func submit() {
        guard !finished else { return }
        guard onApply?(draft) == true else { fail("保存失败，请重试"); return }
        finished = true
    }
    private func choose(_ selection: TaskDateSelection) {
        guard !finished else { return }
        draft = inputModel.applying(selection, to: draft)
        rebuildGrid(); submit()
    }
    @objc private func todayChosen() { choose(.dated(inputModel.today, evening: false)) }
    @objc private func eveningChosen() { choose(.dated(inputModel.today, evening: true)) }
    @objc private func somedayChosen() { choose(.someday) }
    @objc private func clearChosen() { choose(.clear) }
    @objc private func dateChosen(_ sender: NSButton) {
        let dates = inputModel.page(pageIndex)
        guard dates.indices.contains(sender.tag), dates[sender.tag] >= inputModel.today else { return }
        choose(.dated(dates[sender.tag], evening: false))
    }
    @objc private func previousPage() { pageIndex = max(0, pageIndex - 1); rebuildGrid(); resize() }
    @objc private func nextPage() { guard pageIndex < 9_999 else { return }; pageIndex += 1; rebuildGrid(); resize() }
    @objc private func expandReminder() {
        expanded = true
        let date = draft.reminderDate ?? draft.startDate ?? inputModel.today
        reminderDay.stringValue = display(date, format: "yyyy-MM-dd")
        reminderTime.stringValue = draft.reminderDate.map { display($0, format: "HH:mm") } ?? "09:00"
        rebuildReminder()
    }
    @objc private func cancelReminder() { expanded = false; feedback.stringValue = ""; rebuildReminder() }
    @objc private func saveReminder() {
        guard !finished else { return }
        inputModel.now = Date()
        guard let date = inputModel.reminder(dateText: reminderDay.stringValue, timeText: reminderTime.stringValue) else {
            fail("请输入有效且晚于当前时间的提醒日期和 HH:mm 时间"); return
        }
        draft.reminderDate = date
        submit()
        if finished { onReminderCommit?() }
    }
    @objc private func removeReminder() { guard !finished else { return }; draft.reminderDate = nil; submit() }

    @objc func cancelDraft() {
        guard !finished else { return }
        finished = true; draft = original; onCancel?()
    }
    override func cancelOperation(_ sender: Any?) { cancelDraft() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelDraft(); return true }
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if control === reminderDay || control === reminderTime { saveReminder(); return true }
        guard control === input else { return false }
        guard let selection = inputModel.parse(input.stringValue) else { fail("无法识别日期，请输入今天、周几或有效日期"); return true }
        choose(selection); return true
    }
}
