import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class ProjectHeadingTests: XCTestCase {
    func testEmptyHeadingEntryCreatesCardInSecondHeadingAndPersistsNestedChecklist() async throws {
        try await MainActor.run {
            try cardFixture { store, list, url, project in
                let table = try headingControl(NSTableView.self, in: list.view)
                XCTAssertEqual(list.route, .project(project.id))
                XCTAssertEqual(list.numberOfRows(in: table), 2)
                XCTAssertTrue(store.todos.isEmpty)
                for row in 0..<2 {
                    XCTAssertNil(list.task(at: row))
                    let section = try XCTUnwrap(list.tableView(table, viewFor: table.tableColumns[0], row: row) as? ListHeadingView)
                    XCTAssertFalse(headingDescendants(section).contains { $0.accessibilityLabel() == "在“同名标题”下新建待办" }, "标题后不再显示＋")
                    XCTAssertNotNil(try headingControl(NSButton.self, in: section, label: "标题“同名标题”更多操作").action)
                }
                let footer = try headingControl(NSButton.self, in: list.view, label: "在项目中新建标题分组")
                XCTAssertFalse(footer.isHidden)
                XCTAssertTrue(footer.isEnabled)

                list.newTask(inHeading: project.headings[1].id)
                let editor = try XCTUnwrap(list.inlineEditor)
                let taskID = editor.collect().id
                XCTAssertEqual(editor.collect().headingID, project.headings[1].id)
                XCTAssertEqual(editor.collect().projectID, project.id)
                try headingControl(NSTextField.self, in: editor, label: "任务标题").stringValue = "父待办"
                editor.addChecklist()
                try headingControl(NSTextField.self, in: editor, label: "检查列表项").stringValue = "完成这一检查项"
                try headingControl(NSButton.self, in: editor, label: "勾选检查列表项").performClick(nil)
                let draft = editor.collect()
                let checkID = try XCTUnwrap(draft.checklist.first?.id)
                XCTAssertTrue(draft.checklist[0].completed)
                XCTAssertEqual(draft.status, .open)
                XCTAssertNil(draft.completedAt)
                XCTAssertTrue(store.todos.isEmpty)
                XCTAssertTrue(list.finishInlineEditing())
                XCTAssertNil(list.inlineEditor)
                let saved = try XCTUnwrap(TaskStore(fileURL: url).todo(taskID))
                XCTAssertEqual(saved.projectID, project.id)
                XCTAssertEqual(saved.headingID, project.headings[1].id)
                XCTAssertEqual(saved.status, .open)
                XCTAssertNil(saved.completedAt)
                XCTAssertEqual(saved.checklist, [ChecklistItem(id: checkID, title: "完成这一检查项", completed: true)])
                XCTAssertEqual(store.todos.map(\.id), [taskID])
                XCTAssertEqual(TaskStore(fileURL: url).snapshot, store.snapshot)
                XCTAssertEqual(store.snapshot.projects, [project])

                list.beginEditing(saved, isNew: false)
                let reopened = try XCTUnwrap(list.inlineEditor)
                XCTAssertEqual(reopened.collect().checklist.first?.id, checkID)
                reopened.addChecklist()
                let fields = headingDescendants(reopened).compactMap { $0 as? NSTextField }
                    .filter { $0.accessibilityLabel() == "检查列表项" }
                XCTAssertEqual(fields.count, 2)
                fields[1].stringValue = "新增后移除"
                let addedID = try XCTUnwrap(reopened.collect().checklist.last?.id)
                XCTAssertNotEqual(addedID, checkID)
                let bottomDelete = try headingControl(NSButton.self, in: list.view, label: "删除选中的检查项")
                XCTAssertFalse(bottomDelete.isDescendant(of: reopened))
                XCTAssertTrue(bottomDelete.isEnabled)
                bottomDelete.performClick(nil)
                XCTAssertTrue(list.inlineEditor === reopened)
                XCTAssertNil(store.todo(taskID)?.deletedAt)
                // 同时修改保留项，确保重新打开后的保存实际经过存储事务。
                fields[0].stringValue = "更新检查项"
                XCTAssertEqual(reopened.collect().checklist.map(\.id), [checkID])
                XCTAssertTrue(list.finishInlineEditing())
                let updated = try XCTUnwrap(TaskStore(fileURL: url).todo(taskID))
                XCTAssertEqual(updated.checklist, [ChecklistItem(id: checkID, title: "更新检查项", completed: true)])
                XCTAssertEqual(updated.headingID, project.headings[1].id)
                XCTAssertEqual(updated.status, .open)
                XCTAssertEqual(store.todos.map(\.id), [taskID])
            }
        }
    }

    func testCancelGroupedNewAndExistingCardsDoesNotPersistChecklistDrafts() async throws {
        try await MainActor.run {
            try cardFixture { store, list, url, project in
                let todo = Todo(title: "已有父待办", schedule: .anytime, projectID: project.id,
                                headingID: project.headings[1].id, checklist: [ChecklistItem(title: "保留检查项")])
                XCTAssertTrue(store.save(todo))
                let before = store.snapshot
                list.beginEditing(todo, isNew: false)
                let editor = try XCTUnwrap(list.inlineEditor)
                try headingControl(NSTextField.self, in: editor, label: "任务标题").stringValue = "未保存标题"
                try headingControl(NSButton.self, in: editor, label: "勾选检查列表项").performClick(nil)
                editor.addChecklist()
                let fields = headingDescendants(editor).compactMap { $0 as? NSTextField }
                    .filter { $0.accessibilityLabel() == "检查列表项" }
                XCTAssertEqual(fields.count, 2)
                fields[1].stringValue = "未保存检查项"
                XCTAssertNotEqual(editor.collect(), todo)
                list.cancelInlineEditing()
                XCTAssertNil(list.inlineEditor)
                XCTAssertEqual(store.snapshot, before)
                XCTAssertEqual(TaskStore(fileURL: url).snapshot, before)

                list.newTask(inHeading: project.headings[0].id)
                let newEditor = try XCTUnwrap(list.inlineEditor)
                let newID = newEditor.collect().id
                try headingControl(NSTextField.self, in: newEditor, label: "任务标题").stringValue = "取消的新待办"
                newEditor.addChecklist()
                try headingControl(NSTextField.self, in: newEditor, label: "检查列表项").stringValue = "取消的新检查项"
                XCTAssertEqual(newEditor.collect().headingID, project.headings[0].id)
                list.cancelInlineEditing()
                XCTAssertNil(store.todo(newID))
                XCTAssertEqual(store.snapshot, before)
                XCTAssertEqual(TaskStore(fileURL: url).snapshot, before)
            }
        }
    }

    @MainActor private func cardFixture(_ body: (TaskStore, TaskListController, URL, Project) throws -> Void) throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("db.json")
        let store = TaskStore(fileURL: url)
        let project = Project(title: "卡片集成项目", headings: [Heading(title: "同名标题", order: 0), Heading(title: "同名标题", order: 1)])
        XCTAssertTrue(store.saveProject(project))
        let list = TaskListController(store: store)
        _ = list.view
        list.route = .project(project.id)
        try body(store, list, url, project)
    }

    @MainActor private func headingDescendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { headingDescendants($0) }
    }

    @MainActor private func headingControl<T: NSView>(_ type: T.Type, in view: NSView, label: String? = nil) throws -> T {
        try XCTUnwrap(headingDescendants(view).compactMap { $0 as? T }
            .first { label == nil || $0.accessibilityLabel() == label })
    }

    func testAddAndRenamePreserveProjectHeadingsTodosAndChecklist() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.json")
            let store = TaskStore(fileURL: url)
            let heading = Heading(title: "原标题", order: 5, notes: "备注", source: SourceInfo(provider: "fixture", identifier: "heading"))
            let project = Project(title: "项目", notes: "项目备注", headings: [heading], tags: ["标签"])
            let other = Project(title: "其他项目", headings: [Heading(title: "其他标题")])
            XCTAssertTrue(store.saveProject(project))
            XCTAssertTrue(store.saveProject(other))
            let todo = Todo(title: "已有待办", schedule: .anytime, projectID: project.id, headingID: heading.id,
                            checklist: [ChecklistItem(title: "已有检查项", completed: true)])
            XCTAssertTrue(store.save(todo))
            let before = store.snapshot
            let firstID = try XCTUnwrap(store.addHeading(title: " 同名标题\n", to: project.id))
            let secondID = try XCTUnwrap(store.addHeading(title: "同名标题", to: project.id))
            XCTAssertNotEqual(firstID, secondID)
            var expected = project
            expected.headings += [Heading(id: firstID, title: "同名标题", order: 6), Heading(id: secondID, title: "同名标题", order: 7)]
            XCTAssertEqual(store.snapshot.projects, [expected, other])
            XCTAssertEqual(store.snapshot.todos, before.todos)
            XCTAssertTrue(store.renameHeading(heading.id, title: " 改名\n", in: project.id))
            expected.headings[0].title = "改名"
            XCTAssertEqual(store.snapshot.projects, [expected, other])
            XCTAssertEqual(store.snapshot.todos, before.todos)
            XCTAssertEqual(try SnapshotFile(url: url).load(), store.snapshot)
            store.undo()
            XCTAssertEqual(store.snapshot.projects[0].headings[0], heading)
            store.redo()
            XCTAssertEqual(store.snapshot.projects[0], expected)
        }
    }

    func testGroupedTodoPersistsHeadingAndOwnsChecklistAndRejectsWrongProject() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.json")
            let store = TaskStore(fileURL: url)
            let project = Project(title: "项目")
            let other = Project(title: "其他项目")
            XCTAssertTrue(store.saveProject(project))
            XCTAssertTrue(store.saveProject(other))
            let headingID = try XCTUnwrap(store.addHeading(title: "分组", to: project.id))
            let checklist = [ChecklistItem(title: "检查项")]
            let todo = Todo(title: "分组待办", schedule: .anytime, projectID: project.id, headingID: headingID, checklist: checklist)
            XCTAssertTrue(store.save(todo))
            let loaded = try SnapshotFile(url: url).load()
            XCTAssertEqual(loaded.todos.first?.projectID, project.id)
            XCTAssertEqual(loaded.todos.first?.headingID, headingID)
            XCTAssertEqual(loaded.todos.first?.checklist, checklist)
            XCTAssertEqual(loaded.projects[0].headings.map(\.id), [headingID])
            XCTAssertFalse(store.save(Todo(title: "跨项目引用", projectID: other.id, headingID: headingID)))
            XCTAssertFalse(store.save(Todo(title: "无项目引用", headingID: headingID)))
            XCTAssertFalse(store.save(Todo(title: "不存在的标题", projectID: project.id, headingID: UUID())))
            XCTAssertEqual(store.snapshot, loaded)
            XCTAssertEqual(try SnapshotFile(url: url).load(), loaded)
        }
    }

    func testInvalidHeadingEditsLeaveSnapshotUnchanged() async {
        await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TaskStore(fileURL: folder.appendingPathComponent("db.json"))
            let heading = Heading(title: "标题")
            let deleted = Heading(title: "已删除", deletedAt: Date())
            let project = Project(title: "项目", headings: [heading, deleted])
            let trashed = Project(title: "已删除项目", deletedAt: Date())
            XCTAssertTrue(store.saveProject(project))
            XCTAssertTrue(store.saveProject(trashed))
            let before = store.snapshot
            XCTAssertNil(store.addHeading(title: " \n\t", to: project.id))
            XCTAssertNil(store.addHeading(title: "标题", to: UUID()))
            XCTAssertNil(store.addHeading(title: "标题", to: trashed.id))
            XCTAssertFalse(store.renameHeading(heading.id, title: " \n", in: project.id))
            XCTAssertFalse(store.renameHeading(UUID(), title: "新文字", in: project.id))
            XCTAssertFalse(store.renameHeading(heading.id, title: "新文字", in: trashed.id))
            XCTAssertFalse(store.renameHeading(deleted.id, title: "新文字", in: project.id))
            XCTAssertEqual(store.snapshot, before)
        }
    }

    func testFailedDiskWriteDoesNotAddOrRenameHeading() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.json")
            let store = TaskStore(fileURL: url)
            let heading = Heading(title: "原标题")
            let project = Project(title: "项目", headings: [heading])
            XCTAssertTrue(store.saveProject(project))
            let before = store.snapshot
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertNil(store.addHeading(title: "新增", to: project.id))
            XCTAssertFalse(store.renameHeading(heading.id, title: "改名", in: project.id))
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.snapshot, before)
            try FileManager.default.removeItem(at: url)
            try SnapshotFile(url: url).write(before)
            store.undo()
            XCTAssertTrue(store.snapshot.projects.isEmpty)
        }
    }
}
