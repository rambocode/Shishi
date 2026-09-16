import AppKit
import XCTest
import ShishiCore
@testable import Shishi

/// 覆盖「选中一批 → 一次处理」的数据层契约（things-align@1 的 INV-2、INV-4、INV-5）。
final class BatchSelectionTests: XCTestCase {

    /// 在临时目录建一个干净 store，避免测试之间互相污染。
    @MainActor private func makeStore(_ todos: [Todo], projects: [Project] = [], areas: [Area] = []) throws -> (TaskStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("library.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SnapshotFile(url: url).write(Snapshot(todos: todos, projects: projects, areas: areas))
        return (TaskStore(fileURL: url), root)
    }

    func testBatchScheduleAndSingleUndoRestoreWholeBatch() async throws {
        try await MainActor.run {
            let items = (0..<3).map { Todo(title: "任务\($0)", schedule: .anytime) }
            let (store, root) = try makeStore(items)
            defer { try? FileManager.default.removeItem(at: root) }
            let ids = items.map(\.id)

            store.scheduleMany(ids, date: Date(), evening: true)
            for id in ids {
                XCTAssertEqual(store.todo(id)?.schedule, .dated)
                XCTAssertEqual(store.todo(id)?.evening, true)
            }
            // INV-2：整批只产生一次撤销事务。
            store.undo()
            for id in ids {
                XCTAssertEqual(store.todo(id)?.schedule, .anytime)
                XCTAssertEqual(store.todo(id)?.evening, false)
            }
            XCTAssertFalse(store.canUndo)
        }
    }

    func testClearScheduleMovesBatchToAnytime() async throws {
        try await MainActor.run {
            let items = (0..<2).map { Todo(title: "任务\($0)", schedule: .dated, startDate: Date(), evening: true) }
            let (store, root) = try makeStore(items)
            defer { try? FileManager.default.removeItem(at: root) }
            store.scheduleMany(items.map(\.id), date: nil, evening: false)
            for item in items {
                XCTAssertEqual(store.todo(item.id)?.schedule, .anytime)
                XCTAssertNil(store.todo(item.id)?.startDate)
                XCTAssertEqual(store.todo(item.id)?.evening, false)
            }
        }
    }

    func testBatchMoveAssignsProjectAreaAndUndoesAtOnce() async throws {
        try await MainActor.run {
            let area = Area(title: "工作")
            let project = Project(title: "发布", areaID: area.id)
            let items = (0..<3).map { Todo(title: "任务\($0)", schedule: .inbox) }
            let (store, root) = try makeStore(items, projects: [project], areas: [area])
            defer { try? FileManager.default.removeItem(at: root) }

            store.moveMany(items.map(\.id), to: .project(project.id))
            for item in items {
                XCTAssertEqual(store.todo(item.id)?.projectID, project.id)
                XCTAssertEqual(store.todo(item.id)?.areaID, area.id, "移动到项目要继承项目所属区域")
                XCTAssertEqual(store.todo(item.id)?.schedule, .anytime, "收件箱条目移动后不应停留在 inbox")
            }
            store.undo()
            for item in items { XCTAssertNil(store.todo(item.id)?.projectID) }
        }
    }

    func testBatchCompleteSkipsClosedAndTrashedItems() async throws {
        try await MainActor.run {
            let open = Todo(title: "开放", schedule: .anytime)
            let done = Todo(title: "已完成", status: .completed, schedule: .anytime, completedAt: Date())
            let trashed = Todo(title: "废纸篓", schedule: .anytime, deletedAt: Date())
            let (store, root) = try makeStore([open, done, trashed])
            defer { try? FileManager.default.removeItem(at: root) }
            let completedAtBefore = store.todo(done.id)?.completedAt

            // INV-4：批量动作跳过不可操作项，不静默改写它们。
            store.completeMany([open.id, done.id, trashed.id])
            XCTAssertEqual(store.todo(open.id)?.status, .completed)
            XCTAssertEqual(store.todo(done.id)?.completedAt, completedAtBefore)
            XCTAssertEqual(store.todo(trashed.id)?.status, .open)
            XCTAssertNotNil(store.todo(trashed.id)?.deletedAt)
        }
    }

    func testBatchReopenCancelAndTrashAreSingleTransactions() async throws {
        try await MainActor.run {
            let items = (0..<3).map { Todo(title: "任务\($0)", status: .completed, schedule: .anytime, completedAt: Date()) }
            let (store, root) = try makeStore(items)
            defer { try? FileManager.default.removeItem(at: root) }
            let ids = items.map(\.id)

            store.reopenMany(ids)
            for id in ids {
                XCTAssertEqual(store.todo(id)?.status, .open)
                XCTAssertNil(store.todo(id)?.completedAt)
            }
            store.cancelMany(ids)
            for id in ids { XCTAssertEqual(store.todo(id)?.status, .canceled) }
            store.trashMany(ids)
            for id in ids { XCTAssertNotNil(store.todo(id)?.deletedAt) }

            store.undo()
            for id in ids { XCTAssertNil(store.todo(id)?.deletedAt) }
            store.undo()
            for id in ids { XCTAssertEqual(store.todo(id)?.status, .open) }
        }
    }

    func testDuplicateManyCreatesIndependentCopiesWithoutSourceIdentity() async throws {
        try await MainActor.run {
            var origin = Todo(title: "带清单的任务", notes: "备注", schedule: .anytime, tags: ["重点"])
            origin.checklist = [ChecklistItem(title: "步骤一"), ChecklistItem(title: "步骤二")]
            origin.source = SourceInfo(provider: "things", identifier: "ABC")
            let (store, root) = try makeStore([origin])
            defer { try? FileManager.default.removeItem(at: root) }

            let created = store.duplicateMany([origin.id])
            XCTAssertEqual(created.count, 1)
            let copy = try XCTUnwrap(created.first.flatMap { store.todo($0) })
            XCTAssertNotEqual(copy.id, origin.id)
            XCTAssertEqual(copy.title, origin.title)
            XCTAssertEqual(copy.tags, origin.tags)
            XCTAssertEqual(copy.checklist.map(\.title), origin.checklist.map(\.title))
            XCTAssertNil(copy.source, "副本不得继承来源 ID，否则重复导入会覆盖副本")
            XCTAssertNotEqual(copy.checklist.first?.id, origin.checklist.first?.id, "检查项必须换新 ID")
            XCTAssertEqual(store.todo(origin.id)?.checklist.count, 2, "复制不得改动原任务")

            store.undo()
            XCTAssertNil(store.todo(copy.id))
        }
    }

    func testSaveManyAppliesDeadlineAndTagsInOneTransaction() async throws {
        try await MainActor.run {
            let items = (0..<3).map { Todo(title: "任务\($0)", schedule: .anytime, tags: ["旧"]) }
            let (store, root) = try makeStore(items)
            defer { try? FileManager.default.removeItem(at: root) }
            let deadline = Calendar.current.startOfDay(for: Date())

            let updated = items.map { item -> Todo in
                var copy = item; copy.deadline = deadline; copy.tags = ["新"]; return copy
            }
            store.saveMany(updated)
            for item in items {
                XCTAssertEqual(store.todo(item.id)?.deadline, deadline)
                XCTAssertEqual(store.todo(item.id)?.tags, ["新"])
            }
            store.undo()
            for item in items { XCTAssertEqual(store.todo(item.id)?.tags, ["旧"]) }
        }
    }

    func testPermanentDeleteManyOnlyRemovesTrashedItems() async throws {
        try await MainActor.run {
            let trashed = (0..<2).map { Todo(title: "废\($0)", schedule: .anytime, deletedAt: Date()) }
            let alive = Todo(title: "在用", schedule: .anytime)
            let (store, root) = try makeStore(trashed + [alive])
            defer { try? FileManager.default.removeItem(at: root) }

            store.permanentlyDeleteMany(trashed.map(\.id) + [alive.id])
            for item in trashed { XCTAssertNil(store.todo(item.id)) }
            XCTAssertNotNil(store.todo(alive.id), "未进废纸篓的任务不得被批量永久删除")
        }
    }

    /// 多选状态下列表要把可操作对象收敛为「开放且未删除」的待办。
    func testControllerSelectionFiltersNonActionableRows() async throws {
        try await MainActor.run {
            let open1 = Todo(title: "开放一", schedule: .anytime)
            let open2 = Todo(title: "开放二", schedule: .anytime)
            let done = Todo(title: "已完成", status: .completed, schedule: .anytime, completedAt: Date())
            let (store, root) = try makeStore([open1, open2, done])
            defer { try? FileManager.default.removeItem(at: root) }

            let list = TaskListController(store: store)
            list.loadView()
            list.route = .anytime
            list.reload()
            let rows = (0..<list.table.numberOfRows).filter { list.task(at: $0) != nil }
            list.table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)

            XCTAssertEqual(Set(list.actionableTaskIDs), Set([open1.id, open2.id]))
            XCTAssertTrue(list.canRunSelectionAction)

            list.applyQuickSchedule(.today)
            XCTAssertEqual(store.todo(open1.id)?.schedule, .dated)
            XCTAssertEqual(store.todo(open2.id)?.schedule, .dated)

            list.clearSelection()
            XCTAssertTrue(list.actionableTaskIDs.isEmpty)
            XCTAssertFalse(list.canRunSelectionAction)
        }
    }
}

/// 覆盖 INV-3：无修饰单键捷径不得在文本输入或编辑态抢走字符。
final class ItemCommandGateTests: XCTestCase {
    @MainActor func testShortcutsDisabledWhileTypingOrEditing() {
        let textView = NSTextView()
        let field = NSTextField()
        field.isEditable = true
        let readOnly = NSTextField(labelWithString: "只读")
        let table = NSTableView()

        XCTAssertTrue(ItemCommandGate.allows(isMainWindowKey: true, hasSheet: false, hasModal: false,
                                             isEditingInline: false, firstResponder: table))
        // 焦点在文本视图或可编辑文本框时必须交还字符
        XCTAssertFalse(ItemCommandGate.allows(isMainWindowKey: true, hasSheet: false, hasModal: false,
                                              isEditingInline: false, firstResponder: textView))
        XCTAssertFalse(ItemCommandGate.allows(isMainWindowKey: true, hasSheet: false, hasModal: false,
                                              isEditingInline: false, firstResponder: field))
        XCTAssertTrue(ItemCommandGate.allows(isMainWindowKey: true, hasSheet: false, hasModal: false,
                                             isEditingInline: false, firstResponder: readOnly))
        // 卡片编辑、sheet、modal、快速录入面板抢走 key window 时同样禁用
        XCTAssertFalse(ItemCommandGate.allows(isMainWindowKey: true, hasSheet: false, hasModal: false,
                                              isEditingInline: true, firstResponder: table))
        XCTAssertFalse(ItemCommandGate.allows(isMainWindowKey: true, hasSheet: true, hasModal: false,
                                              isEditingInline: false, firstResponder: table))
        XCTAssertFalse(ItemCommandGate.allows(isMainWindowKey: true, hasSheet: false, hasModal: true,
                                              isEditingInline: false, firstResponder: table))
        XCTAssertFalse(ItemCommandGate.allows(isMainWindowKey: false, hasSheet: false, hasModal: false,
                                              isEditingInline: false, firstResponder: table))
    }
}
