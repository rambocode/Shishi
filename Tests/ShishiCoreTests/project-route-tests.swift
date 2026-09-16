import Foundation
import XCTest
@testable import ShishiCore
@testable import Shishi

final class ProjectRouteTests: XCTestCase {
    func testNormalReorderPreservesTodayAndTodayReorderMixesTasksProjects() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let today = Calendar.current.startOfDay(for: Date())
            let a = Todo(title: "A", schedule: .dated, startDate: today, order: 0, source: SourceInfo(provider: "Things3", identifier: "a", metadata: ["todayIndex": "10"]))
            let b = Todo(title: "B", schedule: .dated, startDate: today, order: 1, source: SourceInfo(provider: "Things3", identifier: "b", metadata: ["todayIndex": "30"]))
            let untouched = Todo(title: "未参与", schedule: .dated, startDate: today, order: 2, source: SourceInfo(provider: "Things3", identifier: "untouched", metadata: ["todayIndex": "50"]))
            let project = Project(title: "项目", order: 20, startDate: today, schedule: .dated)
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(todos: [a, b, untouched], projects: [project]))
            let store = TaskStore(fileURL: url)
            store.reorder([b.id, a.id])
            XCTAssertEqual(store.todo(a.id)?.source?.metadata["todayIndex"], "10")
            XCTAssertEqual(store.todo(b.id)?.source?.metadata["todayIndex"], "30")
            XCTAssertEqual(store.todo(untouched.id)?.source, untouched.source)
            let beforeToday = store.snapshot
            store.reorderToday([b.id, project.id, a.id])
            let mixed = store.items(for: .today).map { ($0.id, Double($0.source?.metadata["todayIndex"] ?? "") ?? $0.order) } + store.projectItems(for: .today).map { ($0.id, Double($0.source?.metadata["todayIndex"] ?? "") ?? $0.order) }
            XCTAssertEqual(mixed.sorted { $0.1 < $1.1 }.map(\.0), [b.id, project.id, a.id, untouched.id])
            XCTAssertEqual(store.todo(untouched.id)?.source, untouched.source)
            XCTAssertEqual(store.todos.map(\.order), beforeToday.todos.map(\.order))
            XCTAssertEqual(store.projects[0].order, beforeToday.projects[0].order)
            let valid = store.snapshot
            store.reorderToday([a.id, a.id]); XCTAssertTrue(store.snapshot == valid)
            store.reorderToday([UUID()]); XCTAssertTrue(store.snapshot == valid)
            store.undo(); XCTAssertTrue(store.snapshot == beforeToday)
            store.redo(); XCTAssertTrue(store.snapshot == valid)
        }
    }
    func testIndividualRestoreFromTrashedProjectDoesNotRestoreOtherChildren() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let area = Area(title: "区域")
            let project = Project(title: "废纸篓容器", areaID: area.id, deletedAt: Date())
            let first = Todo(title: "单独恢复", schedule: .anytime, projectID: project.id, areaID: area.id)
            let second = Todo(title: "单独永久删除", projectID: project.id, areaID: area.id)
            let storeURL = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: storeURL).write(Snapshot(todos: [first, second], projects: [project], areas: [area]))
            let store = TaskStore(fileURL: storeURL)
            store.restore(first.id)
            XCTAssertNil(store.todo(first.id)?.projectID)
            XCTAssertEqual(store.todo(first.id)?.areaID, area.id)
            XCTAssertNotNil(store.projects[0].deletedAt)
            XCTAssertEqual(store.items(for: .trash).map(\.id), [second.id])
            store.permanentlyDelete(second.id)
            XCTAssertNil(store.todo(second.id))
            store.undo()
            XCTAssertNotNil(store.todo(second.id))
            try Domain.validate(store.snapshot)
        }
    }
    func testPermanentProjectDeleteRequiresTrashAndUndoRestoresWholeGraph() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.json")
            let heading = Heading(title: "分组")
            let project = Project(title: "删除目标", headings: [heading])
            let unrelatedProject = Project(title: "其他项目")
            let children = [Todo(title: "开放", projectID: project.id, headingID: heading.id), Todo(title: "完成", status: .completed, projectID: project.id, completedAt: Date()), Todo(title: "已删", projectID: project.id, deletedAt: Date())]
            let unrelated = Todo(title: "其他数据", projectID: unrelatedProject.id)
            let value = Snapshot(todos: children + [unrelated], projects: [project, unrelatedProject], tags: ["保留标签"])
            try SnapshotFile(url: url).write(value)
            let store = TaskStore(fileURL: url)
            store.permanentlyDeleteProject(project.id)
            XCTAssertTrue(store.snapshot == value)
            XCTAssertFalse(store.canUndo)
            store.trashProject(project.id)
            let beforeDeletion = store.snapshot
            store.permanentlyDeleteProject(project.id)
            XCTAssertEqual(store.projects.map(\.id), [unrelatedProject.id])
            XCTAssertEqual(store.todos.map(\.id), [unrelated.id])
            XCTAssertEqual(store.snapshot.tags, ["保留标签"])
            try Domain.validate(store.snapshot)
            store.undo()
            XCTAssertTrue(store.snapshot == beforeDeletion)
            XCTAssertTrue(try SnapshotFile(url: url).load() == beforeDeletion)
            store.redo()
            XCTAssertEqual(store.todos.map(\.id), [unrelated.id])
        }
    }
    func testProjectRoutesPreserveIndependentStartDeadlineAndStatus() {
        let today = Calendar.current.startOfDay(for: Date())
        let future = Calendar.current.date(byAdding: .day, value: 3, to: today)!
        let area = Area(title: "工作", tags: ["继承"])
        let started = Project(title: "已开始", areaID: area.id, startDate: today, schedule: .dated)
        let deadline = Project(title: "仅截止", areaID: area.id, deadline: today, tags: ["项目标签"])
        let planned = Project(title: "计划", startDate: future, schedule: .dated)
        let someday = Project(title: "某天", schedule: .someday)
        let canceled = Project(title: "取消", status: .canceled)
        let completed = Project(title: "完成", completed: true)
        let deleted = Project(title: "废纸篓", deletedAt: today)
        let value = Snapshot(projects: [started, deadline, planned, someday, canceled, completed, deleted], areas: [area])
        XCTAssertEqual(Set(Domain.projects(in: value, for: .today).map(\.id)), Set([started.id, deadline.id]))
        XCTAssertEqual(Domain.projects(in: value, for: .upcoming).map(\.id), [planned.id])
        XCTAssertEqual(Set(Domain.projects(in: value, for: .anytime).map(\.id)), Set([started.id, deadline.id]))
        XCTAssertEqual(Domain.projects(in: value, for: .someday).map(\.id), [someday.id])
        XCTAssertEqual(Set(Domain.projects(in: value, for: .area(area.id)).map(\.id)), Set([started.id, deadline.id]))
        XCTAssertEqual(Set(Domain.projects(in: value, for: .logbook).map(\.id)), Set([canceled.id, completed.id]))
        XCTAssertEqual(Domain.projects(in: value, for: .trash).map(\.id), [deleted.id])
        XCTAssertEqual(Domain.projects(in: value, for: .search("已开始")).map(\.id), [started.id])
        XCTAssertEqual(Set(Domain.projects(in: value, for: .tag("继承")).map(\.id)), Set([started.id, deadline.id]))
    }
    func testSuppressedDeadlineDoesNotTriggerTodayButStartStillDoes() {
        let today = Calendar.current.startOfDay(for: Date())
        let earlier = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let suppressed = Todo(title: "已推迟", schedule: .someday, deadline: today, deadlineSuppressionDate: today)
        let started = Todo(title: "已开始", schedule: .dated, startDate: today, deadline: today, deadlineSuppressionDate: today)
        let insufficient = Todo(title: "未覆盖截止", schedule: .anytime, deadline: today, deadlineSuppressionDate: earlier)
        let value = Snapshot(todos: [suppressed, started, insufficient])
        XCTAssertEqual(Set(Domain.items(in: value, for: .today).map(\.id)), Set([started.id, insufficient.id]))
        XCTAssertEqual(Domain.items(in: value, for: .someday).map(\.id), [suppressed.id])
    }
    func testTodayUsesDedicatedImportedIndexAndNormalRoutesUseOrder() {
        let today = Calendar.current.startOfDay(for: Date())
        let a = Todo(title: "A", schedule: .dated, startDate: today, order: 0, source: SourceInfo(provider: "Things3", identifier: "a", metadata: ["todayIndex": "530"]))
        let b = Todo(title: "B", schedule: .dated, startDate: today, order: 1, source: SourceInfo(provider: "Things3", identifier: "b", metadata: ["todayIndex": "-747"]))
        let value = Snapshot(todos: [a, b])
        XCTAssertEqual(Domain.items(in: value, for: .today).map(\.id), [b.id, a.id])
        XCTAssertEqual(Domain.items(in: value, for: .anytime).map(\.id), [a.id, b.id])
    }
    func testUncompleteProjectUpdatesStatusAndGlobalUnusedTagsPersist() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.json")
            let area = Area(title: "区域", tags: ["区域标签"])
            var project = Project(title: "已完成项目", areaID: area.id, completed: true, status: .completed, tags: ["项目标签"])
            let todo = Todo(title: "子任务", schedule: .anytime, projectID: project.id, areaID: area.id)
            try SnapshotFile(url: url).write(Snapshot(todos: [todo], projects: [project], areas: [area], tags: ["未使用标签"]))
            let store = TaskStore(fileURL: url)
            XCTAssertTrue(store.items(for: .anytime).isEmpty)
            project.completed = false
            XCTAssertTrue(store.saveProject(project))
            XCTAssertEqual(store.projects[0].status, .open)
            XCTAssertEqual(store.items(for: .anytime).map(\.id), [todo.id])
            XCTAssertEqual(Set(store.allTags), Set(["未使用标签", "项目标签", "区域标签"]))
            XCTAssertEqual(store.items(for: .tag("区域标签")).map(\.id), [todo.id])
            XCTAssertEqual(store.items(for: .tag("项目标签")).map(\.id), [todo.id])
            XCTAssertEqual(TaskStore(fileURL: url).snapshot.tags, ["未使用标签"])
        }
    }
}
