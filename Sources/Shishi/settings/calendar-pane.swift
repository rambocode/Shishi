import AppKit

@MainActor final class CalendarSettingsPane: NSViewController {
    private let service: SystemIntegrations
    private let stack = NSStackView()
    private var observer: NSObjectProtocol?
    private var work: Task<Void, Never>?
    private var authorizationWork: Task<Void, Never>?
    private var pageActive = true
    init(service: SystemIntegrations) { self.service = service; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        configureIntegrationStack(stack, in: view)
        observer = NotificationCenter.default.addObserver(forName: SystemIntegrations.changed, object: service, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.pageActive else { return }; self.refresh() }
        }
        refresh()
    }
    deinit { work?.cancel(); authorizationWork?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func viewWillAppear() { super.viewWillAppear(); pageActive = true; refresh() }
    override func viewWillDisappear() {
        super.viewWillDisappear(); pageActive = false; work?.cancel(); work = nil
        authorizationWork?.cancel()
    }
    private func refresh() {
        work?.cancel(); clearIntegrationStack(stack)
        stack.addArrangedSubview(NSTextField(labelWithString: "系统日历 · 只读摘要"))
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: service.access(.calendar).message))
        if service.access(.calendar) != .authorized {
            let pending = service.isRequestingAccess(.calendar)
            let button = NSButton(title: pending ? "正在请求日历权限…" : "授权读取日历", target: self, action: #selector(authorize))
            button.isEnabled = !pending; stack.addArrangedSubview(button); return
        }
        let toggle = NSButton(checkboxWithTitle: "在今天和计划中显示日历事件", target: self, action: #selector(toggle(_:)))
        toggle.state = service.calendarEnabled ? .on : .off; stack.addArrangedSubview(toggle)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "计划显示未来 7 天；事件不会转换为待办，也不会写入系统日历。请选择要显示的日历："))
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let lists = try await service.lists(.calendar)
                guard !Task.isCancelled else { return }
                for list in lists {
                    let button = NSButton(checkboxWithTitle: list.title, target: self, action: #selector(selectCalendar(_:)))
                    button.identifier = NSUserInterfaceItemIdentifier(list.id)
                    button.state = service.calendarIDs.contains(list.id) ? .on : .off; stack.addArrangedSubview(button)
                }
            } catch { if !Task.isCancelled { stack.addArrangedSubview(NSTextField(wrappingLabelWithString: error.localizedDescription)) } }
        }
    }
    @objc private func authorize() {
        guard pageActive, !service.isRequestingAccess(.calendar) else { return }
        // Disable synchronously, before the asynchronous request can start.
        stack.arrangedSubviews.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = false }
        authorizationWork = Task { [weak self] in
            guard let self else { return }
            do { try await service.requestAccess(.calendar); if pageActive, !Task.isCancelled { refresh() } }
            catch { if pageActive, !Task.isCancelled { refresh(); stack.addArrangedSubview(NSTextField(wrappingLabelWithString: error.localizedDescription)) } }
        }
    }
    @objc private func toggle(_ sender: NSButton) { service.calendarEnabled = sender.state == .on }
    @objc private func selectCalendar(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var ids = service.calendarIDs; if sender.state == .on { ids.insert(id) } else { ids.remove(id) }; service.calendarIDs = ids
    }
}

@MainActor func clearIntegrationStack(_ stack: NSStackView) {
    for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
}
@MainActor func configureIntegrationStack(_ stack: NSStackView, in view: NSView) {
    let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
    stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 12
    scroll.documentView = stack; view.addSubview(scroll)
    scroll.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 24), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
        stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
    ])
}
