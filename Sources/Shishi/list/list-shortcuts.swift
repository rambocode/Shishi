import AppKit
import ShishiCore

/// 「项」菜单的键盘入口：⌘S 时间、⇧⌘D 截止日期、⇧⌘T 标签、⇧⌘M 移动。
/// 单选时沿用原有的完整弹窗（含提醒），多选时改用批量弹窗，因为提醒是逐条语义。
///
/// 这里所有入口都在**打开弹窗或菜单的那一刻**就把作用对象捕获成 ids，
/// 闭包只用这份快照。弹窗与菜单会接管事件循环，其间表格的 selectedRowIndexes
/// 可能被系统折叠成一行；延迟到回调里再读选择，批量操作就会只作用于一条。
extension TaskListController {

    func showScheduleForSelection() {
        guard canRunSelectionAction else { return }
        let ids = actionableTaskIDs
        if ids.count == 1, let id = ids.first { showTaskDatePopover(for: id, from: selectionAnchor); return }
        let controller = CardDatePopover(date: nil, isDeadline: false)
        controller.onChoice = { [weak self] choice in
            self?.applyBatchSchedule(choice, to: ids)
            self?.shortcutPopover?.performClose(nil)
        }
        presentShortcutPopover(controller, title: "为 \(ids.count) 个待办安排时间")
    }

    func showDeadlineForSelection() {
        guard canRunSelectionAction else { return }
        let ids = actionableTaskIDs
        let initial = ids.count == 1 ? store.todo(ids[0])?.deadline : nil
        let controller = CardDatePopover(date: initial, isDeadline: true)
        controller.onChoice = { [weak self] choice in
            switch choice {
            case .date(let date): self?.applyDeadline(date, to: ids)
            case .clear: self?.applyDeadline(nil, to: ids)
            default: break
            }
            self?.shortcutPopover?.performClose(nil)
        }
        presentShortcutPopover(controller, title: "截止日期")
    }

    func showTagsForSelection() {
        guard canRunSelectionAction else { return }
        let ids = actionableTaskIDs
        let controller = CardTagsPopover(tags: commonTags(of: ids), suggestions: store.allTags)
        controller.onChange = { [weak self] values in
            self?.applyTags(values, to: ids)
            self?.shortcutPopover?.performClose(nil)
        }
        presentShortcutPopover(controller, title: "标签")
    }

    func showMoveMenuForSelection() {
        guard canRunSelectionAction else { return }
        let anchor = selectionAnchor
        selectionMoveMenu(for: actionableTaskIDs).popUpAboveToolbar(from: anchor)
    }

    /// 批量移动菜单：目标与单条移动菜单一致，动作作用于传入的这批 id。
    func selectionMoveMenu(for ids: [UUID]) -> NSMenu {
        let menu = NSMenu(title: "移动到")
        addSelectionItem("收件箱", to: menu) { [weak self] in self?.moveSelection(to: .inbox, ids: ids) }
        for project in store.projects.filter({ !$0.completed && $0.deletedAt == nil && ($0.status == nil || $0.status == .open) }) {
            addSelectionItem(project.title, to: menu) { [weak self] in self?.moveSelection(to: .project(project.id), ids: ids) }
        }
        for area in store.areas {
            addSelectionItem(area.title, to: menu) { [weak self] in self?.moveSelection(to: .area(area.id), ids: ids) }
        }
        return menu
    }

    /// 多选时的右键 /「更多」菜单，只保留对整批都成立的动作。
    func selectionContextMenu() -> NSMenu {
        let selected = selectedTaskIDs
        let ids = actionableTaskIDs
        let menu = NSMenu()
        let header = NSMenuItem(title: "已选 \(selected.count) 个待办", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        addSelectionItem("完成 \(ids.count) 个待办", to: menu) { [weak self] in self?.completeSelection(ids: selected) }
        addSelectionItem("取消 \(ids.count) 个待办", to: menu) { [weak self] in self?.store.cancelMany(ids) }
        menu.addItem(.separator())
        addSelectionItem("今天", to: menu) { [weak self] in self?.applyQuickSchedule(.today, ids: ids) }
        addSelectionItem("今晚", to: menu) { [weak self] in self?.applyQuickSchedule(.evening, ids: ids) }
        addSelectionItem("某天", to: menu) { [weak self] in self?.applyQuickSchedule(.someday, ids: ids) }
        addSelectionItem("清除安排", to: menu) { [weak self] in self?.applyQuickSchedule(.clear, ids: ids) }
        addSelectionItem("选择日期…", to: menu) { [weak self] in self?.showScheduleForSelection() }
        let move = NSMenuItem(title: "移动到", action: nil, keyEquivalent: "")
        move.submenu = selectionMoveMenu(for: ids)
        menu.addItem(move)
        addSelectionItem("标签…", to: menu) { [weak self] in self?.showTagsForSelection() }
        addSelectionItem("截止日期…", to: menu) { [weak self] in self?.showDeadlineForSelection() }
        menu.addItem(.separator())
        addSelectionItem("复制", to: menu) { [weak self] in self?.duplicateSelection(ids: selected) }
        addSelectionItem("移到废纸篓", to: menu) { [weak self] in self?.trashSelection(ids: selected) }
        return menu
    }

    private func applyBatchSchedule(_ choice: CardDateChoice, to ids: [UUID]) {
        switch choice {
        case .today: store.scheduleMany(ids, date: Date(), evening: false)
        case .evening: store.scheduleMany(ids, date: Date(), evening: true)
        case .tomorrow: store.scheduleMany(ids, date: Calendar.current.date(byAdding: .day, value: 1, to: Date()), evening: false)
        case .date(let date): store.scheduleMany(ids, date: date, evening: false)
        case .someday: store.moveMany(ids, to: .someday)
        case .anytime, .clear: store.moveMany(ids, to: .anytime)
        }
        restoreSelection(ids)
    }

    private func presentShortcutPopover(_ controller: NSViewController, title: String) {
        shortcutPopover?.performClose(nil)
        let anchor = selectionAnchor
        let panel = NSPopover()
        panel.behavior = .transient
        panel.contentViewController = controller
        panel.setAccessibilityLabel(title)
        shortcutPopover = panel
        panel.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func addSelectionItem(_ title: String, to menu: NSMenu, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(runSelectionAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = SelectionAction(action)
        menu.addItem(item)
    }

    @objc private func runSelectionAction(_ item: NSMenuItem) { (item.representedObject as? SelectionAction)?.perform() }
}

extension NSMenu {
    /// 底部工具栏贴着窗口下沿，菜单必须向上展开，否则会整块掉到窗口外面盖住别的应用。
    /// 用最后一项对齐锚点左下角来实现向上展开。
    func popUpAboveToolbar(from anchor: NSView) {
        popUp(positioning: items.last, at: NSPoint(x: 0, y: 0), in: anchor)
    }
}

/// 把闭包挂到 NSMenuItem 上的最小包装，和 list-actions 的 ListAction 同构但互不影响。
final class SelectionAction: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
}
