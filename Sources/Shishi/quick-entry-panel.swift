import AppKit
import ShishiCore

enum QuickEntryTerminationChoice { case cancel, save, discard }

/// 可脱离窗口测试的草稿事务。取消只隐藏，失败不清空；成功才重置。
@MainActor final class QuickEntryDraft {
    var title = ""
    var notes = ""
    var destination: QuickEntryDestination
    private(set) var message = ""
    private(set) var isPresented = false
    init(destination: QuickEntryDestination) { self.destination = destination }
    func present() { isPresented = true }
    func cancel() { isPresented = false }
    var isEmpty: Bool { title.isEmpty && notes.isEmpty }

    /// 与窗口无关的退出决策；隐藏状态不影响保护，未指定决策时默认取消。
    func prepareToTerminate(store: TaskStore, route: Route, choice: QuickEntryTerminationChoice = .cancel) -> Bool {
        guard !isEmpty else { return true }
        switch choice {
        case .cancel: return false
        case .save: return save(store: store, route: route)
        case .discard:
            title = ""; notes = ""; message = ""; isPresented = false
            return true
        }
    }

    @discardableResult func save(store: TaskStore, route: Route, now: Date = Date()) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { message = "请输入任务标题。"; return false }
        var todo = Todo(title: trimmed, notes: notes)
        var fallback = false
        let target: Route = destination == .inbox ? .inbox : destination == .today ? .today : route
        switch target {
        case .inbox: break
        case .today: todo.schedule = .dated; todo.startDate = Calendar.current.startOfDay(for: now)
        case .anytime: todo.schedule = .anytime
        case .someday: todo.schedule = .someday
        case .project(let id):
            if let project = store.projects.first(where: { $0.id == id && $0.deletedAt == nil && !$0.completed && ($0.status == nil || $0.status == .open) }) {
                todo.projectID = id; todo.areaID = project.areaID; todo.schedule = .anytime
            } else { fallback = true }
        case .area(let id):
            if store.areas.contains(where: { $0.id == id }) { todo.areaID = id; todo.schedule = .anytime }
            else { fallback = true }
        case .tag(let tag):
            if store.allTags.contains(tag) { todo.tags = [tag]; todo.schedule = .anytime }
            else { fallback = true }
        case .upcoming, .logbook, .trash, .search: fallback = true
        }
        guard store.save(todo) else { message = store.errorMessage ?? "任务保存失败，请重试。"; return false }
        title = ""; notes = ""; isPresented = false
        message = fallback ? "当前列表已失效或无法添加，任务已保存到收件箱。" : "任务已添加。"
        return true
    }
}

/// nonactivatingPanel 可直接接收键盘输入，不要求切换主窗口或读取其他应用内容。
@MainActor final class QuickEntryPanel: NSPanel, NSWindowDelegate {
    private let store: TaskStore
    private let currentRoute: () -> Route
    private let preferences: QuickEntryPreferences
    let draft: QuickEntryDraft
    var saved: ((String) -> Void)?
    private let titleField = NSTextField(string: "")
    private let notesField = NSTextView()
    private let destinationField = NSPopUpButton(frame: .zero, pullsDown: false)
    private let messageField = NSTextField(wrappingLabelWithString: "")
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(store: TaskStore, currentRoute: @escaping () -> Route, preferences: QuickEntryPreferences) {
        self.store = store; self.currentRoute = currentRoute; self.preferences = preferences
        draft = QuickEntryDraft(destination: preferences.destination)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 330), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "快速录入"; level = .floating; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]; delegate = self
        let root = NSView(); contentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)])
        titleField.placeholderString = "任务标题"; titleField.font = .systemFont(ofSize: 16)
        titleField.setAccessibilityLabel("快速录入任务标题")
        stack.addArrangedSubview(titleField); titleField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let notesLabel = NSTextField(labelWithString: "备注"); notesLabel.font = .systemFont(ofSize: 13); stack.addArrangedSubview(notesLabel)
        let scroll = NSScrollView(); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        notesField.isRichText = false; notesField.font = .systemFont(ofSize: 13)
        notesField.setAccessibilityLabel("快速录入任务备注")
        notesField.isVerticallyResizable = true; notesField.isHorizontallyResizable = false
        notesField.autoresizingMask = [.width]; notesField.textContainer?.widthTracksTextView = true
        scroll.documentView = notesField; stack.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true; scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        destinationField.addItems(withTitles: QuickEntryDestination.allCases.map(\.title)); destinationField.font = .systemFont(ofSize: 13)
        destinationField.setAccessibilityLabel("快速录入添加目标")
        destinationField.target = self; destinationField.action = #selector(destinationChanged)
        stack.addArrangedSubview(destinationField)
        messageField.font = .systemFont(ofSize: 12); messageField.textColor = .secondaryLabelColor
        stack.addArrangedSubview(messageField); messageField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let buttons = NSStackView(); buttons.spacing = 12
        let add = NSButton(title: "添加", target: self, action: #selector(addTask)); add.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelAction)); cancel.keyEquivalent = "\u{1b}"
        for button in [cancel, add] { button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 13); buttons.addArrangedSubview(button) }
        stack.addArrangedSubview(buttons); defaultButtonCell = add.cell as? NSButtonCell
        center()
    }
    func present() {
        // 已显示时保持正在编辑的控件内容；关闭再打开时恢复原草稿。
        if !isVisible {
            if draft.isEmpty { draft.destination = preferences.destination }
            titleField.stringValue = draft.title; notesField.string = draft.notes
            destinationField.selectItem(at: QuickEntryDestination.allCases.firstIndex(of: draft.destination) ?? 0)
        }
        messageField.stringValue = draft.message.isEmpty && draft.destination == .currentList ? "当前列表在添加时校验；失效或无法添加时保存到收件箱。" : draft.message
        // 保留独立 nonactivatingPanel 样式，同时主动激活应用，确保显式打开后
        // 原生文本控件获得键盘焦点，也便于辅助功能客户端定位输入控件。
        NSApp.activate(ignoringOtherApps: true)
        draft.present(); makeKeyAndOrderFront(nil); makeFirstResponder(titleField)
    }
    private func capture() {
        draft.title = titleField.stringValue; draft.notes = notesField.string
        draft.destination = QuickEntryDestination.allCases[max(0, destinationField.indexOfSelectedItem)]
    }
    @objc private func destinationChanged() {
        messageField.stringValue = destinationField.indexOfSelectedItem == 2 ? "当前列表在添加时校验；失效或无法添加时保存到收件箱。" : ""
    }
    @objc private func addTask() {
        capture()
        guard draft.save(store: store, route: currentRoute()) else { messageField.stringValue = draft.message; return }
        finishSaving()
    }
    private func finishSaving() {
        titleField.stringValue = ""; notesField.string = ""; orderOut(nil)
        saved?(draft.message)
    }
    /// 同步询问以供 applicationShouldTerminate 使用；Return 默认取消退出。
    func prepareToTerminate() -> Bool {
        if isVisible { capture() }
        guard !draft.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "快速录入有未提交的内容"
        alert.informativeText = "退出前是否保存这份草稿？丢弃后无法恢复。"
        let cancel = alert.addButton(withTitle: "取消退出")
        let save = alert.addButton(withTitle: "保存并退出")
        let discard = alert.addButton(withTitle: "丢弃并退出")
        cancel.keyEquivalent = "\r"
        save.keyEquivalent = ""; discard.keyEquivalent = ""
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        alert.window.standardWindowButton(.closeButton)?.isEnabled = false
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let choice: QuickEntryTerminationChoice
        switch response {
        case .alertSecondButtonReturn: choice = .save
        case .alertThirdButtonReturn: choice = .discard
        default: choice = .cancel
        }
        guard draft.prepareToTerminate(store: store, route: currentRoute(), choice: choice) else {
            if choice == .save { present() }
            return false
        }
        if choice == .save { finishSaving() }
        else { titleField.stringValue = ""; notesField.string = ""; orderOut(nil) }
        return true
    }
    func cancelDraft() { capture(); draft.cancel(); orderOut(nil) }
    @objc private func cancelAction() { cancelDraft() }
    override func cancelOperation(_ sender: Any?) { cancelDraft() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelDraft(); return false }
}
