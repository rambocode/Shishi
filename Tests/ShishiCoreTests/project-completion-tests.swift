import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class ProjectCompletionTests: XCTestCase {
    func testFinishUpdatesOnlyOpenRealTasksAndIsIdempotent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let deletedHeading = Heading(title: "删除分组", deletedAt: now)
        let project = Project(title: "项目", headings: [deletedHeading])
        let tasks = [
            Todo(title: "待完成", projectID: project.id),
            Todo(title: "已完成", status: .completed, projectID: project.id, completedAt: now.addingTimeInterval(-100)),
            Todo(title: "已取消", status: .canceled, projectID: project.id),
            Todo(title: "已删除", projectID: project.id, deletedAt: now),
            Todo(title: "删除分组任务", projectID: project.id, headingID: deletedHeading.id),
            Todo(title: "内部模板", projectID: project.id, source: SourceInfo(provider: "things", identifier: "template", metadata: ["repeatTemplate": "true"])),
            Todo(title: "其它任务")
        ]
        for status in [TaskStatus.completed, .canceled] {
            var snapshot = Snapshot(todos: tasks, projects: [project])
            XCTAssertTrue(try ProjectOperations.finish(project.id, status: status, in: &snapshot, now: now))
            XCTAssertEqual(snapshot.projects[0].status, status)
            XCTAssertTrue(snapshot.projects[0].completed)
            XCTAssertEqual(snapshot.todos[0].status, status)
            XCTAssertEqual(snapshot.todos[0].completedAt, now)
            XCTAssertEqual(Array(snapshot.todos.dropFirst()), Array(tasks.dropFirst()))
            let finished = snapshot
            XCTAssertFalse(try ProjectOperations.finish(project.id, status: status, in: &snapshot, now: now))
            XCTAssertEqual(snapshot, finished)
        }
        var snapshot = Snapshot(todos: tasks, projects: [project])
        XCTAssertThrowsError(try ProjectOperations.finish(project.id, status: .open, in: &snapshot, now: now))
        XCTAssertEqual(snapshot.todos, tasks)
        XCTAssertEqual(snapshot.projects, [project])
        XCTAssertFalse(try ProjectOperations.finish(UUID(), status: .completed, in: &snapshot, now: now))
    }

    func testFinishRepeatingProjectCreatesOneOpenSuccessorAndCancelCreatesNone() throws {
        let project = Project(title: "重复项目", repeatRule: RepeatRule(unit: .day))
        let task = Todo(title: "子任务", projectID: project.id)
        for status in [TaskStatus.completed, .canceled] {
            var snapshot = Snapshot(todos: [task], projects: [project])
            XCTAssertTrue(try ProjectOperations.finish(project.id, status: status, in: &snapshot,
                                                       now: Date(timeIntervalSince1970: 1_800_000_000)))
            XCTAssertEqual(snapshot.projects.count, status == .completed ? 2 : 1)
            if status == .completed {
                XCTAssertFalse(snapshot.projects[1].completed)
                XCTAssertEqual(snapshot.todos[1].status, .open)
            }
        }
    }

    func testStoreFinishIsOneUndoTransactionAndWriteFailurePreservesTree() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let project = Project(title: "原子关闭")
            let task = Todo(title: "子任务", projectID: project.id)
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(todos: [task], projects: [project]))
            let store = TaskStore(fileURL: url)
            let original = store.snapshot
            XCTAssertTrue(store.finishProject(project.id, status: .canceled))
            XCTAssertEqual(store.todo(task.id)?.status, .canceled)
            store.undo()
            XCTAssertEqual(store.snapshot, original)
            store.redo()
            XCTAssertEqual(store.projects[0].status, .canceled)
            store.undo()
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertFalse(store.finishProjectWithFeedback(project.id, status: .completed))
            XCTAssertNil(store.projectCompletionFeedback[project.id])
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.snapshot, original)
        }
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testDialogOffersAllChoicesAndRendersReferenceLayout() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let dialog = ProjectCompletionController(openCount: 3)
            dialog.view.frame = NSRect(x: 0, y: 0, width: 280, height: 190)
            dialog.view.layoutSubtreeIfNeeded()
            let message = try XCTUnwrap(descendants(dialog.view).compactMap { $0 as? NSTextField }.first)
            XCTAssertTrue(message.stringValue.contains("3 个未完成"))
            let buttons = descendants(dialog.view).compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.map(\.title), ["标记为已完成", "标记为已取消", "取消"])
            var choices: [TaskStatus?] = []
            dialog.onChoice = { choices.append($0) }
            for button in buttons { button.performClick(nil) }
            XCTAssertEqual(choices, [.completed, .canceled, nil])
            XCTAssertEqual(buttons[0].keyEquivalent, "\r")
            XCTAssertEqual(buttons[2].keyEquivalent, "\u{1b}")
            for button in buttons {
                XCTAssertGreaterThan(button.frame.width, 200)
                XCTAssertGreaterThanOrEqual(button.frame.height, 30)
            }
            if let path = ProcessInfo.processInfo.environment["SHISHI_COMPLETION_CAPTURE"] {
                let bitmap = try XCTUnwrap(dialog.view.bitmapImageRepForCachingDisplay(in: dialog.view.bounds))
                dialog.view.cacheDisplay(in: dialog.view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func testPromptCancelPreservesDataAndChoicesUpdateLatestTasks() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let project = Project(title: "确认项目")
            let task = Todo(title: "原任务", projectID: project.id)
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(todos: [task], projects: [project]))
            let store = TaskStore(fileURL: url)
            let actions = ProjectActionsController(store: store)
            let original = store.snapshot
            let prompt = try XCTUnwrap(actions.completionPrompt(projectID: project.id))
            let buttons = descendants(prompt.view).compactMap { $0 as? NSButton }
            buttons[2].performClick(nil)
            XCTAssertEqual(store.snapshot, original)
            let lateTask = Todo(title: "确认期间新任务", projectID: project.id)
            store.save(lateTask)
            buttons[0].performClick(nil)
            XCTAssertEqual(store.todo(task.id)?.status, .completed)
            XCTAssertEqual(store.todo(lateTask.id)?.status, .completed)
            XCTAssertEqual(store.projects[0].status, .completed)
            store.undo()
            let cancellation = try XCTUnwrap(actions.completionPrompt(projectID: project.id))
            descendants(cancellation.view).compactMap { $0 as? NSButton }[1].performClick(nil)
            XCTAssertEqual(store.projects[0].status, .canceled)
            XCTAssertEqual(store.todo(task.id)?.status, .canceled)
            XCTAssertEqual(store.todo(lateTask.id)?.status, .canceled)
        }
    }

    func testProjectCompletionShowsTickAndRetainsRowsUntilDelayExpires() async throws {
        let (store, sidebar, list, folder, project, task) = try await MainActor.run {
            _ = NSApplication.shared
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let project = Project(title: "延迟完成项目")
            let task = Todo(title: "剩余任务", projectID: project.id)
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(todos: [task], projects: [project]))
            let store = TaskStore(fileURL: url)
            let sidebar = SidebarController(store: store)
            _ = sidebar.view
            sidebar.select(.project(project.id))
            let list = TaskListController(store: store)
            _ = list.view
            list.route = .project(project.id)
            return (store, sidebar, list, folder, project, task)
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            XCTAssertTrue(store.finishProjectWithFeedback(project.id, status: .completed))
            XCTAssertEqual(store.projects[0].status, .completed)
            XCTAssertEqual(store.todo(task.id)?.status, .completed)
            XCTAssertEqual(list.task(at: 0)?.id, task.id)
            let header = try XCTUnwrap(descendants(list.view).compactMap { $0 as? ProjectProgressView }.first)
            XCTAssertTrue(header.showsCheckmark)
            let table = try XCTUnwrap(descendants(sidebar.view).compactMap { $0 as? NSTableView }.first)
            XCTAssertGreaterThanOrEqual(table.selectedRow, 0)
            let cell = try XCTUnwrap(sidebar.tableView(table, viewFor: table.tableColumns[0], row: table.selectedRow))
            XCTAssertTrue(try XCTUnwrap(descendants(cell).compactMap { $0 as? ProjectProgressView }.first).showsCheckmark)
            let openProject = Project(title: "仅任务全完成")
            let icon = ProjectProgressView()
            icon.configure(project: openProject, summary: ProjectSummary(project: openProject, tasks: [Todo(title: "已完成", status: .completed, projectID: openProject.id)]))
            XCTAssertEqual(icon.fraction, 1)
            XCTAssertFalse(icon.showsCheckmark)
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        await MainActor.run {
            XCTAssertNotNil(store.projectCompletionFeedback[project.id])
            XCTAssertEqual(list.task(at: 0)?.id, task.id)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await MainActor.run {
            XCTAssertNil(store.projectCompletionFeedback[project.id])
            let table = try XCTUnwrap(descendants(sidebar.view).compactMap { $0 as? NSTableView }.first)
            XCTAssertEqual(table.selectedRow, -1)
            XCTAssertFalse((0..<list.numberOfRows(in: list.table)).contains { list.task(at: $0)?.id == task.id })
        }
    }

    func testReopeningProjectCancelsPendingRemoval() async throws {
        let (store, folder, project) = try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let project = Project(title: "恢复项目")
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(projects: [project]))
            let store = TaskStore(fileURL: url)
            XCTAssertTrue(store.finishProjectWithFeedback(project.id, status: .completed))
            XCTAssertNotNil(store.projectCompletionFeedback[project.id])
            XCTAssertTrue(store.setProjectCompleted(project.id, completed: false))
            XCTAssertNil(store.projectCompletionFeedback[project.id])
            return (store, folder, project)
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Task.sleep(nanoseconds: 1_800_000_000)
        await MainActor.run {
            XCTAssertEqual(store.projects.first { $0.id == project.id }?.status, .open)
            XCTAssertNil(store.projectCompletionFeedback[project.id])
        }
    }

    func testConfirmationDrawsTickBeforeDeferredSaveAndCancelDoesNotScheduleWork() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let project = Project(title: "先反馈后保存")
            let task = Todo(title: "开放任务", projectID: project.id)
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(todos: [task], projects: [project]))
            let store = TaskStore(fileURL: url)
            var queued: [() -> Void] = []
            let actions = ProjectActionsController(store: store, scheduleCompletion: { queued.append($0) })
            let progress = ProjectProgressView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            progress.configure(project: project, summary: ProjectSummary(project: project, tasks: [task]))
            let window = NSWindow(contentRect: progress.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = progress
            defer { window.close() }
            let prompt = try XCTUnwrap(actions.completionPrompt(projectID: project.id, from: progress))
            let buttons = descendants(prompt.view).compactMap { $0 as? NSButton }
            buttons[2].performClick(nil)
            XCTAssertTrue(queued.isEmpty)
            XCTAssertFalse(progress.showsCheckmark)
            buttons[0].performClick(nil)
            XCTAssertTrue(progress.showsCheckmark, "保存执行前必须已显示勾号")
            XCTAssertFalse(progress.needsDisplay)
            XCTAssertFalse(store.projects[0].completed)
            XCTAssertEqual(store.todo(task.id)?.status, .open)
            XCTAssertEqual(queued.count, 1)
            buttons[0].performClick(nil)
            XCTAssertEqual(queued.count, 1, "等待保存时不能重复提交")
            queued.removeFirst()()
            XCTAssertEqual(store.projects[0].status, .completed)
            XCTAssertEqual(store.todo(task.id)?.status, .completed)
            store.undo()
            progress.configure(project: store.projects[0], summary: ProjectSummary(project: store.projects[0], tasks: store.todos))
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            buttons[0].performClick(nil)
            XCTAssertTrue(progress.showsCheckmark)
            queued.removeFirst()()
            XCTAssertFalse(progress.showsCheckmark, "写盘失败恢复原来的未勾选状态")
            XCTAssertEqual(store.todo(task.id)?.status, .open)
            XCTAssertNotNil(store.errorMessage)
        }
    }

    func testHeaderProgressIsClickableAndEmptyProjectCanReopen() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let project = Project(title: "空项目")
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(projects: [project]))
            let store = TaskStore(fileURL: url)
            let list = TaskListController(store: store)
            _ = list.view
            list.route = .project(project.id)
            let progress = try XCTUnwrap(descendants(list.view).compactMap { $0 as? ProjectProgressView }.first)
            XCTAssertNotNil(progress.onActivate)
            progress.performClick(nil)
            XCTAssertEqual(store.projects[0].status, .completed)
            progress.performClick(nil)
            XCTAssertEqual(store.projects[0].status, .open)
        }
    }
}
