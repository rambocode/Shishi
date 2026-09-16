import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class InlineTests: XCTestCase {
    func testTodayDragReordersMixedIDsAndOtherRouteRejectsProjectDrag() async throws {
        try await MainActor.run {
            try fixture { store, list, url in
                func source(_ index: Int) -> SourceInfo {
                    SourceInfo(provider: "test", identifier: "row-\(index)", metadata: ["todayIndex": String(index)])
                }
                let firstProject = Project(title: "项目0", order: 0, startDate: Date(), schedule: .dated, source: source(0))
                let secondProject = Project(title: "项目2", order: 2, startDate: Date(), schedule: .dated, source: source(2))
                let firstTask = Todo(title: "任务1", schedule: .dated, startDate: Date(), order: 1, source: source(1))
                let secondTask = Todo(title: "任务3", schedule: .dated, startDate: Date(), order: 3, source: source(3))
                XCTAssertTrue(store.saveProject(firstProject)); XCTAssertTrue(store.saveProject(secondProject))
                XCTAssertTrue(store.save(firstTask)); XCTAssertTrue(store.save(secondTask))
                _ = list.view
                let table = try XCTUnwrap(descendants(list.view).compactMap { $0 as? NSTableView }.first)
                @MainActor func ids() -> [UUID] {
                    (0..<list.numberOfRows(in: table)).compactMap { list.task(at: $0)?.id ?? list.project(at: $0)?.id }
                }
                XCTAssertEqual(ids(), [firstProject.id, firstTask.id, secondProject.id, secondTask.id])
                XCTAssertTrue(list.acceptDraggedItem(secondTask.id, at: 1, fromLocalList: true))
                XCTAssertEqual(ids(), [secondTask.id, firstProject.id, firstTask.id, secondProject.id])
                XCTAssertTrue(list.acceptDraggedItem(firstProject.id, at: list.numberOfRows(in: table), fromLocalList: true))
                XCTAssertEqual(ids(), [secondTask.id, firstTask.id, secondProject.id, firstProject.id])
                XCTAssertEqual(list.selectedProjectID, firstProject.id)
                XCTAssertNotNil(list.tableView(table, pasteboardWriterForRow: table.selectedRow))
                let expected = store.snapshot
                XCTAssertFalse(list.acceptDraggedItem(secondProject.id, at: 1, fromLocalList: false))
                XCTAssertEqual(store.snapshot, expected)
                list.route = .anytime
                list.selectProject(firstProject.id)
                XCTAssertNil(list.tableView(table, pasteboardWriterForRow: table.selectedRow))
                XCTAssertFalse(list.acceptDraggedItem(firstProject.id, at: 1, fromLocalList: true))
                XCTAssertEqual(store.snapshot, expected)
                XCTAssertTrue(list.acceptDraggedItem(firstTask.id, at: 0, fromLocalList: true))
                XCTAssertEqual(store.todo(firstTask.id)?.source?.metadata["todayIndex"], expected.todos.first { $0.id == firstTask.id }?.source?.metadata["todayIndex"])
                XCTAssertEqual(TaskStore(fileURL: url).snapshot, store.snapshot)
                list.route = .today
                XCTAssertEqual(ids(), [secondTask.id, firstTask.id, secondProject.id, firstProject.id])
            }
        }
    }
    func testProjectDeleteMovesToTrashAndPermanentDeletionRequiresConfirmation() async throws {
        try await MainActor.run {
            try fixture { store, list, _ in
                let heading = Heading(title: "保留分组")
                let project = Project(title: "保留项目", headings: [heading], schedule: .anytime)
                XCTAssertTrue(store.saveProject(project))
                let task = Todo(title: "保留关联任务", schedule: .anytime, projectID: project.id, headingID: heading.id)
                XCTAssertTrue(store.save(task))
                _ = list.view
                list.route = .anytime
                list.selectProject(project.id)
                XCTAssertTrue(list.canDeleteSelection)
                list.deleteSelected()
                XCTAssertNotNil(store.snapshot.projects.first { $0.id == project.id }?.deletedAt)
                XCTAssertNotNil(store.todo(task.id))
                list.route = .trash
                list.selectProject(project.id)
                XCTAssertTrue(list.canDeleteSelection)
                let table = try XCTUnwrap(descendants(list.view).compactMap { $0 as? NSTableView }.first)
                let menu = try XCTUnwrap(list.contextMenu(row: table.selectedRow))
                XCTAssertNotNil(try XCTUnwrap(menu.items.first { $0.title.contains("永久删除") }).action)
                XCTAssertTrue(menu.items.contains { $0.title == "恢复项目" })
                let before = store.snapshot
                list.deleteSelected()
                XCTAssertEqual(store.snapshot, before)
                let alert = list.projectDeletionAlert(project)
                XCTAssertEqual(alert.buttons.first?.title, "取消")
                XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r")
                XCTAssertEqual(alert.buttons.last?.keyEquivalent, "")
                XCTAssertTrue(alert.buttons.last?.hasDestructiveAction == true)
                XCTAssertTrue(alert.informativeText.contains("所有子任务"))
                list.restoreArchivedProject(project.id)
                let restored = try XCTUnwrap(store.snapshot.projects.first { $0.id == project.id })
                XCTAssertNil(restored.deletedAt)
                XCTAssertEqual(restored.headings, [heading])
                XCTAssertEqual(store.todo(task.id)?.projectID, project.id)
                XCTAssertEqual(store.todo(task.id)?.headingID, heading.id)
                store.trashProject(project.id)
                store.permanentlyDeleteProject(project.id)
                XCTAssertFalse(store.snapshot.projects.contains { $0.id == project.id })
                XCTAssertNil(store.todo(task.id))
                store.undo()
                XCTAssertNotNil(store.todo(task.id))
                XCTAssertNotNil(store.snapshot.projects.first { $0.id == project.id })
            }
        }
    }
    func testTodayIncludesProjectsAndTasksAndProjectReturnNavigates() async throws {
        try await MainActor.run {
            try fixture { store, list, _ in
                let projects = [Project(title: "今日项目一", startDate: Date(), schedule: .dated),
                                Project(title: "今日项目二", startDate: Date(), schedule: .dated)]
                for project in projects { XCTAssertTrue(store.saveProject(project)) }
                for title in ["任务一", "任务二", "任务三"] {
                    XCTAssertTrue(store.save(Todo(title: title, schedule: .dated, startDate: Date())))
                }
                _ = list.view
                list.reload()
                let table = try XCTUnwrap(descendants(list.view).compactMap { $0 as? NSTableView }.first)
                let indices = 0..<list.numberOfRows(in: table)
                XCTAssertEqual(indices.compactMap { list.project(at: $0) }.count, 2)
                XCTAssertEqual(indices.compactMap { list.task(at: $0) }.count, 3)
                var navigation: [Route] = []
                var editCalls: [UUID] = []
                list.onNavigate = { navigation.append($0) }
                list.onEditProject = { editCalls.append($0) }
                list.selectProject(projects[0].id)
                list.edit()
                XCTAssertEqual(navigation, [.project(projects[0].id)])
                XCTAssertTrue(editCalls.isEmpty)
                if let action = table.action { _ = table.sendAction(action, to: table.target) }
                XCTAssertEqual(navigation.count, 2)
                list.route = .project(projects[0].id)
                XCTAssertFalse((0..<list.numberOfRows(in: table)).contains { list.project(at: $0) != nil })
            }
        }
    }

    func testUpcomingMergesProjectAndTaskUnderOneDateHeading() async throws {
        try await MainActor.run {
            try fixture { store, list, _ in
                let day = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 2, to: Date()))
                let project = Project(title: "同日项目", startDate: day, schedule: .dated)
                XCTAssertTrue(store.saveProject(project))
                XCTAssertTrue(store.save(Todo(title: "同日任务", schedule: .dated, startDate: day)))
                _ = list.view
                list.route = .upcoming
                let table = try XCTUnwrap(descendants(list.view).compactMap { $0 as? NSTableView }.first)
                XCTAssertEqual(list.numberOfRows(in: table), 3)
                XCTAssertFalse(list.tableView(table, shouldSelectRow: 0))
                XCTAssertNotNil(list.project(at: 1))
                XCTAssertNotNil(list.task(at: 2))
                list.route = .anytime
                XCTAssertEqual((0..<list.numberOfRows(in: table)).compactMap { list.project(at: $0) }.count,
                               store.projectItems(for: .anytime).count)
            }
        }
    }
    func testSelectedInlineRowKeepsNormalBackgroundAndSemanticTitleColor() async throws {
        try await MainActor.run {
            try fixture { _, list, _ in
                list.beginEditing(Todo(title: "始终可见的标题"), isNew: true)
                let table = try XCTUnwrap(descendants(list.view).compactMap { $0 as? NSTableView }.first)
                let row = try XCTUnwrap(list.tableView(table, rowViewForRow: table.selectedRow) as? TaskListRowView)
                row.isSelected = true
                XCTAssertFalse(row.isEmphasized)
                XCTAssertEqual(row.interiorBackgroundStyle, .normal)
                row.isEmphasized = true
                XCTAssertEqual(row.interiorBackgroundStyle, .normal)
                let editor = try XCTUnwrap(list.inlineEditor)
                XCTAssertEqual(try control(NSTextField.self, in: editor, label: "任务标题").textColor, .labelColor)
                XCTAssertTrue(try control(NSTextView.self, in: editor, label: "任务备注").allowsUndo)
            }
        }
    }
    @MainActor private func fixture(_ body: (TaskStore, TaskListController, URL) throws -> Void) throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shishi-inline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("db.json")
        let store = TaskStore(fileURL: url)
        try body(store, TaskListController(store: store), url)
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor private func control<T: NSView>(_ type: T.Type, in view: NSView, label: String) throws -> T {
        try XCTUnwrap(descendants(view).compactMap { $0 as? T }.first { $0.accessibilityLabel() == label })
    }

    func testNewDraftHasRealControlsAndNoPrematureWrite() async throws {
        try await MainActor.run {
            try fixture { store, list, url in
                let todo = Todo(title: "草稿", checklist: [ChecklistItem(title: "检查")])
                var transitions: [Bool] = []
                list.onInlineEditingChanged = { transitions.append($0) }
                list.beginEditing(todo, isNew: true)
                let editor = try XCTUnwrap(list.inlineEditor)
                XCTAssertEqual(list.selectedTaskID, todo.id)
                XCTAssertNotNil(try control(NSTextField.self, in: editor, label: "任务标题"))
                XCTAssertTrue(try control(NSTextView.self, in: editor, label: "任务备注").allowsUndo)
                let check = try control(NSButton.self, in: editor, label: "勾选检查列表项")
                check.performClick(nil)
                XCTAssertTrue(editor.collect().checklist[0].completed)
                XCTAssertTrue(store.todos.isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
                XCTAssertTrue(list.finishInlineEditing())
                XCTAssertTrue(try XCTUnwrap(store.todo(todo.id)).checklist[0].completed)
                XCTAssertEqual(TaskStore(fileURL: url).todo(todo.id)?.title, "草稿")
                XCTAssertEqual(transitions, [true, false])
            }
        }
    }

    func testNavigationAutosavesValidDraftAndBlankNewDraftCancels() async throws {
        try await MainActor.run {
            try fixture { store, list, _ in
                let todo = Todo(title: "保存后导航", schedule: .anytime)
                list.beginEditing(todo, isNew: true)
                list.route = .anytime
                XCTAssertEqual(list.route, .anytime)
                XCTAssertNil(list.inlineEditor)
                XCTAssertEqual(store.todo(todo.id)?.title, todo.title)
                let blank = Todo(title: "  ")
                list.beginEditing(blank, isNew: true)
                list.route = .inbox
                XCTAssertEqual(list.route, .inbox)
                XCTAssertNil(list.inlineEditor)
                XCTAssertNil(store.todo(blank.id))
            }
        }
    }

    func testTitlelessMeaningfulDraftBlocksNavigationAndFinish() async throws {
        try await MainActor.run {
            try fixture { store, list, _ in
                let todo = Todo(title: "", notes: "不能静默丢失的备注")
                var blocked: [Route] = []
                list.onRouteChangeBlocked = { blocked.append($0) }
                list.beginEditing(todo, isNew: true)
                list.route = .inbox
                XCTAssertEqual(list.route, .today)
                XCTAssertEqual(blocked, [.today])
                XCTAssertFalse(list.finishInlineEditing())
                XCTAssertEqual(list.inlineEditor?.collect().notes, todo.notes)
                XCTAssertTrue(store.todos.isEmpty)
            }
        }
    }

    func testCardSchedulePreservesHierarchyAndMovingToInboxClearsIt() async throws {
        try await MainActor.run {
            try fixture { store, list, _ in
                let area = Area(title: "领域")
                let heading = Heading(title: "分组")
                let project = Project(title: "项目", areaID: area.id, headings: [heading])
                XCTAssertTrue(store.saveArea(area)); XCTAssertTrue(store.saveProject(project))
                let todo = Todo(title: "移入收件箱", schedule: .dated, startDate: Date(), evening: true,
                                projectID: project.id, areaID: area.id, headingID: heading.id)
                list.beginEditing(todo, isNew: true)
                try XCTUnwrap(list.inlineEditor).applySchedule(.anytime)
                XCTAssertTrue(list.finishInlineEditing())
                XCTAssertEqual(store.todo(todo.id)?.headingID, heading.id)
                XCTAssertEqual(store.todo(todo.id)?.projectID, project.id)
                XCTAssertEqual(store.todo(todo.id)?.schedule, .anytime)
                store.move(todo.id, to: .inbox)
                let saved = try XCTUnwrap(store.todo(todo.id))
                XCTAssertEqual(saved.schedule, .inbox)
                XCTAssertNil(saved.projectID); XCTAssertNil(saved.areaID); XCTAssertNil(saved.headingID)
                XCTAssertNil(saved.startDate); XCTAssertFalse(saved.evening)
                XCTAssertTrue(store.items(for: .inbox).contains { $0.id == todo.id })
            }
        }
    }

    func testFailedPersistenceBlocksRouteAndRetainsDraft() async throws {
        try await MainActor.run {
            try fixture { store, list, url in
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let corrupt = Data("corrupt".utf8)
                try corrupt.write(to: url)
                let protected = TaskStore(fileURL: url)
                let controller = TaskListController(store: protected)
                let todo = Todo(title: "保存失败仍保留")
                controller.beginEditing(todo, isNew: true)
                controller.route = .anytime
                XCTAssertEqual(controller.route, .today)
                XCTAssertFalse(controller.finishInlineEditing())
                XCTAssertEqual(controller.inlineEditor?.collect().title, todo.title)
                XCTAssertNotNil(protected.errorMessage)
                XCTAssertTrue(protected.todos.isEmpty)
                XCTAssertEqual(try Data(contentsOf: url), corrupt)
                XCTAssertTrue(store.todos.isEmpty)
                XCTAssertNil(list.inlineEditor)
            }
        }
    }

    func testConcurrentChangeDoesNotGetOverwritten() async throws {
        try await MainActor.run {
            try fixture { store, list, _ in
                let todo = Todo(title: "原标题", schedule: .anytime)
                XCTAssertTrue(store.save(todo))
                list.beginEditing(todo, isNew: false)
                try control(NSTextField.self, in: XCTUnwrap(list.inlineEditor), label: "任务标题").stringValue = "本地草稿"
                var external = todo; external.notes = "外部更新"
                XCTAssertTrue(store.save(external))
                list.route = .inbox
                XCTAssertEqual(list.route, .today)
                XCTAssertFalse(list.finishInlineEditing())
                XCTAssertEqual(store.todo(todo.id)?.notes, "外部更新")
                XCTAssertEqual(store.todo(todo.id)?.title, "原标题")
                XCTAssertEqual(list.inlineEditor?.collect().title, "本地草稿")
            }
        }
    }

    func testHiddenWindowCommitsFieldEditorCompositionBeforeSaving() async throws {
        try await MainActor.run {
            try fixture { store, list, _ in
                // 仅内存中的隐藏窗口，不展示、不激活、不操作用户应用。
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 745, height: 700),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = list.view
                defer { window.contentView = nil; window.close() }
                let todo = Todo(title: "原稿")
                list.beginEditing(todo, isNew: true)
                let editor = try XCTUnwrap(list.inlineEditor)
                let field = try control(NSTextField.self, in: editor, label: "任务标题")
                XCTAssertTrue(window.makeFirstResponder(field))
                let shared = try XCTUnwrap(field.currentEditor() as? NSTextView)
                shared.setMarkedText("输入法任务", selectedRange: NSRange(location: 5, length: 0),
                                     replacementRange: NSRange(location: 0, length: shared.string.utf16.count))
                XCTAssertTrue(shared.hasMarkedText())
                XCTAssertTrue(list.finishInlineEditing())
                XCTAssertEqual(store.todo(todo.id)?.title, "输入法任务")
                XCTAssertFalse(shared.hasMarkedText())
                XCTAssertNil(list.inlineEditor)
            }
        }
    }
}
