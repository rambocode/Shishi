import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class CardRegressionTests: XCTestCase {
    func testMarkedEscapeDoesNotDiscardTitleOrChecklistDraft() async {
        await MainActor.run {
            _ = NSApplication.shared
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = TaskStore(fileURL: dir.appendingPathComponent("library.json"))
            let list = TaskListController(store: store)
            let task = Todo(title: "已经填写", checklist: [ChecklistItem(title: "检查资料")])
            list.beginEditing(task, isNew: true)
            XCTAssertFalse(list.handleInlineKey(53, modifiers: [], hasMarkedText: true))
            XCTAssertEqual(list.inlineEditor?.collect(), task)
            XCTAssertTrue(store.todos.isEmpty)
            XCTAssertTrue(list.handleInlineKey(36, modifiers: .command, hasMarkedText: false))
            XCTAssertEqual(store.todo(task.id)?.checklist.count, 1)
        }
    }
    func testMetadataOnlyDraftCannotBeSilentlyDiscardedByNavigation() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = TaskStore(fileURL: dir.appendingPathComponent("library.json"))
            let list = TaskListController(store: store)
            let task = Todo(title: "")
            list.beginEditing(task, isNew: true)
            let editor = try XCTUnwrap(list.inlineEditor)
            editor.applySchedule(.tomorrow)
            list.route = .inbox
            XCTAssertEqual(list.route, .today)
            XCTAssertTrue(list.inlineEditor === editor)
            XCTAssertNotNil(list.inlineEditor?.collect().startDate)
            XCTAssertTrue(store.todos.isEmpty)
            XCTAssertTrue(list.handleInlineKey(53, modifiers: [], hasMarkedText: false))
            XCTAssertNil(list.inlineEditor)
        }
    }
}
