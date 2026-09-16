import AppKit
import ShishiCore

@MainActor
final class GeneralSettingsPane: NSViewController {
    private let preferences: GeneralPreferences
    private let store: TaskStore
    private let archive = NSPopUpButton()
    private let dock = NSPopUpButton()
    private let theme = NSPopUpButton()
    private let size = NSSlider(value: 14, minValue: 11, maxValue: 20, target: nil, action: nil)
    private let grouping = NSButton(checkboxWithTitle: "按项目或区域分组“今天”列表中的待办事项", target: nil, action: nil)
    private let feedback = NSTextField(wrappingLabelWithString: "")
    init(store: TaskStore, preferences: GeneralPreferences? = nil) {
        self.store = store; self.preferences = preferences ?? store.preferences; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func loadView() {
        view = NSView(); let stack = SettingsLayout.stack(in: view)
        archive.addItems(withTitles: ArchiveTiming.allCases.map(\.title))
        archive.selectItem(at: ArchiveTiming.allCases.firstIndex(of: preferences.archiveTiming) ?? 0)
        archive.target = self; archive.action = #selector(changeArchive); archive.setAccessibilityLabel("将完成的项移到日志簿")
        dock.addItems(withTitles: DockCountMode.allCases.map(\.title))
        dock.selectItem(at: DockCountMode.allCases.firstIndex(of: preferences.dockCount) ?? 0)
        dock.target = self; dock.action = #selector(changeDock); dock.setAccessibilityLabel("Dock 计数")
        theme.addItems(withTitles: ["自动", "浅色", "深色"]); theme.selectItem(at: preferences.appearance)
        theme.target = self; theme.action = #selector(changeTheme); theme.setAccessibilityLabel("外观")
        size.numberOfTickMarks = 10; size.allowsTickMarkValuesOnly = true
        size.widthAnchor.constraint(equalToConstant: 155).isActive = true
        size.integerValue = preferences.textSize; size.isContinuous = false
        size.target = self; size.action = #selector(changeSize); size.setAccessibilityLabel("文字大小")
        let reset = NSButton(title: "默认", target: self, action: #selector(resetSize))
        let sizeRow = NSStackView(views: [SettingsLayout.label("A", size: 11), size, SettingsLayout.label("A", size: 18), reset])
        sizeRow.orientation = .horizontal; sizeRow.spacing = 8
        let grid = NSGridView(views: [
            [SettingsLayout.label("将完成的项移到日志簿："), archive],
            [SettingsLayout.label("Dock 计数："), dock],
            [SettingsLayout.label("外观："), theme],
            [SettingsLayout.label("文字大小："), sizeRow]
        ])
        grid.rowSpacing = 20; grid.columnSpacing = 12; grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 275; grid.column(at: 1).xPlacement = .fill; grid.rowAlignment = .firstBaseline
        for popup in [archive, dock, theme] { popup.widthAnchor.constraint(equalToConstant: 275).isActive = true }
        stack.addArrangedSubview(grid); stack.addArrangedSubview(SettingsLayout.separator())
        grouping.state = preferences.groupToday ? .on : .off; grouping.target = self; grouping.action = #selector(changeGrouping)
        stack.addArrangedSubview(grouping)
        stack.addArrangedSubview(SettingsLayout.note("更改会自动保存。字号应用于任务与列表；正在编辑的内容会保留，结束编辑后刷新字号。"))
        stack.addArrangedSubview(NSButton(title: "立即归档已完成项", target: self, action: #selector(archiveNow)))
        feedback.font = .systemFont(ofSize: 12); feedback.textColor = .secondaryLabelColor
        stack.addArrangedSubview(feedback); stack.addArrangedSubview(SettingsLayout.separator())
        stack.addArrangedSubview(SettingsLayout.note("当前侧栏调整保持窗口宽度。Spotlight、URL Scheme、快捷指令批量操作及自动更新尚未接入，本版本不提供无效开关。"))
    }
    @objc private func changeArchive() { preferences.archiveTiming = ArchiveTiming.allCases[archive.indexOfSelectedItem] }
    @objc private func changeDock() { preferences.dockCount = DockCountMode.allCases[dock.indexOfSelectedItem] }
    @objc private func changeTheme() { preferences.appearance = theme.indexOfSelectedItem; Appearance.apply(preferences) }
    @objc private func changeSize() { preferences.textSize = size.integerValue }
    @objc private func resetSize() { size.integerValue = 14; changeSize() }
    @objc private func changeGrouping() { preferences.groupToday = grouping.state == .on }
    @objc private func archiveNow() {
        let success = store.archiveCompletedItems()
        feedback.textColor = success ? .secondaryLabelColor : .systemRed
        feedback.stringValue = success ? "已完成项已归档，可在日志簿查看；可通过撤销恢复。" : (store.errorMessage ?? "归档失败，请重试。")
    }
}

/// 设置窗口使用系统固定字号，避免修改阅读字号时控件自身跳动。
@MainActor enum SettingsLayout {
    static func stack(in view: NSView) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28)
        ]); return stack
    }
    static func label(_ text: String, size: CGFloat = 13) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: size); return field
    }
    static func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor; field.preferredMaxLayoutWidth = 535
        return field
    }
    static func separator() -> NSBox {
        let box = NSBox(); box.boxType = .separator; box.widthAnchor.constraint(equalToConstant: 535).isActive = true; return box
    }
}
