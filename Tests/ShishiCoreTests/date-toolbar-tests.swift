import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class DateToolbarTests: XCTestCase {
    @MainActor private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    func testDateRequiresSelectedOpenTaskAndCannotDefaultToProject() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TaskStore(fileURL: folder.appendingPathComponent("db.json"))
            let heading = Heading(title: "阶段")
            let project = Project(title: "项目", headings: [heading])
            XCTAssertTrue(store.saveProject(project))
            let task = Todo(title: "待办", schedule: .anytime, projectID: project.id, headingID: heading.id)
            XCTAssertTrue(store.save(task))
            let list = TaskListController(store: store); _ = list.view; list.route = .project(project.id)
            let table = try XCTUnwrap(views(list.view).compactMap { $0 as? NSTableView }.first)
            let buttons = views(list.view).compactMap { $0 as? NSButton }.filter { $0.accessibilityLabel() == "时间" }
            XCTAssertEqual(buttons.count, 2)
            XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled })
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); list.updateTools()
            XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled }, "标题不能修改项目日期")
            list.selectTask(task.id)
            XCTAssertTrue(buttons.allSatisfy(\.isEnabled))
            list.beginEditing(task, isNew: false)
            XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled })
            list.cancelInlineEditing()
            list.route = .anytime
            list.selectProject(project.id)
            XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled }, "选择项目不能代替选择任务")
        }
    }
}
