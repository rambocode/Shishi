import AppKit

@MainActor final class RemindersSettingsPane: NSViewController {
    private let service: SystemIntegrations
    private let store: TaskStore
    private let stack = NSStackView()
    private let previewStack = NSStackView()
    private var observer: NSObjectProtocol?
    private var work: Task<Void, Never>?
    private var authorizationWork: Task<Void, Never>?
    private var pageActive = true
    private var records: [ReminderRecord] = []
    private var selected: Set<String> = []
    private var generation = 0
    init(service: SystemIntegrations, store: TaskStore) {
        self.service = service; self.store = store; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 460)); configureIntegrationStack(stack, in: view)
        observer = NotificationCenter.default.addObserver(forName: SystemIntegrations.changed, object: service, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.pageActive else { return }; self.refresh() }
        }
        refresh()
    }
    deinit { work?.cancel(); authorizationWork?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func viewWillAppear() { super.viewWillAppear(); pageActive = true; refresh() }
    override func viewWillDisappear() {
        super.viewWillDisappear(); pageActive = false; generation += 1
        work?.cancel(); work = nil; authorizationWork?.cancel()
        records = []; selected = []; clearIntegrationStack(previewStack)
    }
    private func refresh() {
        generation += 1; work?.cancel(); records = []; selected = []; clearIntegrationStack(stack)
        stack.addArrangedSubview(NSTextField(labelWithString: "系统提醒事项"))
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "与 Things 的处理方式不同：导入会复制到独立的 Shishi 库，保留系统中的原提醒事项，不删除、不完成原记录。重复导入跳过已导入项，保留本地编辑。"))
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: service.access(.reminders).message))
        guard service.access(.reminders) == .authorized else {
            let pending = service.isRequestingAccess(.reminders)
            let button = NSButton(title: pending ? "正在请求提醒事项权限…" : "授权读取提醒事项", target: self, action: #selector(authorize))
            button.isEnabled = !pending; stack.addArrangedSubview(button); return
        }
        let token = generation
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let lists = try await service.lists(.reminders)
                guard !Task.isCancelled, token == generation else { return }
                for list in lists {
                    let button = NSButton(checkboxWithTitle: list.title, target: self, action: #selector(selectList(_:)))
                    button.identifier = NSUserInterfaceItemIdentifier(list.id); button.state = service.reminderIDs.contains(list.id) ? .on : .off
                    stack.addArrangedSubview(button)
                }
                let button = NSButton(title: "预览所选列表的未完成提醒", target: self, action: #selector(preview))
                button.isEnabled = !service.reminderIDs.isEmpty; stack.addArrangedSubview(button)
                previewStack.orientation = .vertical; previewStack.alignment = .leading; previewStack.spacing = 8
                clearIntegrationStack(previewStack); stack.addArrangedSubview(previewStack)
            } catch { if !Task.isCancelled { show(error.localizedDescription) } }
        }
    }
    private func show(_ message: String) { stack.addArrangedSubview(NSTextField(wrappingLabelWithString: message)) }
    @objc private func authorize() {
        guard pageActive, !service.isRequestingAccess(.reminders) else { return }
        stack.arrangedSubviews.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = false }
        authorizationWork = Task { [weak self] in
            guard let self else { return }
            do { try await service.requestAccess(.reminders); if pageActive, !Task.isCancelled { refresh() } }
            catch { if pageActive, !Task.isCancelled { refresh(); show(error.localizedDescription) } }
        }
    }
    @objc private func selectList(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var ids = service.reminderIDs; if sender.state == .on { ids.insert(id) } else { ids.remove(id) }; service.reminderIDs = ids
    }
    @objc private func preview() {
        guard pageActive else { return }
        // Clear obsolete controls immediately. Only this click starts reminder I/O.
        work?.cancel(); generation += 1; let token = generation
        records = []; selected = []; clearIntegrationStack(previewStack)
        previewStack.addArrangedSubview(NSTextField(labelWithString: "正在读取…"))
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await service.previewReminders()
                guard !Task.isCancelled, token == generation else { return }
                records = value
                clearIntegrationStack(previewStack)
                previewStack.addArrangedSubview(NSTextField(labelWithString: "\(value.count) 条未完成提醒；勾选需要导入的记录。"))
                for record in value {
                    let button = NSButton(checkboxWithTitle: record.title, target: self, action: #selector(selectRecord(_:)))
                    button.identifier = NSUserInterfaceItemIdentifier(record.id); previewStack.addArrangedSubview(button)
                }
                previewStack.addArrangedSubview(NSButton(title: "导入勾选提醒到 Shishi", target: self, action: #selector(importSelected)))
                previewStack.addArrangedSubview(NSButton(title: "重新预览", target: self, action: #selector(preview)))
            } catch { if !Task.isCancelled, token == generation { show(error.localizedDescription); stack.addArrangedSubview(NSButton(title: "重试预览", target: self, action: #selector(preview))) } }
        }
    }
    @objc private func selectRecord(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if sender.state == .on { selected.insert(id) } else { selected.remove(id) }
    }
    @objc private func importSelected() {
        guard pageActive else { return }
        guard !selected.isEmpty else { show("请先勾选需要导入的提醒。"); return }
        do {
            let count = try service.importReminders(records.filter { selected.contains($0.id) }, into: store)
            show("已导入 \(count) 条；已导入的来源已跳过。原提醒事项保持不变。")
        } catch { show("导入失败，可再次点击重试。\(error.localizedDescription)") }
    }
}
