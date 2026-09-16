import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class ProjectHistoryTests: XCTestCase {
    @MainActor private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
    func testProjectProgressAndHistoryToggleTrackRealRecordsAndRestore() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = TaskStore(fileURL: dir.appendingPathComponent("db.json"))
            let project = Project(title: "四项待办与六项记录")
            XCTAssertTrue(store.saveProject(project))
            for index in 0..<10 {
                XCTAssertTrue(store.save(Todo(title: "任务\(index)", status: index < 4 ? .open : .completed,
                    schedule: .anytime, projectID: project.id, completedAt: index < 4 ? nil : Date(timeIntervalSince1970: Double(index)))))
            }
            let list = TaskListController(store: store)
            _ = list.view; list.route = .project(project.id)
            let table = try XCTUnwrap(allViews(list.view).compactMap { $0 as? NSTableView }.first)
            @MainActor func shown() -> [Todo] { (0..<list.numberOfRows(in: table)).compactMap { list.task(at: $0) } }
            XCTAssertEqual(shown().count, 4)
            let progress = try XCTUnwrap(allViews(list.view).compactMap { $0 as? ProjectProgressView }.first)
            XCTAssertEqual(progress.fraction, 0.6, accuracy: 0.001)
            let row = try XCTUnwrap(list.tableView(table, viewFor: table.tableColumns[0], row: 4))
            let button = try XCTUnwrap(allViews(row).compactMap { $0 as? NSButton }.first)
            XCTAssertEqual(button.title, "显示 6 个录入项")
            button.performClick(nil)
            XCTAssertTrue(list.isProjectHistoryExpanded)
            XCTAssertEqual(shown().count, 10)
            XCTAssertEqual(shown().suffix(6).map(\.status), Array(repeating: .completed, count: 6))
            let closed = try XCTUnwrap(shown().last)
            store.toggle(closed.id)
            XCTAssertEqual(shown().filter { $0.status == .open }.count, 5)
            XCTAssertEqual(progress.fraction, 0.5, accuracy: 0.001)
            list.toggleProjectHistory()
            XCTAssertEqual(shown().count, 5)
            list.route = .inbox; list.route = .project(project.id)
            XCTAssertFalse(list.isProjectHistoryExpanded)
            XCTAssertEqual(shown().count, 5)
        }
    }
    func testHistoryToggleDoesNotDiscardInvalidDraft() async {
        await MainActor.run {
            _ = NSApplication.shared
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = TaskStore(fileURL: dir.appendingPathComponent("db.json"))
            let project = Project(title: "保护草稿")
            XCTAssertTrue(store.saveProject(project))
            let list = TaskListController(store: store); _ = list.view; list.route = .project(project.id)
            list.beginEditing(Todo(title: "", notes: "不能丢失", projectID: project.id), isNew: true)
            list.toggleProjectHistory()
            XCTAssertFalse(list.isProjectHistoryExpanded)
            XCTAssertNotNil(list.inlineEditor)
            XCTAssertTrue(store.todos.isEmpty)
        }
    }
}
