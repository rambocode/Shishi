import AppKit
import ShishiCore

/// 列表多选与批量动作：把 Things 3 的「选中一批 → 一次处理」交互落到单一入口，
/// 所有批量写入都走 TaskStore 的批量 API，保证一次操作只产生一次撤销事务。
extension TaskListController {

    // MARK: - 选择集合

    /// 当前选中的待办 ID，按列表显示顺序返回；项目行与标题行被忽略。
    var selectedTaskIDs: [UUID] {
        table.selectedRowIndexes.sorted().compactMap { task(at: $0)?.id }
    }

    /// 选中项中可继续编辑的开放待办；已完成、已取消和废纸篓中的条目被排除。
    var actionableTaskIDs: [UUID] {
        selectedTaskIDs.filter { id in
            guard let todo = store.todo(id) else { return false }
            return todo.status == .open && Domain.deletionDate(todo, in: store.snapshot) == nil
        }
    }

    var selectionCount: Int { table.selectedRowIndexes.count }
    var hasMultipleSelection: Bool { selectedTaskIDs.count > 1 }

    /// 批量动作的统一前置条件：不在卡片编辑态、没有 sheet、至少有一条可操作待办。
    var canRunSelectionAction: Bool {
        inlineEditor == nil && !actionableTaskIDs.isEmpty
    }

    /// 弹窗与菜单锚点：统一锚在底部工具栏的「更多」按钮上，位置不随列表滚动跑掉。
    var selectionAnchor: NSView { contextualTools.isHidden ? moveButton : contextualMore }

    func clearSelection() {
        table.deselectAll(nil)
        updateTools()
    }

    /// ⌘A：选中当前列表里全部可选的待办行，不含标题与项目行。
    func selectAllTasks() {
        let rows = (0..<table.numberOfRows).filter { task(at: $0) != nil }
        guard !rows.isEmpty else { return }
        table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        updateTools()
    }

    // MARK: - 批量动作

    /// 今天 / 今晚 / 某天 / 清除 四个单键捷径共用的入口。
    /// ids 默认取当前选择；从菜单调用时由调用方传入发起菜单那一刻的快照。
    func applyQuickSchedule(_ choice: QuickSchedule, ids: [UUID]? = nil) {
        let targets = ids ?? actionableTaskIDs
        guard !targets.isEmpty else { return }
        switch choice {
        case .today: store.scheduleMany(targets, date: Date(), evening: false)
        case .evening: store.scheduleMany(targets, date: Date(), evening: true)
        case .someday: store.moveMany(targets, to: .someday)
        case .clear: store.moveMany(targets, to: .anytime)
        }
        restoreSelection(targets)
    }

    func completeSelection(ids: [UUID]? = nil) {
        guard inlineEditor == nil else { return }
        let targets = ids ?? selectedTaskIDs
        guard !targets.isEmpty else { return }
        // 混合选择时按多数语义处理：只要还有开放项就完成它们，全部已完成才整批重新打开。
        let open = targets.filter { store.todo($0)?.status == .open }
        if open.isEmpty { store.reopenMany(targets) } else { store.completeMany(open) }
    }

    func cancelSelection(ids: [UUID]? = nil) {
        let targets = ids ?? actionableTaskIDs
        guard !targets.isEmpty else { return }
        store.cancelMany(targets)
    }

    func duplicateSelection(ids: [UUID]? = nil) {
        guard inlineEditor == nil else { return }
        let targets = (ids ?? selectedTaskIDs).filter { store.todo($0)?.deletedAt == nil }
        guard !targets.isEmpty else { return }
        let created = store.duplicateMany(targets)
        guard !created.isEmpty else { return }
        reload()
        restoreSelection(created)
    }

    /// 菜单里的「移到废纸篓」：作用于发起菜单时选中的那批。
    func trashSelection(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if route == .trash { confirmPermanentDeletion(ids) } else { store.trashMany(ids) }
    }

    /// 批量移动到项目 / 区域 / 收件箱，菜单项与单选时同源。
    func moveSelection(to route: Route, ids: [UUID]? = nil) {
        let targets = ids ?? actionableTaskIDs
        guard !targets.isEmpty else { return }
        store.moveMany(targets, to: route)
        restoreSelection(targets)
    }

    /// 批量设置或清除截止日期。
    func applyDeadline(_ date: Date?, to ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let updated = ids.compactMap { id -> Todo? in
            guard var todo = store.todo(id) else { return nil }
            todo.deadline = date.map { Calendar.current.startOfDay(for: $0) }
            if date == nil { todo.deadlineSuppressionDate = nil }
            return todo
        }
        store.saveMany(updated)
        restoreSelection(ids)
    }

    /// 批量替换标签集合；弹窗返回的是最终标签，不做增量合并。
    func applyTags(_ tags: [String], to ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let updated = ids.compactMap { id -> Todo? in
            guard var todo = store.todo(id) else { return nil }
            todo.tags = tags
            return todo
        }
        store.saveMany(updated)
        restoreSelection(ids)
    }

    /// 这批待办的共同标签，作为标签弹窗的初值。
    func commonTags(of ids: [UUID]) -> [String] {
        let lists = ids.compactMap { store.todo($0)?.tags }
        guard let first = lists.first else { return [] }
        return first.filter { tag in lists.allSatisfy { $0.contains(tag) } }
    }

    /// 批量写入后行顺序会变，按 ID 重新选中仍然存在的条目，避免选择态凭空消失。
    func restoreSelection(_ ids: [UUID]) {
        let rows = (0..<table.numberOfRows).filter { row in
            guard let id = task(at: row)?.id else { return false }
            return ids.contains(id)
        }
        if rows.isEmpty { table.deselectAll(nil) }
        else { table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false) }
        updateTools()
    }
}

/// 单键捷径的四个目标，与 Things 3 的「捷径」子菜单一一对应。
enum QuickSchedule { case today, evening, someday, clear }
