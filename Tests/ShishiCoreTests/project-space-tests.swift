import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class ProjectSpaceTests: XCTestCase {
    @MainActor private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    func testSpaceUsesNewTaskEntryAndKeepsSelectedHeading() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("library.json")
            let store = TaskStore(fileURL: url)
            let heading = Heading(title: "第一阶段")
            let project = Project(title: "项目", headings: [heading])
            XCTAssertTrue(store.saveProject(project))
            let owner = MainWindowController(store: store, dataURL: url)
            defer { owner.window?.close() }
            owner.navigate(.project(project.id))
            let list = owner.list
            let table = try XCTUnwrap(allViews(list.view).compactMap { $0 as? NSTableView }.first)
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            XCTAssertTrue(list.handleSpaceNewTask(49, modifiers: [], responder: table))
            let editor = try XCTUnwrap(list.inlineEditor)
            XCTAssertTrue(editor.isNew)
            XCTAssertEqual(editor.collect().projectID, project.id)
            XCTAssertEqual(editor.collect().headingID, heading.id)
            XCTAssertTrue(store.todos.isEmpty, "快捷键只打开草稿，不提前创建空任务")
            XCTAssertFalse(list.handleSpaceNewTask(49, modifiers: [], responder: table))
            XCTAssertTrue(list.inlineEditor === editor)
            list.cancelInlineEditing()
        }
    }

    func testTextInputsControlsModifiersRepeatAndOtherRoutesAreNotIntercepted() async {
        await MainActor.run {
            _ = NSApplication.shared
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TaskStore(fileURL: folder.appendingPathComponent("library.json"))
            var project = Project(title: "项目")
            XCTAssertTrue(store.saveProject(project))
            let list = TaskListController(store: store); _ = list.view; list.route = .project(project.id)
            var calls = 0; list.onNewTask = { calls += 1 }
            let text = NSTextView(); text.isEditable = true
            for input: NSResponder in [text, NSTextField(), NSSearchField(), NSButton()] {
                XCTAssertFalse(list.handleSpaceNewTask(49, modifiers: [], responder: input))
            }
            for flags: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
                XCTAssertFalse(list.handleSpaceNewTask(49, modifiers: flags, responder: nil))
            }
            XCTAssertFalse(list.handleSpaceNewTask(49, modifiers: [], responder: nil, isRepeat: true))
            XCTAssertFalse(list.handleSpaceNewTask(36, modifiers: [], responder: nil))
            for route: Route in [.trash, .logbook, .search("x")] {
                list.route = route
                XCTAssertFalse(list.handleSpaceNewTask(49, modifiers: [], responder: nil))
            }
            list.route = .project(project.id)
            project.completed = true; project.status = .completed; XCTAssertTrue(store.saveProject(project))
            XCTAssertFalse(list.handleSpaceNewTask(49, modifiers: [], responder: nil))
            XCTAssertEqual(calls, 0)
        }
    }
    /// 项目中未选择任何行时，空格新建的草稿不关联标题。
    func testSpaceWithoutSelectionCreatesTaskWithoutHeading() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("library.json")
            let store = TaskStore(fileURL: url)
            let project = Project(title: "项目", headings: [Heading(title: "第一阶段")])
            XCTAssertTrue(store.saveProject(project))
            let owner = MainWindowController(store: store, dataURL: url)
            defer { owner.window?.close() }
            owner.navigate(.project(project.id))
            let list = owner.list
            list.clearSelection()
            XCTAssertTrue(list.handleSpaceNewTask(49, modifiers: [], responder: list.table))
            let editor = try XCTUnwrap(list.inlineEditor)
            XCTAssertEqual(editor.collect().projectID, project.id)
            XCTAssertNil(editor.collect().headingID)
            list.cancelInlineEditing()
        }
    }

    /// 普通列表（如收件箱）同样支持空格新建，草稿沿用该列表的新建归属。
    func testSpaceCreatesTaskInRegularLists() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("library.json")
            let store = TaskStore(fileURL: url)
            let owner = MainWindowController(store: store, dataURL: url)
            defer { owner.window?.close() }
            for route: Route in [.inbox, .today, .anytime, .someday] {
                owner.navigate(route)
                let list = owner.list
                XCTAssertTrue(list.handleSpaceNewTask(49, modifiers: [], responder: list.table))
                let editor = try XCTUnwrap(list.inlineEditor)
                XCTAssertTrue(editor.isNew)
                XCTAssertNil(editor.collect().headingID)
                list.cancelInlineEditing()
            }
            XCTAssertTrue(store.todos.isEmpty, "取消后不留下空任务")
        }
    }
}
