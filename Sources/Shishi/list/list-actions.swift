import AppKit
import ShishiCore

private final class ListAction: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
}

extension TaskListController {
    func contextMenu(row: Int) -> NSMenu? {
        guard inlineEditor == nil else { return nil }
        // 多选优先：右键与「更多」都要作用于整个选择，否则用户会以为只处理了一条。
        if selectedTaskIDs.count > 1, let id = task(at: row)?.id, selectedTaskIDs.contains(id) {
            return selectionContextMenu()
        }
        if let project = project(at: row) {
            let menu = NSMenu()
            add("打开项目", to: menu) { [weak self] in self?.navigateProject(project.id) }
            add("编辑项目…", to: menu) { [weak self] in self?.onEditProject?(project.id) }
            if project.completed || project.status == .completed || project.status == .canceled || project.deletedAt != nil {
                add("恢复项目", to: menu) { [weak self] in self?.restoreArchivedProject(project.id) }
            }
            menu.addItem(.separator())
            if project.deletedAt == nil {
                add("移到废纸篓", to: menu) { [weak self] in self?.store.trashProject(project.id) }
            } else {
                add("永久删除项目…", to: menu) { [weak self] in self?.confirmProjectDeletion(project.id) }
            }
            return menu
        }
        guard let todo = task(at: row) else { return nil }
        let menu = NSMenu()
        if todo.deletedAt != nil {
            add("恢复任务", to: menu) { [weak self] in self?.restoreTask(todo.id) }
            add("永久删除…", to: menu) { [weak self] in self?.confirmDeletion(todo.id) }
            return menu
        }
        add("编辑任务", to: menu) { [weak self] in self?.beginEditing(todo, isNew: false) }
        add("完整详情…", to: menu) { [weak self] in self?.onEditTask?(todo.id) }
        if todo.status != .open {
            add("恢复任务", to: menu) { [weak self] in self?.restoreTask(todo.id) }
        } else {
            add("完成任务", to: menu) { [weak self] in self?.store.toggle(todo.id) }
            add("取消任务", to: menu) { [weak self] in self?.store.cancel(todo.id) }
            menu.addItem(.separator())
            let dates = dateMenu(todo.id)
            for dateItem in dates.items { dates.removeItem(dateItem); menu.addItem(dateItem) }
            let item = NSMenuItem(title: "移动到", action: nil, keyEquivalent: "")
            item.submenu = moveMenu(todo.id); menu.addItem(item)
            menu.addItem(.separator())
            add("重复…", to: menu) { [weak self] in self?.showRepeatEditor(todo.id, row: row) }
        }
        menu.addItem(.separator())
        add("移到废纸篓", to: menu) { [weak self] in self?.store.trash(todo.id) }
        return menu
    }

    // 底部按钮与右键复用同一组动作，失败交由Store的ShishiStoreFailed通知统一呈现。
    func dateMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu(title: "日期")
        add("今天", to: menu) { [weak self] in self?.schedule(id, date: Date(), evening: false) }
        add("今晚", to: menu) { [weak self] in self?.schedule(id, date: Date(), evening: true) }
        add("明天", to: menu) { [weak self] in
            self?.schedule(id, date: Calendar.current.date(byAdding: .day, value: 1, to: Date()), evening: false)
        }
        add("选择日期…", to: menu) { [weak self] in self?.chooseDate(id) }
        menu.addItem(.separator())
        add("随时", to: menu) { [weak self] in self?.store.move(id, to: .anytime) }
        add("某天", to: menu) { [weak self] in self?.store.move(id, to: .someday) }
        return menu
    }
    func moveMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu(title: "移动到")
        add("收件箱", to: menu) { [weak self] in self?.store.move(id, to: .inbox) }
        for project in store.projects.filter({ !$0.completed && $0.deletedAt == nil && ($0.status == nil || $0.status == .open) }) {
            add(project.title, to: menu) { [weak self] in self?.store.move(id, to: .project(project.id)) }
        }
        for area in store.areas {
            add(area.title, to: menu) { [weak self] in self?.store.move(id, to: .area(area.id)) }
        }
        return menu
    }

    private func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = ListAction(action); menu.addItem(item)
    }
    @objc private func runMenuAction(_ item: NSMenuItem) { (item.representedObject as? ListAction)?.perform() }

    /// 列表里的重复设置：面板结果直接写回 Store，锚点取该行矩形，位置与右键点击处一致。
    func showRepeatEditor(_ id: UUID, row: Int) {
        guard let todo = store.todo(id), todo.deletedAt == nil, todo.status == .open else { return }
        guard finishInlineEditing() else { return }
        let controller = TaskRepeatPopover(settings: TaskRepeatSettings.from(todo))
        let panel = NSPopover()
        panel.behavior = .transient
        panel.contentViewController = controller
        controller.onSave = { [weak self, weak panel] settings in
            panel?.performClose(nil)
            guard let self, let latest = self.store.todo(id) else { return }
            guard self.store.save(settings.applied(to: latest)) else { return }
            self.reload()
            self.selectTask(id)
        }
        controller.onCancel = { [weak panel] in panel?.performClose(nil) }
        repeatPopover = panel
        let anchor = row >= 0 && row < table.numberOfRows ? table.rect(ofRow: row) : table.bounds
        panel.show(relativeTo: anchor, of: table, preferredEdge: .maxY)
    }

    func restoreTask(_ id: UUID) {
        guard var todo = store.todo(id) else { return }
        if todo.deletedAt != nil { store.restore(id) }
        else { todo.status = .open; todo.completedAt = nil; store.save(todo) }
    }

    private func schedule(_ id: UUID, date: Date?, evening: Bool) {
        guard var todo = store.todo(id), todo.status == .open, todo.deletedAt == nil, let date else { return }
        todo.schedule = .dated
        todo.startDate = Calendar.current.startOfDay(for: date)
        todo.evening = evening
        store.save(todo)
    }
    private func chooseDate(_ id: UUID) {
        guard let window = view.window else { return }
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 280, height: 150))
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay]
        picker.dateValue = store.todo(id)?.startDate ?? Date()
        picker.setAccessibilityLabel("任务开始日期")
        let alert = NSAlert()
        alert.messageText = "安排任务"
        alert.informativeText = "选择任务的开始日期。截止日期保持独立。"
        alert.accessoryView = picker
        alert.addButton(withTitle: "安排"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.schedule(id, date: picker.dateValue, evening: false)
        }
    }
    func confirmDeletion(_ id: UUID) {
        guard let todo = store.todo(id), let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "永久删除“\(todo.title)”？"
        alert.informativeText = "任务及其备注和清单将从废纸篓中移除。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "永久删除")
        alert.buttons.last?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.store.permanentlyDelete(id) }
        }
    }

    /// 废纸篓内的批量永久删除：一次确认覆盖整批，确认文案写明条数。
    func confirmPermanentDeletion(_ ids: [UUID]) {
        let targets = ids.filter { store.todo($0) != nil }
        guard !targets.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "永久删除选中的 \(targets.count) 个任务？"
        alert.informativeText = "这些任务及其备注和清单将从废纸篓中移除，无法恢复。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "永久删除")
        alert.buttons.last?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.store.permanentlyDeleteMany(targets)
        }
    }

    func projectDeletionAlert(_ project: Project) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "永久删除项目“\(project.title)”？"
        alert.informativeText = "将永久删除此项目及所有子任务，包括备注、清单和项目分组。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "永久删除项目及所有子任务")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        alert.buttons[1].hasDestructiveAction = true
        return alert
    }

    func confirmProjectDeletion(_ id: UUID) {
        guard let project = store.snapshot.projects.first(where: { $0.id == id }), project.deletedAt != nil,
              let window = view.window else { return }
        let alert = projectDeletionAlert(project)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.store.permanentlyDeleteProject(id)
        }
    }
}
