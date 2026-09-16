import AppKit
import ShishiCore

/// 重复面板的六种选择；每种固定周期锁定一个单位，"完成后" 允许自由选单位。
enum TaskRepeatMode: Int, CaseIterable {
    case none, afterCompletion, daily, weekly, monthly, yearly
    var title: String {
        switch self {
        case .none: return "不重复"
        case .afterCompletion: return "完成后"
        case .daily: return "每天"
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .yearly: return "每年"
        }
    }
    /// 固定周期模式对应的单位；"完成后" 与 "不重复" 由面板另行决定。
    var fixedUnit: RepeatUnit? {
        switch self {
        case .daily: return .day
        case .weekly: return .week
        case .monthly: return .month
        case .yearly: return .year
        default: return nil
        }
    }
    /// 由既有规则推断面板初始模式。
    static func mode(for rule: RepeatRule?) -> TaskRepeatMode {
        guard let rule else { return .none }
        if rule.afterCompletion { return .afterCompletion }
        switch rule.unit {
        case .day: return .daily
        case .week: return .weekly
        case .month: return .monthly
        case .year: return .yearly
        }
    }
}

/// Things 风格的待办重复面板：顶部选重复方式，中间设间隔，下面可另外附加提醒和截止日期。
/// 面板只产出 TaskRepeatSettings，写回任务由调用方完成，卡片草稿与列表右键因此共用同一面板。
@MainActor
final class TaskRepeatPopover: NSViewController, NSTextFieldDelegate {
    var onSave: ((TaskRepeatSettings) -> Void)?
    var onCancel: (() -> Void)?

    private let initial: TaskRepeatSettings
    private let mode = NSPopUpButton()
    private let interval = NSTextField()
    private let unit = NSPopUpButton()
    private let caption = NSTextField(labelWithString: "")
    private let box = NSView()
    private let reminderToggle = NSButton(checkboxWithTitle: "添加提醒", target: nil, action: nil)
    private let reminderPicker = NSDatePicker()
    private let deadlineToggle = NSButton(checkboxWithTitle: "添加截止日期", target: nil, action: nil)
    private let deadlineField = NSTextField()
    private let deadlineSuffix = NSTextField(labelWithString: "天后")
    private let error = NSTextField(wrappingLabelWithString: "")
    private let units: [(String, RepeatUnit)] = [("天", .day), ("周", .week), ("月", .month), ("年", .year)]
    private var finished = false

    init(settings: TaskRepeatSettings) {
        initial = settings
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        stack.addArrangedSubview(header())
        stack.addArrangedSubview(intervalBox())
        stack.addArrangedSubview(reminderRow())
        stack.addArrangedSubview(deadlineRow())

        error.font = .systemFont(ofSize: 11)
        error.textColor = .systemRed
        error.maximumNumberOfLines = 2
        stack.addArrangedSubview(error)

        let actions = NSStackView()
        actions.spacing = 8
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelChosen))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let confirm = NSButton(title: "好", target: self, action: #selector(submit))
        confirm.bezelStyle = .rounded
        confirm.keyEquivalent = "\r"
        actions.addArrangedSubview(cancel)
        actions.addArrangedSubview(confirm)
        stack.addArrangedSubview(actions)

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 320),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            actions.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            box.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = container
        applyInitialValues()
        modeChanged()
        preferredContentSize = view.fittingSize
    }

    private func header() -> NSView {
        let row = NSStackView()
        row.spacing = 6
        let icon = NSImageView(image: NSImage(systemSymbolName: "repeat", accessibilityDescription: "重复")!)
        icon.contentTintColor = Appearance.blue
        let label = NSTextField(labelWithString: "重复")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        mode.addItems(withTitles: TaskRepeatMode.allCases.map(\.title))
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setAccessibilityLabel("重复方式")
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        row.addArrangedSubview(mode)
        return row
    }

    /// 间隔区做成浅色圆角块，与 Things 的“1 周 上一项结束后”一行保持同样的视觉分组。
    private func intervalBox() -> NSView {
        let row = NSStackView()
        row.spacing = 8
        interval.alignment = .center
        interval.font = .systemFont(ofSize: 13)
        interval.delegate = self
        interval.setAccessibilityLabel("重复间隔")
        unit.addItems(withTitles: units.map(\.0))
        unit.target = self
        unit.action = #selector(fieldChanged)
        unit.setAccessibilityLabel("重复单位")
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        row.addArrangedSubview(interval)
        row.addArrangedSubview(unit)
        row.addArrangedSubview(caption)
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            interval.widthAnchor.constraint(equalToConstant: 46),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10)
        ])
        return box
    }

    private func reminderRow() -> NSView {
        let row = NSStackView()
        row.spacing = 8
        reminderToggle.target = self
        reminderToggle.action = #selector(fieldChanged)
        reminderToggle.font = .systemFont(ofSize: 13)
        reminderPicker.datePickerStyle = .textFieldAndStepper
        reminderPicker.datePickerElements = [.hourMinute]
        reminderPicker.font = .systemFont(ofSize: 13)
        reminderPicker.setAccessibilityLabel("提醒时间")
        row.addArrangedSubview(reminderToggle)
        row.addArrangedSubview(reminderPicker)
        return row
    }

    private func deadlineRow() -> NSView {
        let row = NSStackView()
        row.spacing = 8
        deadlineToggle.target = self
        deadlineToggle.action = #selector(fieldChanged)
        deadlineToggle.font = .systemFont(ofSize: 13)
        deadlineField.alignment = .center
        deadlineField.font = .systemFont(ofSize: 13)
        deadlineField.delegate = self
        deadlineField.setAccessibilityLabel("截止日期天数")
        deadlineSuffix.font = .systemFont(ofSize: 12)
        deadlineSuffix.textColor = .secondaryLabelColor
        row.addArrangedSubview(deadlineToggle)
        row.addArrangedSubview(deadlineField)
        row.addArrangedSubview(deadlineSuffix)
        deadlineField.widthAnchor.constraint(equalToConstant: 46).isActive = true
        return row
    }

    private func applyInitialValues() {
        let current = TaskRepeatMode.mode(for: initial.rule)
        mode.selectItem(at: current.rawValue)
        interval.stringValue = String(initial.rule?.interval ?? 1)
        let selectedUnit = initial.rule?.unit ?? .day
        unit.selectItem(at: units.firstIndex { $0.1 == selectedUnit } ?? 0)
        reminderToggle.state = initial.reminder != nil ? .on : .off
        var components = DateComponents(hour: initial.reminder?.hour ?? 9, minute: initial.reminder?.minute ?? 0)
        components.year = 2000; components.month = 1; components.day = 1
        reminderPicker.dateValue = Calendar.current.date(from: components) ?? Date()
        deadlineToggle.state = initial.deadlineOffsetDays != nil ? .on : .off
        deadlineField.stringValue = String(initial.deadlineOffsetDays ?? 0)
    }

    private var selectedMode: TaskRepeatMode { TaskRepeatMode(rawValue: mode.indexOfSelectedItem) ?? .none }

    @objc private func modeChanged() {
        let current = selectedMode
        if let fixed = current.fixedUnit { unit.selectItem(at: units.firstIndex { $0.1 == fixed } ?? 0) }
        let repeats = current != .none
        interval.isEnabled = repeats
        unit.isEnabled = current == .afterCompletion
        reminderToggle.isEnabled = repeats
        deadlineToggle.isEnabled = repeats
        caption.stringValue = current == .afterCompletion ? "上一项完成后" : (repeats ? "从开始日期起" : "")
        fieldChanged()
    }

    @objc private func fieldChanged() {
        let repeats = selectedMode != .none
        reminderPicker.isEnabled = repeats && reminderToggle.state == .on
        deadlineField.isEnabled = repeats && deadlineToggle.state == .on
        deadlineSuffix.textColor = deadlineField.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        error.stringValue = ""
    }

    func controlTextDidChange(_ obj: Notification) { error.stringValue = "" }

    @objc private func cancelChosen() {
        guard !finished else { return }
        finished = true
        onCancel?()
    }

    @objc private func submit() {
        guard !finished else { return }
        let current = selectedMode
        guard current != .none else {
            finished = true
            onSave?(TaskRepeatSettings())
            return
        }
        guard let count = Int(interval.stringValue.trimmingCharacters(in: .whitespaces)), (1...10000).contains(count) else {
            error.stringValue = "重复间隔必须是 1 到 10000 之间的整数。"
            return
        }
        let chosenUnit = current.fixedUnit ?? units[max(0, min(unit.indexOfSelectedItem, units.count - 1))].1
        var settings = TaskRepeatSettings(rule: RepeatRule(unit: chosenUnit, interval: count, afterCompletion: current == .afterCompletion))
        if reminderToggle.state == .on {
            settings.reminder = Calendar.current.dateComponents([.hour, .minute], from: reminderPicker.dateValue)
        }
        if deadlineToggle.state == .on {
            guard let days = Int(deadlineField.stringValue.trimmingCharacters(in: .whitespaces)), (0...3650).contains(days) else {
                error.stringValue = "截止日期天数必须是 0 到 3650 之间的整数。"
                return
            }
            settings.deadlineOffsetDays = days
        }
        finished = true
        onSave?(settings)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelChosen(); return true }
        return false
    }
}
