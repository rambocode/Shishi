import AppKit

@MainActor final class QuickEntrySettingsPane: NSViewController {
    private let preferences: QuickEntryPreferences
    private weak var coordinator: QuickEntryCoordinator?
    private let enabled = NSButton(checkboxWithTitle: "启用全局快速输入快捷键", target: nil, action: nil)
    private let shortcut = NSPopUpButton(frame: .zero, pullsDown: false)
    private let destination = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(wrappingLabelWithString: "")
    convenience init(coordinator: QuickEntryCoordinator?) {
        self.init(preferences: .shared, coordinator: coordinator)
    }
    init(preferences: QuickEntryPreferences, coordinator: QuickEntryCoordinator?) {
        self.preferences = preferences; self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 560, height: 330)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: QuickEntryPreferences.changed, object: preferences)
        if let coordinator { NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: QuickEntryCoordinator.changed, object: coordinator) }
    }
    required init?(coder: NSCoder) { fatalError("使用 init(preferences:coordinator:)") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 330))
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24), stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24)])
        enabled.target = self; enabled.action = #selector(updateEnabled); enabled.font = .systemFont(ofSize: 13); stack.addArrangedSubview(enabled)
        shortcut.addItems(withTitles: QuickEntryShortcut.allCases.map(\.title)); shortcut.target = self; shortcut.action = #selector(updateShortcut)
        destination.addItems(withTitles: QuickEntryDestination.allCases.map(\.title)); destination.target = self; destination.action = #selector(updateDestination)
        for (label, control) in [("快捷键", shortcut), ("默认添加到", destination)] {
            let row = NSStackView(); row.spacing = 16
            let text = NSTextField(labelWithString: label); text.font = .systemFont(ofSize: 13); text.widthAnchor.constraint(equalToConstant: 92).isActive = true
            control.font = .systemFont(ofSize: 13); row.addArrangedSubview(text); row.addArrangedSubview(control); stack.addArrangedSubview(row)
        }
        let trial = NSButton(title: "试用快速输入…", target: self, action: #selector(tryEntry)); trial.bezelStyle = .rounded; trial.font = .systemFont(ofSize: 13); trial.isEnabled = coordinator != nil; stack.addArrangedSubview(trial)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; stack.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let note = NSTextField(wrappingLabelWithString: "自动填写：尚未接入。不会读取其他应用的选中文字。快捷键不需要辅助功能权限。取消或 Esc 会保留未提交的内容。")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note); note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        refresh()
    }
    @objc private func refresh() {
        guard isViewLoaded else { return }
        enabled.state = preferences.enabled ? .on : .off
        shortcut.selectItem(at: QuickEntryShortcut.allCases.firstIndex(of: preferences.shortcut) ?? 0)
        destination.selectItem(at: QuickEntryDestination.allCases.firstIndex(of: preferences.destination) ?? 0)
        status.stringValue = coordinator?.statusText ?? "快速输入尚未连接应用；未登记快捷键。"
    }
    @objc private func updateEnabled() { preferences.enabled = enabled.state == .on }
    @objc private func updateShortcut() { preferences.shortcut = QuickEntryShortcut.allCases[shortcut.indexOfSelectedItem] }
    @objc private func updateDestination() { preferences.destination = QuickEntryDestination.allCases[destination.indexOfSelectedItem] }
    @objc private func tryEntry() { coordinator?.show() }
    deinit { NotificationCenter.default.removeObserver(self) }
}
