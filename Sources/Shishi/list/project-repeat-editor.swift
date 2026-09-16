import AppKit
import ShishiCore

/// 重复规则只作为草稿编辑；保存成功后由调用方关闭弹窗，失败时保留输入。
@MainActor
final class ProjectRepeatEditor: NSViewController {
    var onSave: ((RepeatRule?) -> Bool)?
    var onCancel: (() -> Void)?
    private let initial: RepeatRule?
    private let unit = NSPopUpButton()
    private let interval = NSTextField(string: "1")
    private let afterCompletion = NSButton(checkboxWithTitle: "完成后重复", target: nil, action: nil)
    private let error = NSTextField(wrappingLabelWithString: "")

    init(rule: RepeatRule?) { initial = rule; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        unit.addItems(withTitles: ["不重复", "天", "周", "月", "年"])
        unit.selectItem(at: initial.map { (RepeatUnit.allCases.firstIndex(of: $0.unit) ?? 0) + 1 } ?? 0)
        unit.target = self; unit.action = #selector(selectionChanged)
        unit.setAccessibilityLabel("重复周期")
        interval.stringValue = String(initial?.interval ?? 1)
        interval.setAccessibilityLabel("重复间隔")
        afterCompletion.state = initial?.afterCompletion == true ? .on : .off
        let row = NSStackView(views: [NSTextField(labelWithString: "每"), interval, unit])
        row.spacing = 8
        interval.widthAnchor.constraint(equalToConstant: 60).isActive = true
        stack.addArrangedSubview(row); stack.addArrangedSubview(afterCompletion)
        error.textColor = .systemRed; error.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(error)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "完成", target: self, action: #selector(submit))
        save.keyEquivalent = "\r"
        stack.addArrangedSubview(NSStackView(views: [cancel, save]))
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 280),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        view = container; selectionChanged(); preferredContentSize = view.fittingSize
    }

    @objc private func selectionChanged() {
        interval.isEnabled = unit.indexOfSelectedItem > 0
        afterCompletion.isEnabled = interval.isEnabled
    }

    @objc private func submit() {
        let rule: RepeatRule?
        if unit.indexOfSelectedItem == 0 { rule = nil }
        else {
            guard let value = Int(interval.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0,
                  RepeatUnit.allCases.indices.contains(unit.indexOfSelectedItem - 1) else {
                error.stringValue = "重复间隔必须是正整数。"; return
            }
            rule = RepeatRule(unit: RepeatUnit.allCases[unit.indexOfSelectedItem - 1], interval: value,
                              afterCompletion: afterCompletion.state == .on)
        }
        error.stringValue = ""
        _ = onSave?(rule)
    }

    @objc private func cancel() { onCancel?() }
}
