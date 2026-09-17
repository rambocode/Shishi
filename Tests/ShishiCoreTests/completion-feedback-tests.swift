import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class CompletionFeedbackTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private func fixture() throws -> (TaskListController, TaskStore, URL, Project, [Todo]) {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let heading = Heading(title: "阶段")
        let project = Project(title: "完成反馈", headings: [heading])
        let tasks = (0..<3).map { Todo(title: "任务\($0)", schedule: .anytime, projectID: project.id, headingID: heading.id, order: Double($0)) }
        let url = folder.appendingPathComponent("library.json")
        try SnapshotFile(url: url).write(Snapshot(todos: tasks, projects: [project]))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Shishi.CompletionFeedbackTests." + UUID().uuidString))
        let store = TaskStore(fileURL: url, preferences: GeneralPreferences(defaults: defaults))
        let list = TaskListController(store: store)
        _ = list.view
        list.route = .project(project.id)
        return (list, store, folder, project, tasks)
    }

    @MainActor private func click(_ id: UUID, in list: TaskListController) throws {
        let row = try XCTUnwrap((0..<list.numberOfRows(in: list.table)).first { list.task(at: $0)?.id == id })
        let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: row))
        let check = try XCTUnwrap(descendants(cell).compactMap { $0 as? NSButton }.first)
        check.performClick(nil)
    }

    func testFailedSaveRestoresOpenCheckbox() async throws {
        try await MainActor.run {
            let (list, store, folder, _, tasks) = try fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("library.json")
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try click(tasks[0].id, in: list)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.todo(tasks[0].id)?.status, .open)
            XCTAssertEqual(list.task(at: 1)?.status, .open)
            let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 1))
            XCTAssertEqual(descendants(cell).compactMap { $0 as? NSButton }.first?.state, .off)
        }
    }

    func testLastInboxTaskRemainsUntilFeedbackExpires() async throws {
        let (list, store, folder, _, tasks) = try await MainActor.run { try fixture() }
        defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            store.move(tasks[0].id, to: .inbox)
            list.route = .inbox
            try click(tasks[0].id, in: list)
            XCTAssertEqual(list.task(at: 0)?.id, tasks[0].id)
            XCTAssertEqual(list.task(at: 0)?.status, .completed)
            let empty = try XCTUnwrap(descendants(list.view).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("暂无任务") })
            XCTAssertTrue(empty.isHidden, "反馈期间不能提前显示空列表提示")
        }
        try await Task.sleep(nanoseconds: 1_800_000_000)
        await MainActor.run { XCTAssertEqual(list.numberOfRows(in: list.table), 0) }
    }

    func testCompletedTaskShowsCheckmarkBeforeLeavingList() async throws {
        let (list, store, folder, _, tasks) = try await MainActor.run { try fixture() }
        defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            try click(tasks[0].id, in: list)
            XCTAssertEqual(store.todo(tasks[0].id)?.status, .completed, "完成立即保存，不延后持久化")
            XCTAssertEqual(list.task(at: 1)?.id, tasks[0].id, "短暂停留在原位置")
            XCTAssertEqual(list.task(at: 1)?.status, .completed)
            let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 1))
            let check = try XCTUnwrap(descendants(cell).compactMap { $0 as? NSButton }.first)
            XCTAssertEqual(check.state, .on)
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        await MainActor.run { XCTAssertEqual(list.task(at: 1)?.id, tasks[0].id, "1.5 秒停留结束前仍显示已勾选任务") }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await MainActor.run {
            XCTAssertFalse((0..<list.numberOfRows(in: list.table)).contains { list.task(at: $0)?.id == tasks[0].id })
            XCTAssertEqual(list.task(at: 1)?.id, tasks[1].id)
        }
    }

    func testSecondClickReopensAndCancelsRemoval() async throws {
        let (list, store, folder, _, tasks) = try await MainActor.run { try fixture() }
        defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            try click(tasks[0].id, in: list)
            try click(tasks[0].id, in: list)
            XCTAssertEqual(store.todo(tasks[0].id)?.status, .open)
        }
        try await Task.sleep(nanoseconds: 1_800_000_000)
        await MainActor.run {
            XCTAssertEqual(list.task(at: 1)?.id, tasks[0].id)
            XCTAssertEqual(list.task(at: 1)?.status, .open)
        }
    }

    func testMultipleCompletionsKeepPositionsAndRouteChangeClearsFeedback() async throws {
        let (list, store, folder, project, tasks) = try await MainActor.run { try fixture() }
        defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            try click(tasks[0].id, in: list)
            try click(tasks[1].id, in: list)
            list.reload()
            XCTAssertEqual(list.task(at: 1)?.id, tasks[0].id)
            XCTAssertEqual(list.task(at: 2)?.id, tasks[1].id)
            list.route = .inbox
            XCTAssertEqual(list.numberOfRows(in: list.table), 0)
            list.route = .project(project.id)
            XCTAssertEqual(list.task(at: 1)?.id, tasks[2].id)
            XCTAssertEqual(store.todo(tasks[0].id)?.status, .completed)
        }
        try await Task.sleep(nanoseconds: 1_800_000_000)
        await MainActor.run { XCTAssertEqual(list.task(at: 1)?.id, tasks[2].id) }
    }
}
