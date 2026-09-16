import XCTest
import ShishiCore
@testable import Shishi

final class IntegrationTests: XCTestCase {
    func testAssignedInboxBecomesAnytimeAndFailedCommitNotifies() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.json")
            let store = TaskStore(fileURL: url)
            let area = Area(title: "工作")
            let project = Project(title: "项目", areaID: area.id)
            XCTAssertTrue(store.saveArea(area)); XCTAssertTrue(store.saveProject(project))
            let projectTask = Todo(title: "只选项目", projectID: project.id)
            let areaTask = Todo(title: "只选区域", areaID: area.id)
            XCTAssertEqual(Domain.normalized(projectTask).schedule, .anytime)
            XCTAssertEqual(Domain.normalized(areaTask).schedule, .anytime)
            XCTAssertTrue(store.save(projectTask)); XCTAssertTrue(store.save(areaTask))
            XCTAssertTrue(store.items(for: .inbox).isEmpty)
            XCTAssertEqual(Set(store.items(for: .anytime).map(\.id)), Set([projectTask.id, areaTask.id]))
            let failed = expectation(description: "失败通知")
            let observer = NotificationCenter.default.addObserver(forName: Notification.Name("ShishiStoreFailed"), object: nil, queue: nil) { notification in
                XCTAssertTrue((notification.object as? TaskStore) === store)
                failed.fulfill()
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            let previous = store.snapshot
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            store.cancel(projectTask.id)
            XCTAssertEqual(store.snapshot, previous)
            XCTAssertNotNil(store.errorMessage)
            wait(for: [failed], timeout: 1)
        }
    }
    func testCompletedProjectHidesOpenChildrenButKeepsHistoryAndRestore() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TaskStore(fileURL: folder.appendingPathComponent("db.json"))
            let area = Area(title: "工作")
            var project = Project(title: "发布", areaID: area.id)
            XCTAssertTrue(store.saveArea(area)); XCTAssertTrue(store.saveProject(project))
            let task = Todo(title: "开放子任务", schedule: .dated, startDate: Date(), projectID: project.id, tags: ["重点"])
            let finished = Todo(title: "历史", status: .completed, projectID: project.id, completedAt: Date())
            let trashed = Todo(title: "回收", projectID: project.id, deletedAt: Date())
            XCTAssertTrue(store.save(task)); XCTAssertTrue(store.save(finished)); XCTAssertTrue(store.save(trashed))
            project.completed = true
            XCTAssertTrue(store.saveProject(project))
            for route: Route in [.today, .anytime, .project(project.id), .area(area.id), .tag("重点"), .search("开放")] {
                XCTAssertTrue(store.items(for: route).isEmpty)
            }
            XCTAssertEqual(store.items(for: .logbook).map(\.id), [finished.id])
            XCTAssertEqual(store.items(for: .trash).map(\.id), [trashed.id])
            XCTAssertEqual(store.todo(task.id)?.status, .open)
            store.undo()
            XCTAssertEqual(store.items(for: .today).map(\.id), [task.id])
            store.redo()
            XCTAssertTrue(store.items(for: .today).isEmpty)
            project.completed = false
            XCTAssertTrue(store.saveProject(project))
            XCTAssertEqual(store.items(for: .area(area.id)).map(\.id), [task.id])
            try Domain.validate(store.snapshot)
        }
    }
    func testProjectAreaChangesSynchronizeAllChildrenAndPersist() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.json")
            let store = TaskStore(fileURL: url)
            let first = Area(title: "工作"), second = Area(title: "个人")
            let heading = Heading(title: "准备")
            var project = Project(title: "计划", areaID: first.id, headings: [heading])
            XCTAssertTrue(store.saveArea(first)); XCTAssertTrue(store.saveArea(second)); XCTAssertTrue(store.saveProject(project))
            let open = Todo(title: "开放", schedule: .anytime, projectID: project.id, areaID: second.id, headingID: heading.id)
            let done = Todo(title: "完成", status: .completed, projectID: project.id, completedAt: Date())
            let deleted = Todo(title: "删除", projectID: project.id, deletedAt: Date())
            for task in [open, done, deleted] { XCTAssertTrue(store.save(task)); XCTAssertEqual(store.todo(task.id)?.areaID, first.id) }
            project.areaID = second.id; project.headings = []
            XCTAssertTrue(store.saveProject(project))
            XCTAssertTrue(store.todos.allSatisfy { $0.areaID == second.id && $0.headingID == nil })
            XCTAssertTrue(store.items(for: .area(first.id)).isEmpty)
            XCTAssertEqual(store.items(for: .area(second.id)).map(\.id), [open.id])
            XCTAssertEqual(TaskStore(fileURL: url).snapshot, store.snapshot)
            store.undo()
            XCTAssertEqual(store.todo(open.id)?.areaID, first.id)
            XCTAssertEqual(store.todo(open.id)?.headingID, heading.id)
            store.redo()
            project.areaID = nil
            XCTAssertTrue(store.saveProject(project))
            XCTAssertTrue(store.todos.allSatisfy { $0.areaID == nil })
            store.move(open.id, to: .area(first.id))
            XCTAssertNil(store.todo(open.id)?.projectID)
            project.areaID = second.id; XCTAssertTrue(store.saveProject(project))
            store.move(open.id, to: .project(project.id))
            XCTAssertEqual(store.todo(open.id)?.areaID, second.id)
            try Domain.validate(store.snapshot)
        }
    }
    func testPartialReorderAndInvalidMoveAreTransactional() async {
        await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TaskStore(fileURL: folder.appendingPathComponent("db.json"))
            let tasks = (0..<4).map { Todo(title: "任务\($0)", order: Double($0)) }
            tasks.forEach { XCTAssertTrue(store.save($0)) }
            store.reorder([tasks[3].id, tasks[1].id])
            XCTAssertEqual(store.items(for: .inbox).map(\.id), [tasks[0].id, tasks[3].id, tasks[2].id, tasks[1].id])
            let previous = store.snapshot
            store.reorder([tasks[0].id, tasks[0].id]); XCTAssertEqual(store.snapshot, previous)
            store.reorder([UUID()]); XCTAssertEqual(store.snapshot, previous)
            store.move(tasks[0].id, to: .project(UUID())); XCTAssertEqual(store.snapshot, previous)
            store.move(tasks[0].id, to: .area(UUID())); XCTAssertEqual(store.snapshot, previous)
            store.undo()
            XCTAssertEqual(store.items(for: .inbox).map(\.id), tasks.map(\.id))
        }
    }
    func testDemoExplicitAndDoesNotReplaceExistingDatabase() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let plain = TaskStore(fileURL: folder.appendingPathComponent("plain.json"))
            XCTAssertTrue(plain.todos.isEmpty); XCTAssertTrue(plain.projects.isEmpty); XCTAssertTrue(plain.areas.isEmpty)
            let url = folder.appendingPathComponent("demo.json")
            let demo = TaskStore(fileURL: url, demo: true)
            XCTAssertNil(demo.errorMessage)
            XCTAssertEqual(demo.areas.count, 2); XCTAssertEqual(demo.projects.count, 3)
            XCTAssertEqual(demo.todos.count, 20)
            XCTAssertTrue(demo.projects.allSatisfy { !$0.headings.isEmpty })
            XCTAssertTrue(demo.items(for: .today).contains { $0.evening })
            XCTAssertFalse(demo.items(for: .upcoming).isEmpty)
            XCTAssertFalse(demo.items(for: .logbook).isEmpty)
            XCTAssertTrue(demo.todos.contains { !$0.checklist.isEmpty && !$0.tags.isEmpty })
            try Domain.validate(demo.snapshot)
            demo.todos.forEach { demo.trash($0.id) }
            let previous = demo.snapshot
            XCTAssertEqual(TaskStore(fileURL: url, demo: true).snapshot, previous)
        }
    }
}
