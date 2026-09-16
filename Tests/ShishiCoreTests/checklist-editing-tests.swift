import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class ChecklistEditingTests: XCTestCase {
    func testBottomDeletionRequiresASelectionAndCannotDeleteNeighborOrParent() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shishi-delete-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = TaskStore(fileURL: dir.appendingPathComponent("db.json"))
            let todo = Todo(title: "保留父待办", schedule: .anytime, checklist: [ChecklistItem(title: "保留一"), ChecklistItem(title: "删除此项"), ChecklistItem(title: "保留二")])
            XCTAssertTrue(store.save(todo))
            let list = TaskListController(store: store); list.route = .anytime
            list.beginEditing(todo, isNew: false)
            let card = try XCTUnwrap(list.inlineEditor)
            let checklist = try XCTUnwrap(descendants(card).compactMap { $0 as? InlineChecklistView }.first)
            let fields = descendants(checklist).compactMap { $0 as? NSTextField }
            checklist.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: fields[1]))
            let bottom = try XCTUnwrap(descendants(list.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "删除选中的检查项" })
            XCTAssertFalse(bottom.isDescendant(of: card))
            bottom.performClick(nil)
            XCTAssertFalse(bottom.isEnabled)
            XCTAssertFalse(list.canDeleteSelection)
            XCTAssertTrue(list.inlineEditor === card)
            let remaining = [todo.checklist[0], todo.checklist[2]]
            XCTAssertEqual(card.collect().checklist, remaining)
            list.deleteSelected()
            XCTAssertEqual(card.collect().checklist, remaining)
            XCTAssertNil(store.todo(todo.id)?.deletedAt)
            XCTAssertTrue(list.finishInlineEditing())
            XCTAssertEqual(store.todo(todo.id)?.title, todo.title)
            XCTAssertEqual(store.todo(todo.id)?.checklist, remaining)
            XCTAssertEqual(store.todo(todo.id)?.status, .open)
        }
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    func testSavedChecklistAcceptsMouseEditingAndPersistsOnlyItsOwnText() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shishi-focus-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("library.json")
            let store = TaskStore(fileURL: url)
            let first = ChecklistItem(title: "已经完成的步骤", completed: true)
            let second = ChecklistItem(title: "需要修改的步骤")
            let todo = Todo(title: "父标题保持不变", schedule: .anytime, checklist: [first, second])
            XCTAssertTrue(store.save(todo))
            let list = TaskListController(store: store)
            list.route = .anytime
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = list.view
            defer { window.contentView = nil; window.close() }
            list.beginEditing(try XCTUnwrap(store.todo(todo.id)), isNew: false)
            window.contentView?.layoutSubtreeIfNeeded()
            let card = try XCTUnwrap(list.inlineEditor)
            let fields = descendants(card).compactMap { $0 as? NSTextField }.filter { $0.accessibilityLabel() == "检查列表项" }
            let table = try XCTUnwrap(descendants(list.view).compactMap { $0 as? ListTableView }.first)
            XCTAssertEqual(fields.count, 2)
            for (index, field) in fields.enumerated() {
                for clickCount in [1, 2] {
                    let point = field.convert(NSPoint(x: 15, y: 8), to: nil)
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 1, clickCount: clickCount, pressure: 1))
                    // 使用 NSTextField.mouseDown 实际调用的响应链校验，禁止绕过表格的焦点检查。
                    XCTAssertTrue(field.validateProposedFirstResponder(field, for: event), "检查项\(index)的\(clickCount)击必须直接进入文字编辑")
                    XCTAssertTrue(table.validateProposedFirstResponder(field, for: event), "表格不能为子输入框等待父行双击判定")
                }
            }
            let field = fields[1]
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            // 表格可能在文字控件取得焦点后继续发出doubleAction，不能再把光标拉回父标题。
            list.edit()
            XCTAssertTrue(field.currentEditor() === editor, "已展开行的doubleAction不得抢走检查项焦点")
            editor.selectAll(nil)
            editor.insertText("修改后检查内容", replacementRange: editor.selectedRange())
            XCTAssertTrue(list.finishInlineEditing())
            let reloaded = TaskStore(fileURL: url)
            let saved = try XCTUnwrap(reloaded.todo(todo.id))
            XCTAssertEqual(saved.title, todo.title)
            XCTAssertEqual(saved.status, .open)
            XCTAssertEqual(saved.checklist.map(\.id), [first.id, second.id])
            XCTAssertEqual(saved.checklist.map(\.title), [first.title, "修改后检查内容"])
            XCTAssertEqual(saved.checklist.map(\.completed), [true, false])
            XCTAssertEqual(reloaded.todos.count, 1)
        }
    }
}
