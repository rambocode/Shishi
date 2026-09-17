import AppKit
import ShishiCore

/// representedObject 强持有动作及其 target，菜单关闭后仍可安全执行已选动作。
@MainActor
private final class ProjectMenuAction: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
    @objc func run(_ sender: NSMenuItem) { perform() }
}

@MainActor
final class ProjectActionsController: NSObject {
    var onNavigate: ((Route) -> Void)?
    var onChanged: (() -> Void)?
    private let store: TaskStore
    private weak var anchor: NSView?
    private var popover: NSPopover?
    private var sharingPicker: NSSharingServicePicker?
    private var pendingCompletions = Set<UUID>()
    private let scheduleCompletion: (@escaping () -> Void) -> Void

    init(store: TaskStore, scheduleCompletion: @escaping (@escaping () -> Void) -> Void = {
        DispatchQueue.main.async(execute: $0)
    }) {
        self.store = store
        self.scheduleCompletion = scheduleCompletion
        super.init()
    }

    func show(projectID: UUID, from view: NSView) {
        anchor = view
        buildMenu(projectID: projectID).popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
    }

    /// 入口共享最新快照；弹窗打开期间不写盘，选择后再读取项目和剩余任务。
    func toggleCompletion(projectID: UUID, from view: NSView?) {
        guard let value = editable(projectID) else { return }
        if let view { anchor = view }
        if isClosed(value) {
            if store.setProjectCompleted(projectID, completed: false) { onChanged?() } else { showError() }
            return
        }
        let count = ProjectSummary(project: value, tasks: store.todos).openCount
        if count == 0 { finish(projectID, status: .completed); return }
        guard anchor?.window != nil else { return }
        guard let editor = completionPrompt(projectID: projectID, from: view) else { return }
        present(editor)
    }

    /// 构造与真实入口相同的确认界面；取消不保存，提交时使用最新任务树而非弹窗旧副本。
    func completionPrompt(projectID: UUID, from view: NSView? = nil) -> ProjectCompletionController? {
        if let view { anchor = view }
        guard let value = editable(projectID), !isClosed(value) else { return nil }
        let count = ProjectSummary(project: value, tasks: store.todos).openCount
        guard count > 0 else { return nil }
        let editor = ProjectCompletionController(openCount: count)
        editor.onChoice = { [weak self] status in
            guard let self else { return }
            // 确认后立即移除弹窗，避免关闭动画与同步保存争用主线程。
            popover?.animates = false
            popover?.close()
            if let status { finish(projectID, status: status) }
        }
        return editor
    }

    private func finish(_ id: UUID, status: TaskStatus) {
        guard let value = editable(id), !isClosed(value), !pendingCompletions.contains(id) else { return }
        let progress = anchor as? ProjectProgressView
        if status == .completed { progress?.showCompletionCheckmark() }
        let needsDeferredSave = anchor?.window != nil
        pendingCompletions.insert(id)
        let save = { [self, weak progress] in
            defer { pendingCompletions.remove(id) }
            // 提交时重新校验，不能用弹窗打开时的旧快照覆盖后续改动。
            guard let current = editable(id), !isClosed(current) else { return }
            if store.finishProjectWithFeedback(id, status: status) { onChanged?() }
            else {
                if let current = editable(id), let progress, progress.projectID == id {
                    progress.configure(project: current, summary: ProjectSummary(project: current, tasks: store.todos))
                }
                showError()
            }
        }
        // 先让按钮事件结束、关闭窗口及勾号呈现，再执行持久化和同步观察者刷新。
        if needsDeferredSave { scheduleCompletion(save) } else { save() }
    }

    /// 无有效项目时返回空菜单；废纸篓项目禁用修改及分享，恢复由既有废纸篓负责。
    func buildMenu(projectID: UUID) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        guard let project = project(projectID) else { return menu }
        let enabled = project.deletedAt == nil
        add(isClosed(project) ? "重新打开项目" : "完成项目", icon: "checkmark.circle", to: menu, enabled: enabled, deferPresentation: anchor != nil) { [self] in
            toggleCompletion(projectID: projectID, from: anchor)
        }
        add("时间", icon: "calendar", to: menu, enabled: enabled, deferPresentation: true) { [self] in
            if let anchor { showDate(projectID: projectID, from: anchor) }
        }
        add("添加标签", icon: "tag", to: menu, enabled: enabled, deferPresentation: true) { [self] in showTags(projectID) }
        add("添加截止日期", icon: "flag", to: menu, enabled: enabled, deferPresentation: true) { [self] in showDeadline(projectID) }
        menu.addItem(.separator())
        add("移动", icon: "arrow.right", to: menu, enabled: enabled, deferPresentation: true) { [self] in
            if let anchor { showMove(projectID: projectID, from: anchor) }
        }
        add("重复…", icon: "repeat", to: menu, enabled: enabled && !isClosed(project), deferPresentation: true) { [self] in showRepeat(projectID) }
        add("复制项目", icon: "doc.on.doc", to: menu, enabled: enabled) { [self] in
            guard editable(projectID) != nil else { return }
            if let id = store.duplicateProject(projectID) { onChanged?(); onNavigate?(.project(id)) }
            else { showError() }
        }
        add("删除项目", icon: "trash", to: menu, enabled: enabled, deferPresentation: true) { [self] in confirmDeletion(projectID) }
        add("分享…", icon: "square.and.arrow.up", to: menu, enabled: enabled, deferPresentation: true) { [self] in share(projectID) }
        return menu
    }

    func showDate(projectID: UUID, from view: NSView) {
        anchor = view
        guard let value = editable(projectID) else { return }
        let editor = CardDatePopover(date: value.startDate, isDeadline: false)
        editor.onChoice = { [weak self] choice in
            guard let self else { return }
            if applyDate(choice, projectID: projectID, deadline: false) { popover?.performClose(nil) }
        }
        present(editor)
    }

    func showMove(projectID: UUID, from view: NSView) {
        anchor = view
        guard let value = editable(projectID) else { return }
        let menu = NSMenu(title: "移动"); menu.autoenablesItems = false
        add("无区域", icon: "tray", to: menu) { [self] in move(projectID, areaID: nil) }
        menu.items.last?.state = value.areaID == nil ? .on : .off
        for area in store.areas {
            add(area.title, icon: "square.stack", to: menu) { [self] in move(projectID, areaID: area.id) }
            menu.items.last?.state = value.areaID == area.id ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
    }

    @discardableResult
    func applyDate(_ choice: CardDateChoice, projectID: UUID, deadline: Bool) -> Bool {
        update(projectID) { value in
            if deadline {
                switch choice {
                case .date(let date): value.deadline = Calendar.current.startOfDay(for: date)
                case .clear: value.deadline = nil
                default: break
                }
                return
            }
            value.evening = false
            switch choice {
            case .today, .evening:
                value.schedule = .dated; value.startDate = Calendar.current.startOfDay(for: Date())
                value.evening = choice == .evening
            case .tomorrow:
                value.schedule = .dated
                value.startDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
            case .date(let date): value.schedule = .dated; value.startDate = Calendar.current.startOfDay(for: date)
            case .someday: value.schedule = .someday; value.startDate = nil
            case .anytime, .clear: value.schedule = .anytime; value.startDate = nil
            }
        }
    }

    @discardableResult func move(_ id: UUID, areaID: UUID?) -> Bool {
        guard areaID == nil || store.areas.contains(where: { $0.id == areaID }) else { return false }
        return update(id) { $0.areaID = areaID }
    }

    private func showTags(_ id: UUID) {
        guard let value = editable(id) else { return }
        present(tagsEditor(id, tags: value.tags ?? []))
    }

    private func tagsEditor(_ id: UUID, tags: [String]) -> CardTagsPopover {
        let editor = CardTagsPopover(tags: tags, suggestions: store.allTags)
        editor.onChange = { [weak self] tags in
            guard let self else { return }
            if update(id, change: { $0.tags = tags }) { popover?.performClose(nil) }
            else {
                // 标签组件完成后冻结草稿；失败时重建相同草稿，允许再次保存。
                popover?.contentViewController = tagsEditor(id, tags: tags)
            }
        }
        return editor
    }

    private func showDeadline(_ id: UUID) {
        guard let value = editable(id) else { return }
        let editor = CardDatePopover(date: value.deadline, isDeadline: true)
        editor.onChoice = { [weak self] choice in
            guard let self else { return }
            if applyDate(choice, projectID: id, deadline: true) { popover?.performClose(nil) }
        }
        present(editor)
    }

    private func showRepeat(_ id: UUID) {
        guard let value = editable(id) else { return }
        let editor = ProjectRepeatEditor(rule: value.repeatRule)
        editor.onSave = { [weak self] rule in
            guard let self else { return false }
            let saved = update(id) { $0.repeatRule = rule }
            if saved { popover?.performClose(nil) }; return saved
        }
        editor.onCancel = { [weak self] in self?.popover?.performClose(nil) }
        present(editor)
    }

    func deletionAlert(_ value: Project) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "删除项目“\(value.title)”？"
        alert.informativeText = "项目将移到废纸篓，可以从废纸篓恢复。项目、分组和任务内容不会被永久删除。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除项目")
        alert.buttons[0].keyEquivalent = "\r"; alert.buttons[1].keyEquivalent = ""
        alert.buttons[1].hasDestructiveAction = true
        return alert
    }

    private func confirmDeletion(_ id: UUID) {
        guard let value = editable(id), let window = anchor?.window else { return }
        deletionAlert(value).beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn, editable(id) != nil else { return }
            store.trashProject(id)
            if project(id)?.deletedAt != nil { onChanged?(); onNavigate?(.trash) } else { showError() }
        }
    }

    /// 仅生成分享草稿，排除含继承删除状态的内容及内部重复模板；选择服务及发送始终由用户操作。
    func sharingText(projectID: UUID) -> String? {
        guard let value = project(projectID), value.deletedAt == nil else { return nil }
        var lines = [value.title]
        if !value.notes.isEmpty { lines.append(value.notes) }
        let tasks = store.todos.filter {
            $0.projectID == projectID && Domain.deletionDate($0, in: store.snapshot) == nil
                && $0.source?.metadata["repeatTemplate"] != "true"
        }.sorted { $0.order < $1.order }
        func appendTasks(_ todos: [Todo]) {
            for task in todos {
                lines.append("\(task.status == .completed ? "☑" : "☐") \(task.title)")
                if !task.notes.isEmpty { lines.append(task.notes) }
                lines += task.checklist.map { "  \($0.completed ? "☑" : "☐") \($0.title)" }
            }
        }
        let headings = value.headings.filter(HeadingOperations.isVisible).sorted { $0.order < $1.order }
        let known = Set(headings.map(\.id))
        appendTasks(tasks.filter { task in task.headingID.map { !known.contains($0) } ?? true })
        for heading in headings {
            lines.append("\n\(heading.title)")
            if let notes = heading.notes, !notes.isEmpty { lines.append(notes) }
            appendTasks(tasks.filter { $0.headingID == heading.id })
        }
        return lines.joined(separator: "\n")
    }

    private func share(_ id: UUID) {
        guard let anchor, let text = sharingText(projectID: id) else { return }
        let picker = NSSharingServicePicker(items: [text]); sharingPicker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func project(_ id: UUID) -> Project? { store.snapshot.projects.first { $0.id == id } }
    private func editable(_ id: UUID) -> Project? {
        guard let value = project(id), value.deletedAt == nil else { return nil }; return value
    }
    private func isClosed(_ value: Project) -> Bool { value.completed || value.status == .completed || value.status == .canceled }

    /// 每次动作重新取得快照，调用方只改动所属字段；只读或保存失败由 Store 拒绝并呈现错误。
    @discardableResult private func update(_ id: UUID, change: (inout Project) -> Void) -> Bool {
        guard var value = editable(id) else { return false }
        change(&value)
        guard store.saveProject(value) else { showError(); return false }
        onChanged?(); return true
    }

    private func present(_ editor: NSViewController) {
        guard let anchor, anchor.window != nil else { return }
        popover?.performClose(nil)
        let value = NSPopover(); value.behavior = .semitransient; value.contentViewController = editor
        popover = value
        value.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func showError() {
        guard let window = anchor?.window else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "项目操作失败"
        alert.informativeText = store.errorMessage ?? "无法保存项目，请重试。"
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    private func add(_ title: String, icon: String, to menu: NSMenu, enabled: Bool = true,
                     deferPresentation: Bool = false, action: @escaping () -> Void) {
        let target = ProjectMenuAction { [self] in
            guard deferPresentation else { action(); return }
            // NSMenu tracking 关闭后再呈现 UI，避免新弹窗被菜单收尾流程关闭。
            // 点击时固定锚点；项目 ID 已由各动作按值捕获，后续仍重新读取最新快照。
            let selectedAnchor = anchor
            DispatchQueue.main.async { [self, selectedAnchor] in
                guard let selectedAnchor, selectedAnchor.window != nil else { return }
                anchor = selectedAnchor
                action()
            }
        }
        let item = NSMenuItem(title: title, action: #selector(ProjectMenuAction.run(_:)), keyEquivalent: "")
        item.target = target; item.representedObject = target; item.isEnabled = enabled
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        menu.addItem(item)
    }
}
