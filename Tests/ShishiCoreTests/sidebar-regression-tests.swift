import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class SidebarRegressionTests: XCTestCase {
    @MainActor private func allViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }

    @MainActor private func table(in sidebar: SidebarController) throws -> NSTableView {
        try XCTUnwrap(allViews(sidebar.view).compactMap { $0 as? NSTableView }.first)
    }

    // 通过公开表格委托取得当前行，避免依赖私有 rows 或屏幕上的可见范围。
    @MainActor private func cells(in sidebar: SidebarController) throws -> [NSTableCellView] {
        let table = try table(in: sidebar)
        return try (0..<sidebar.numberOfRows(in: table)).map {
            try XCTUnwrap(sidebar.tableView(table, viewFor: table.tableColumns[0], row: $0) as? NSTableCellView)
        }
    }

    @MainActor private func progress(for project: Project, in sidebar: SidebarController) throws -> ProjectProgressView {
        let cell = try XCTUnwrap(try cells(in: sidebar).first { $0.textField?.stringValue == project.title })
        let icons = allViews(cell).compactMap { $0 as? ProjectProgressView }
        XCTAssertEqual(icons.count, 1)
        return try XCTUnwrap(icons.first)
    }

    func testSidebarProgressMatchesSummaryAndDetailAtZeroPartialAndFull() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let area = Area(title: "进度区域")
            let empty = Project(title: "零进度")
            let partial = Project(title: "部分进度", areaID: area.id)
            // 子任务全完成不等于项目本身已归档，100% 图标仍应可见。
            let full = Project(title: "全部子任务完成")
            let tasks = [
                Todo(title: "开放", projectID: partial.id, areaID: area.id,
                     checklist: [ChecklistItem(title: "不计入进度", completed: true)]),
                Todo(title: "完成", status: .completed, projectID: partial.id, areaID: area.id),
                Todo(title: "取消不计分母", status: .canceled, projectID: partial.id, areaID: area.id),
                Todo(title: "删除不计分母", projectID: partial.id, areaID: area.id, deletedAt: Date()),
                Todo(title: "全部完成", status: .completed, projectID: full.id)
            ]
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(todos: tasks, projects: [empty, partial, full], areas: [area]))
            let store = TaskStore(fileURL: url)
            let sidebar = SidebarController(store: store)
            let detail = TaskListController(store: store)
            _ = sidebar.view; _ = detail.view
            for (project, expected) in [(empty, 0.0), (partial, 0.5), (full, 1.0)] {
                let summary = ProjectSummary(project: project, tasks: store.todos)
                XCTAssertEqual(summary.fraction, expected, accuracy: 0.001)
                let icon = try progress(for: project, in: sidebar)
                XCTAssertEqual(icon.fraction, summary.fraction, accuracy: 0.001)
                detail.route = .project(project.id)
                let detailIcon = try XCTUnwrap(allViews(detail.view).compactMap { $0 as? ProjectProgressView }.first)
                XCTAssertEqual(icon.fraction, detailIcon.fraction, accuracy: 0.001)
            }
        }
    }

    func testTaskCompletionUndoRedoAndReopenRefreshSidebarProgress() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let project = Project(title: "动态进度")
            let task = Todo(title: "待完成", projectID: project.id)
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(todos: [task], projects: [project]))
            let store = TaskStore(fileURL: url)
            let sidebar = SidebarController(store: store); _ = sidebar.view
            @MainActor func check(_ expected: Double) throws {
                XCTAssertNil(store.errorMessage)
                let summary = ProjectSummary(project: project, tasks: store.todos)
                XCTAssertEqual(summary.fraction, expected, accuracy: 0.001)
                XCTAssertEqual(try progress(for: project, in: sidebar).fraction, summary.fraction, accuracy: 0.001)
            }
            try check(0)
            store.toggle(task.id); try check(1)
            store.undo(); try check(0)
            store.redo(); try check(1)
            store.toggle(task.id); try check(0)
        }
    }

    func testArchivedProjectsDisappearButRemainInLogbookAndUndoRestoresSidebar() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let area = Area(title: "归档区域")
            let active = Project(title: "正在进行")
            let completed = Project(title: "已完成根项目", completed: true, status: .completed)
            let canceled = Project(title: "已取消区域项目", areaID: area.id, completed: true, status: .canceled)
            let statusCompleted = Project(title: "仅状态已完成", areaID: area.id, status: .completed)
            let statusCanceled = Project(title: "仅状态已取消", status: .canceled)
            let archived = [completed, canceled, statusCompleted, statusCanceled]
            let archivedIDs = Set(archived.map(\.id))
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(projects: [active] + archived, areas: [area]))
            let store = TaskStore(fileURL: url)
            let sidebar = SidebarController(store: store); _ = sidebar.view
            @MainActor func titles() throws -> [String] { try cells(in: sidebar).compactMap { $0.textField?.stringValue } }
            XCTAssertTrue(try titles().contains(active.title))
            for title in archived.map(\.title) + ["已完成项目"] { XCTAssertFalse(try titles().contains(title)) }
            XCTAssertEqual(Set(store.projectItems(for: .logbook).map(\.id)), archivedIDs)
            XCTAssertTrue(store.setProjectCompleted(active.id, completed: true))
            XCTAssertFalse(try titles().contains(active.title))
            XCTAssertEqual(Set(store.projectItems(for: .logbook).map(\.id)), archivedIDs.union([active.id]))
            store.undo()
            XCTAssertTrue(try titles().contains(active.title))
            XCTAssertEqual(Set(store.projectItems(for: .logbook).map(\.id)), archivedIDs)
            store.redo()
            XCTAssertFalse(try titles().contains(active.title))
            XCTAssertTrue(store.setProjectCompleted(active.id, completed: false))
            XCTAssertTrue(try titles().contains(active.title))
        }
    }

    func testRoutesAbsentFromSidebarClearSelectionWithoutSelectingAnotherRoute() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let first = Project(title: "选中的项目", order: 0)
            let second = Project(title: "不能误选的邻居", order: 1)
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(projects: [first, second]))
            let store = TaskStore(fileURL: url)
            let sidebar = SidebarController(store: store); _ = sidebar.view
            let table = try table(in: sidebar)
            var callbacks: [Route] = []
            sidebar.onSelect = { callbacks.append($0) }
            sidebar.select(.project(first.id))
            XCTAssertGreaterThanOrEqual(table.selectedRow, 0)
            XCTAssertTrue(store.setProjectCompleted(first.id, completed: true))
            XCTAssertEqual(table.selectedRow, -1)
            XCTAssertTrue(table.selectedRowIndexes.isEmpty)
            XCTAssertEqual(sidebar.route, .project(first.id))
            XCTAssertTrue(callbacks.isEmpty)
            for hiddenRoute in [Route.search("查询"), .project(UUID()), .project(first.id)] {
                sidebar.select(.today)
                XCTAssertGreaterThanOrEqual(table.selectedRow, 0)
                sidebar.select(hiddenRoute)
                XCTAssertEqual(table.selectedRow, -1)
                XCTAssertTrue(table.selectedRowIndexes.isEmpty)
                XCTAssertEqual(sidebar.route, hiddenRoute)
                XCTAssertTrue(callbacks.isEmpty)
            }
            sidebar.select(.project(second.id))
            let selectedCell = try cells(in: sidebar)[table.selectedRow]
            XCTAssertEqual(selectedCell.textField?.stringValue, second.title)
        }
    }
}
