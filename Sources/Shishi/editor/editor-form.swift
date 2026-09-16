import AppKit
import Foundation

/// 所有输入保存在控件和调用方草稿中；底部操作固定，长表单独立滚动。
private final class FlippedFormStack: NSStackView {
    override var isFlipped: Bool { true }
}

class EditorFormController: NSViewController {
    let form: NSStackView = FlippedFormStack()
    let feedback = NSTextField(wrappingLabelWithString: "")
    private var actions: [() -> Void] = []
    private weak var initialFocus: NSTextField?
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 520))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 9
        form.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)
        scroll.documentView = form
        let save = button("保存", action: { [weak self] in self?.finishInputAndSave() })
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        let cancel = button("取消", action: { [weak self] in self?.cancelDraft() })
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        feedback.textColor = .systemRed
        let footer = NSStackView(views: [feedback, cancel, save])
        footer.orientation = .horizontal
        footer.spacing = 12
        for item in [scroll, footer] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        form.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            form.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        buildForm()
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window, let initialFocus,
              window.makeFirstResponder(initialFocus) else {
            error("无法聚焦标题输入框，请点击输入框后编辑。"); return
        }
    }
    private func finishInputAndSave() {
        // 先提交当前 field editor 和输入法内容；控件拒绝结束编辑时不得落盘。
        guard let window = view.window, window.makeFirstResponder(nil) else {
            error("当前输入尚未提交，请检查输入内容后重试。"); return
        }
        guard let initialFocus, window.makeFirstResponder(initialFocus) else {
            error("无法恢复编辑焦点，请点击标题输入框后重试。"); return
        }
        saveDraft()
    }
    func buildForm() {}
    func saveDraft() {}
    func cancelDraft() {}
    func row(_ title: String, _ control: NSView) {
        let stack = section(title, control)
        form.addArrangedSubview(stack)
        stack.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -48).isActive = true
    }
    func titleStyle(_ field: NSTextField) {
        field.font = .systemFont(ofSize: 20, weight: .bold)
        initialFocus = field
    }
    func pair(_ firstTitle: String, _ first: NSView, _ secondTitle: String, _ second: NSView) {
        let left = section(firstTitle, first)
        let right = section(secondTitle, second)
        let line = NSStackView(views: [left, right])
        line.orientation = .horizontal; line.alignment = .top; line.spacing = 16
        line.distribution = .fillEqually
        form.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -48).isActive = true
    }
    private func section(_ title: String, _ control: NSView) -> NSStackView {
        control.setAccessibilityLabel(title)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
    func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(performAction(_:)))
        button.tag = actions.count; actions.append(action)
        return button
    }
    @objc private func performAction(_ sender: NSButton) { actions[sender.tag]() }
    func error(_ message: String) { feedback.stringValue = message }
}

final class OptionalDateField: NSStackView {
    let enabled = NSButton(checkboxWithTitle: "设置日期", target: nil, action: nil)
    let picker = NSDatePicker()
    private let calendarButton = NSButton(title: "", target: nil, action: nil)
    private let popover = NSPopover()
    private let calendar = NSDatePicker()
    var onChange: (() -> Void)?
    var date: Date? { enabled.state == .on ? picker.dateValue : nil }
    init(_ value: Date?) {
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 6
        picker.datePickerStyle = .textFieldAndStepper
        picker.controlSize = .small
        picker.datePickerElements = [.yearMonthDay]
        picker.dateValue = value ?? Date()
        enabled.state = value == nil ? .off : .on
        enabled.target = self; enabled.action = #selector(changed)
        picker.target = self; picker.action = #selector(changed)
        picker.setAccessibilityLabel("日历日期")
        enabled.title = "日期"
        enabled.controlSize = .small
        calendarButton.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "打开日历")
        calendarButton.bezelStyle = .texturedRounded
        calendarButton.setAccessibilityLabel("打开日历选择日期")
        calendarButton.target = self; calendarButton.action = #selector(showCalendar)
        calendar.datePickerStyle = .clockAndCalendar
        calendar.datePickerElements = [.yearMonthDay]
        calendar.target = self; calendar.action = #selector(calendarChanged)
        calendar.setAccessibilityLabel("日历日期选择")
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 190))
        calendar.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(calendar)
        NSLayoutConstraint.activate([
            calendar.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 12),
            calendar.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -12),
            calendar.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 12),
            calendar.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -12)
        ])
        popover.contentViewController = controller; popover.behavior = .transient
        addArrangedSubview(enabled); addArrangedSubview(picker); addArrangedSubview(calendarButton)
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func update() { picker.isEnabled = enabled.state == .on }
    @objc private func changed() { update(); onChange?() }
    @objc private func showCalendar() {
        calendar.dateValue = picker.dateValue
        popover.show(relativeTo: calendarButton.bounds, of: calendarButton, preferredEdge: .maxY)
    }
    @objc private func calendarChanged() {
        set(calendar.dateValue); onChange?(); popover.performClose(nil)
    }
    func set(_ date: Date?) { enabled.state = date == nil ? .off : .on; if let date { picker.dateValue = date }; update() }
}

/// 原生多行文本编辑器，保留换行并支持系统编辑快捷键。
final class NotesField: NSScrollView {
    private let text = NSTextView()
    var stringValue: String {
        get { text.string }
        set { text.string = newValue }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true; borderType = .bezelBorder
        text.isRichText = false; text.font = .systemFont(ofSize: 14)
        text.allowsUndo = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.setAccessibilityLabel("备注或说明")
        documentView = text
        heightAnchor.constraint(equalToConstant: 64).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
