import XCTest
import ShishiCore
@testable import Shishi

final class ProjectOperationsTests: XCTestCase {
    func testUnscheduledSuccessorTasksWaitForProjectCycleWithoutChangingSomedayOrHistory() throws {
        let now = date(2024, 1, 1)
        var project = Project(title: "重复项目", startDate: date(2024, 1, 10), schedule: .dated,
                              repeatRule: RepeatRule(unit: .week))
        let anytime = Todo(title: "随时任务", schedule: .anytime, projectID: project.id)
        let inbox = Todo(title: "未整理任务", projectID: project.id)
        let someday = Todo(title: "将来任务", schedule: .someday, projectID: project.id)
        let dated = Todo(title: "独立日期", schedule: .dated, startDate: date(2024, 1, 12), projectID: project.id)
        let deadlineOnly = Todo(title: "独立截止", schedule: .anytime, deadline: date(2024, 1, 13), projectID: project.id)
        let original = [anytime, inbox, someday, dated, deadlineOnly]
        var snapshot = Snapshot(todos: original, projects: [project])
        XCTAssertTrue(Domain.items(in: snapshot, for: .anytime, now: now, calendar: calendar).contains { $0.id == anytime.id })
        project.completed = true
        try ProjectOperations.save(project, in: &snapshot, now: now, calendar: calendar)
        let next = snapshot.projects[1]
        let tasks = snapshot.todos.filter { $0.projectID == next.id }
        for title in ["随时任务", "未整理任务"] {
            let task = try XCTUnwrap(tasks.first { $0.title == title })
            XCTAssertEqual(task.startDate, date(2024, 1, 17))
            XCTAssertEqual(task.schedule, .dated)
            XCTAssertFalse(Domain.items(in: snapshot, for: .anytime, now: now, calendar: calendar).contains { $0.id == task.id })
            XCTAssertTrue(Domain.items(in: snapshot, for: .upcoming, now: now, calendar: calendar).contains { $0.id == task.id })
            XCTAssertTrue(Domain.items(in: snapshot, for: .anytime, now: date(2024, 1, 17), calendar: calendar).contains { $0.id == task.id })
        }
        let nextSomeday = try XCTUnwrap(tasks.first { $0.title == "将来任务" })
        XCTAssertEqual(nextSomeday.schedule, .someday)
        XCTAssertNil(nextSomeday.startDate)
        XCTAssertEqual(tasks.first { $0.title == "独立日期" }?.startDate, date(2024, 1, 19))
        XCTAssertEqual(tasks.first { $0.title == "独立截止" }?.deadline, date(2024, 1, 20))
        XCTAssertEqual(Array(snapshot.todos.prefix(original.count)), original)
        var manual = Snapshot(todos: original, projects: [Project(id: project.id, title: "原项目")])
        let copyID = try XCTUnwrap(ProjectOperations.duplicate(project.id, in: &manual))
        let manualAnytime = try XCTUnwrap(manual.todos.first { $0.projectID == copyID && $0.title == "随时任务" })
        XCTAssertNil(manualAnytime.startDate)
        XCTAssertEqual(manualAnytime.schedule, .anytime)
    }

    func testSuccessorWithDeadlineOrChildDatesIsScheduledUntilItsCycle() throws {
        let now = date(2024, 1, 1)
        for projectDeadline in [true, false] {
            var project = Project(title: "项目", deadline: projectDeadline ? date(2024, 1, 10) : nil,
                                  schedule: .anytime, repeatRule: RepeatRule(unit: .week))
            let task = Todo(title: "原开放任务", schedule: .dated, startDate: date(2024, 1, 12),
                            deadline: date(2024, 1, 14), projectID: project.id,
                            checklist: [ChecklistItem(title: "未完成")])
            var snapshot = Snapshot(todos: [task], projects: [project]); project.completed = true
            try ProjectOperations.save(project, in: &snapshot, now: now, calendar: calendar)
            let next = snapshot.projects[1]
            let expected = projectDeadline ? date(2024, 1, 17) : date(2024, 1, 19)
            XCTAssertEqual(next.startDate, expected)
            XCTAssertEqual(next.schedule, .dated)
            XCTAssertFalse(Domain.projects(in: snapshot, for: .anytime, now: now, calendar: calendar).contains { $0.id == next.id })
            XCTAssertFalse(Domain.projects(in: snapshot, for: .today, now: now, calendar: calendar).contains { $0.id == next.id })
            XCTAssertTrue(Domain.projects(in: snapshot, for: .upcoming, now: now, calendar: calendar).contains { $0.id == next.id })
            XCTAssertTrue(Domain.projects(in: snapshot, for: .anytime, now: expected, calendar: calendar).contains { $0.id == next.id })
            XCTAssertEqual(snapshot.todos[0], task)
            XCTAssertEqual(snapshot.todos[0].status, .open)
            XCTAssertEqual(snapshot.todos[1].startDate, date(2024, 1, 19))
            XCTAssertEqual(snapshot.todos[1].deadline, date(2024, 1, 21))
            XCTAssertNil(snapshot.projects[0].startDate)
            XCTAssertTrue(snapshot.projects[0].completed)
        }
    }

    func testHiddenRepeatTemplatesAreExcludedFromBothClones() throws {
        var project = Project(title: "项目", repeatRule: RepeatRule(unit: .day))
        let visible = Todo(title: "真实任务", status: .canceled, projectID: project.id)
        let hidden = Todo(title: "内部模板", schedule: .dated, startDate: date(2020, 1, 1), projectID: project.id,
                          checklist: [ChecklistItem(title: "模板清单")],
                          source: SourceInfo(provider: "Things", identifier: "template", metadata: ["repeatTemplate": "true"]))
        let before = Snapshot(todos: [visible, hidden], projects: [project])
        var manual = before
        let copiedID = try XCTUnwrap(ProjectOperations.duplicate(project.id, in: &manual))
        XCTAssertEqual(manual.todos.filter { $0.projectID == copiedID }.map(\.title), ["真实任务"])
        XCTAssertEqual(Array(manual.todos.prefix(2)), before.todos)
        var repeating = before; project.completed = true
        try ProjectOperations.save(project, in: &repeating, now: date(2024, 1, 1), calendar: calendar)
        XCTAssertEqual(repeating.todos.filter { $0.projectID == repeating.projects[1].id }.map(\.title), ["真实任务"])
        XCTAssertEqual(Array(repeating.todos.prefix(2)), before.todos)
        XCTAssertEqual(repeating.projects[1].startDate, date(2024, 1, 2))
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testInvalidInputRuleCannotBeSilentlyDiscarded() throws {
        let project = Project(title: "项目")
        let before = Snapshot(projects: [project])
        var snapshot = before, invalid = project
        invalid.completed = true; invalid.repeatRule = RepeatRule(unit: .day, interval: 0)
        XCTAssertThrowsError(try ProjectOperations.save(invalid, in: &snapshot))
        XCTAssertEqual(snapshot, before)
    }

    func testUndatedRepeatSchedulesNextInstance() throws {
        var project = Project(title: "项目", repeatRule: RepeatRule(unit: .week, interval: 2, afterCompletion: true))
        var snapshot = Snapshot(projects: [project])
        project.completed = true
        try ProjectOperations.save(project, in: &snapshot, now: date(2024, 12, 25), calendar: calendar)
        XCTAssertEqual(snapshot.projects[1].startDate, date(2025, 1, 8))
        XCTAssertEqual(snapshot.projects[1].schedule, .dated)
    }

    func testUnitsIntervalsCompletionAnchorAndLeapBoundary() throws {
        let cases: [(RepeatUnit, Int, Bool, Date, Date, Date)] = [
            (.day, 2, false, date(2024, 12, 31), date(2025, 1, 10), date(2025, 1, 2)),
            (.week, 2, false, date(2024, 12, 25), date(2025, 1, 10), date(2025, 1, 8)),
            (.month, 1, true, date(2024, 1, 1), date(2024, 1, 31), date(2024, 2, 29)),
            (.year, 1, false, date(2024, 2, 29), date(2024, 3, 1), date(2025, 2, 28)),
            (.day, 3, true, date(2024, 1, 1), date(2024, 2, 1), date(2024, 2, 4)),
            (.year, 2, true, date(2023, 1, 1), date(2024, 2, 29), date(2026, 2, 28))
        ]
        for (unit, interval, after, start, now, expected) in cases {
            var project = Project(title: "周期", deadline: calendar.date(byAdding: .day, value: 4, to: start),
                                  startDate: start, schedule: .dated, repeatRule: RepeatRule(unit: unit, interval: interval, afterCompletion: after))
            var snapshot = Snapshot(projects: [project]); project.completed = true
            try ProjectOperations.save(project, in: &snapshot, now: now, calendar: calendar)
            XCTAssertEqual(snapshot.projects[1].startDate, expected, "\(unit)")
            XCTAssertEqual(snapshot.projects[1].deadline, calendar.date(byAdding: .day, value: 4, to: expected))
        }
    }

    func testDeletedChildrenAreExcludedAndAllCloneIDsAreDisjoint() throws {
        let source = SourceInfo(provider: "Things", identifier: "external", metadata: ["todayIndex": "1"])
        let live = Heading(title: "保留", source: source), deleted = Heading(title: "删除", deletedAt: date(2024, 1, 1))
        let project = Project(title: "项目", headings: [live, deleted], source: source, repeatRule: RepeatRule(unit: .day), evening: true)
        let task = Todo(title: "任务", status: .canceled, projectID: project.id, headingID: live.id,
                        checklist: [ChecklistItem(title: "检查", source: source)], source: source)
        let hidden = Todo(title: "分组删除", projectID: project.id, headingID: deleted.id)
        let trashed = Todo(title: "任务删除", projectID: project.id, deletedAt: date(2024, 1, 1))
        let before = Snapshot(todos: [task, hidden, trashed], projects: [project])
        var snapshot = before
        let id = try XCTUnwrap(ProjectOperations.duplicate(project.id, in: &snapshot))
        let copy = snapshot.projects[1], child = snapshot.todos[3]
        XCTAssertEqual(snapshot.todos.count, 4)
        XCTAssertEqual(copy.id, id)
        XCTAssertEqual(copy.headings.count, 1)
        XCTAssertEqual(copy.evening, true)
        XCTAssertNil(copy.repeatRule)
        XCTAssertNil(copy.headings[0].source)
        XCTAssertNil(child.source)
        XCTAssertNil(child.checklist[0].source)
        let oldIDs = Set([project.id, live.id, deleted.id, task.id, hidden.id, trashed.id, task.checklist[0].id])
        let newIDs = [copy.id, copy.headings[0].id, child.id, child.checklist[0].id]
        XCTAssertTrue(oldIDs.isDisjoint(with: newIDs))
        XCTAssertEqual(Set(newIDs).count, newIDs.count)
        XCTAssertEqual(Array(snapshot.todos.prefix(3)), before.todos)
        XCTAssertEqual(snapshot.projects[0], project)
        var completed = project; completed.completed = true
        var repeated = before
        try ProjectOperations.save(completed, in: &repeated, now: date(2024, 2, 1), calendar: calendar)
        XCTAssertEqual(repeated.todos.count, 4)
        XCTAssertTrue(oldIDs.isDisjoint(with: [repeated.projects[1].id, repeated.projects[1].headings[0].id, repeated.todos[3].id, repeated.todos[3].checklist[0].id]))
        XCTAssertEqual(repeated.todos[3].headingID, repeated.projects[1].headings[0].id)
        XCTAssertEqual(repeated.todos[3].status, .open)
        XCTAssertNil(repeated.todos[3].deletedAt)
        XCTAssertNil(repeated.todos[3].source)
    }

    func testInvalidSnapshotsAndDatesFailWithoutMutation() throws {
        let project = Project(title: "项目", repeatRule: RepeatRule(unit: .day))
        let badValues = [Snapshot(version: 2, projects: [project]),
                         Snapshot(todos: [Todo(title: "错误引用", projectID: UUID())], projects: [project]),
                         Snapshot(todos: [Todo(title: "错误分组", projectID: project.id, headingID: UUID())], projects: [project]),
                         Snapshot(projects: [Project(title: "错误区域", areaID: UUID())]),
                         Snapshot(projects: [Project(title: "错误规则", repeatRule: RepeatRule(unit: .day, interval: 10001))])]
        for before in badValues {
            var snapshot = before
            XCTAssertThrowsError(try ProjectOperations.duplicate(project.id, in: &snapshot))
            XCTAssertEqual(snapshot, before)
            XCTAssertThrowsError(try ProjectOperations.save(project, in: &snapshot))
            XCTAssertEqual(snapshot, before)
        }
        var snapshot = Snapshot(projects: [project]), completed = project
        let before = snapshot; completed.completed = true
        XCTAssertThrowsError(try ProjectOperations.save(completed, in: &snapshot, now: Date(timeIntervalSinceReferenceDate: .infinity)))
        XCTAssertEqual(snapshot, before)
        var invalid = project; invalid.areaID = UUID()
        XCTAssertThrowsError(try ProjectOperations.save(invalid, in: &snapshot))
        XCTAssertEqual(snapshot, before)
    }

    func testOldJSONAndSourceMetadataDoNotActivateProjectRepeats() throws {
        let data = Data("{\"version\":1,\"todos\":[],\"areas\":[],\"projects\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"title\":\"旧项目\",\"notes\":\"\",\"completed\":false,\"headings\":[],\"order\":0,\"source\":{\"provider\":\"Things\",\"identifier\":\"p\",\"metadata\":{\"repeatTemplate\":\"true\",\"repeatRule\":\"complex\"}}}]}".utf8)
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertNil(snapshot.projects[0].repeatRule)
        XCTAssertNil(snapshot.projects[0].evening)
        var project = snapshot.projects[0]; project.completed = true
        try ProjectOperations.save(project, in: &snapshot)
        XCTAssertEqual(snapshot.projects.count, 1)
        XCTAssertEqual(snapshot.projects[0].source, project.source)
    }

    func testCalendarDayAcrossDSTRetainsLocalTimeAndTodayOrder() throws {
        var local = Calendar(identifier: .gregorian); local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = local.date(from: DateComponents(year: 2024, month: 3, day: 9, hour: 12))!
        let childStart = local.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 12))!
        var project = Project(title: "项目", order: 9, startDate: start, schedule: .dated,
                              source: SourceInfo(provider: "Things", identifier: "p", metadata: ["todayIndex": "1"]),
                              repeatRule: RepeatRule(unit: .day), evening: true)
        let independent = Project(title: "其他", order: 2, startDate: start, schedule: .dated)
        let task = Todo(title: "任务", schedule: .dated, startDate: childStart, projectID: project.id)
        var snapshot = Snapshot(todos: [task], projects: [project, independent])
        XCTAssertEqual(Domain.projects(in: snapshot, for: .today, now: childStart, calendar: local).map(\.id), [project.id, independent.id])
        project.completed = true
        try ProjectOperations.save(project, in: &snapshot, now: childStart, calendar: local)
        XCTAssertEqual(local.component(.hour, from: snapshot.projects[2].startDate!), 12)
        XCTAssertEqual(local.component(.day, from: snapshot.projects[2].startDate!), 10)
        XCTAssertEqual(local.component(.hour, from: snapshot.todos[1].startDate!), 12)
        XCTAssertEqual(local.component(.day, from: snapshot.todos[1].startDate!), 11)
        XCTAssertEqual(snapshot.projects[2].evening, true)
        XCTAssertNil(snapshot.projects[2].source)
        XCTAssertEqual(snapshot.projects[1], independent)
    }

    func testCanceledDeletedAndNewCompletedProjectsDoNotGenerate() throws {
        let original = Project(title: "项目", repeatRule: RepeatRule(unit: .day))
        var snapshot = Snapshot(projects: [original]), canceled = original
        canceled.completed = true; canceled.status = .canceled
        try ProjectOperations.save(canceled, in: &snapshot)
        XCTAssertEqual(snapshot.projects.count, 1)
        var deleted = original; deleted.deletedAt = date(2024, 1, 1)
        snapshot = Snapshot(projects: [deleted]); deleted.completed = true
        try ProjectOperations.save(deleted, in: &snapshot)
        XCTAssertEqual(snapshot.projects.count, 1)
        XCTAssertNil(try ProjectOperations.duplicate(deleted.id, in: &snapshot))
        XCTAssertNil(try ProjectOperations.duplicate(UUID(), in: &snapshot))
        snapshot = Snapshot(); var completed = original; completed.completed = true
        try ProjectOperations.save(completed, in: &snapshot)
        XCTAssertEqual(snapshot.projects.count, 1)
    }

    func testFailedUndoKeepsCompleteTreeAndUndoStack() async throws {
        try await MainActor.run {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("db.json")
            let project = Project(title: "项目", repeatRule: RepeatRule(unit: .day))
            let before = Snapshot(projects: [project])
            try SnapshotFile(url: url).write(before)
            let store = TaskStore(fileURL: url)
            XCTAssertTrue(store.setProjectCompleted(project.id, completed: true))
            let after = store.snapshot
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            store.undo()
            XCTAssertEqual(store.snapshot, after)
            XCTAssertTrue(store.canUndo)
            XCTAssertFalse(store.canRedo)
            try FileManager.default.removeItem(at: url)
            try SnapshotFile(url: url).write(after)
            store.undo()
            XCTAssertEqual(store.snapshot, before)
            XCTAssertEqual(try SnapshotFile(url: url).load(), before)
        }
    }

    func testStoreCompletionUndoRedoAndDiskFailureAreAtomic() async throws {
        try await MainActor.run {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("db.json")
            let project = Project(title: "项目", startDate: date(2024, 1, 1), schedule: .dated, repeatRule: RepeatRule(unit: .day))
            let task = Todo(title: "任务", status: .completed, projectID: project.id, checklist: [ChecklistItem(title: "检查", completed: true)])
            let before = Snapshot(todos: [task], projects: [project])
            try SnapshotFile(url: url).write(before)
            let store = TaskStore(fileURL: url)
            var completed = project; completed.completed = true
            XCTAssertTrue(store.saveProject(completed))
            let after = store.snapshot
            XCTAssertEqual(after.projects.count, 2)
            XCTAssertEqual(after.todos[0], task)
            XCTAssertEqual(try SnapshotFile(url: url).load(), after)
            XCTAssertTrue(store.setProjectCompleted(project.id, completed: true))
            XCTAssertEqual(store.snapshot, after)
            store.undo(); XCTAssertEqual(store.snapshot, before); XCTAssertFalse(store.canUndo)
            store.redo(); XCTAssertEqual(store.snapshot, after)
            store.undo(); XCTAssertEqual(store.snapshot, before)
            // 仅在临时测试目录将文件目标换成目录，强制原子写失败。
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertNil(store.duplicateProject(project.id))
            XCTAssertFalse(store.saveProject(completed))
            XCTAssertEqual(store.snapshot, before)
            XCTAssertFalse(store.canUndo)
            XCTAssertTrue(store.canRedo)
            XCTAssertNotNil(store.errorMessage)
            try FileManager.default.removeItem(at: url)
            try SnapshotFile(url: url).write(before)
            store.redo(); XCTAssertEqual(store.snapshot, after)
            store.undo(); XCTAssertEqual(store.snapshot, before)
            XCTAssertTrue(store.setProjectCompleted(project.id, completed: true))
            XCTAssertEqual(store.snapshot.projects.count, 2)
        }
    }

    func testMonthlyCompletionPreservesOffsetsAndHistory() throws {
        let heading = Heading(title: "分组", status: .completed)
        var project = Project(title: "月度", headings: [heading], startDate: date(2024, 1, 31), schedule: .dated)
        project.repeatRule = RepeatRule(unit: .month)
        let task = Todo(title: "任务", status: .completed, schedule: .dated, startDate: date(2024, 2, 1),
                        deadline: date(2024, 2, 3), projectID: project.id, headingID: heading.id,
                        checklist: [ChecklistItem(title: "步骤", completed: true)], completedAt: date(2024, 2, 4))
        var snapshot = Snapshot(todos: [task], projects: [project])
        project.completed = true
        XCTAssertTrue(try ProjectOperations.save(project, in: &snapshot, now: date(2024, 2, 5), calendar: calendar))
        XCTAssertEqual(snapshot.projects.count, 2)
        let next = snapshot.projects[1], child = snapshot.todos[1]
        XCTAssertEqual(next.startDate, date(2024, 2, 29))
        XCTAssertEqual(child.startDate, date(2024, 3, 1))
        XCTAssertEqual(child.deadline, date(2024, 3, 3))
        XCTAssertEqual(child.status, .open)
        XCTAssertFalse(child.checklist[0].completed)
        XCTAssertNil(child.completedAt)
        XCTAssertEqual(snapshot.todos[0], task)
        XCTAssertTrue(snapshot.projects[0].completed)
        XCTAssertNil(snapshot.projects[0].repeatRule)
        XCTAssertEqual(next.repeatRule, RepeatRule(unit: .month))
        XCTAssertTrue(try ProjectOperations.save(project, in: &snapshot, now: date(2024, 2, 5), calendar: calendar))
        XCTAssertNil(snapshot.projects[0].repeatRule)
        XCTAssertEqual(snapshot.projects.count, 2)
        project.completed = false
        XCTAssertTrue(try ProjectOperations.save(project, in: &snapshot, calendar: calendar))
        project.completed = true
        XCTAssertTrue(try ProjectOperations.save(project, in: &snapshot, calendar: calendar))
        XCTAssertEqual(snapshot.projects.count, 2)
    }

    func testDuplicateIsDeepAndUndoIsOneTransaction() async throws {
        try await MainActor.run {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("db.json")
            let heading = Heading(title: "分组", source: SourceInfo(provider: "Things", identifier: "h"))
            let project = Project(title: "项目", completed: true, headings: [heading], source: SourceInfo(provider: "Things", identifier: "p"))
            let task = Todo(title: "任务", notes: "备注", status: .completed, schedule: .dated,
                            startDate: Date(timeIntervalSince1970: 1000), deadline: Date(timeIntervalSince1970: 2000),
                            projectID: project.id, headingID: heading.id, tags: ["标签"],
                            checklist: [ChecklistItem(title: "检查", completed: true)], repeatRule: RepeatRule(unit: .day), completedAt: Date())
            let before = Snapshot(todos: [task], projects: [project])
            try SnapshotFile(url: url).write(before)
            let store = TaskStore(fileURL: url)
            let id = try XCTUnwrap(store.duplicateProject(project.id))
            let copy = try XCTUnwrap(store.snapshot.projects.first { $0.id == id })
            let child = try XCTUnwrap(store.todos.first { $0.projectID == id })
            XCTAssertEqual(copy.title, "项目副本")
            XCTAssertFalse(copy.completed)
            XCTAssertNil(copy.source)
            XCTAssertNotEqual(copy.headings[0].id, heading.id)
            XCTAssertEqual(child.headingID, copy.headings[0].id)
            XCTAssertNotEqual(child.id, task.id)
            XCTAssertNotEqual(child.checklist[0].id, task.checklist[0].id)
            XCTAssertTrue(child.checklist[0].completed)
            XCTAssertEqual(child.status, .completed)
            XCTAssertEqual(child.startDate, task.startDate)
            XCTAssertEqual(child.deadline, task.deadline)
            XCTAssertEqual(child.notes, task.notes)
            XCTAssertEqual(child.tags, task.tags)
            XCTAssertNil(child.repeatRule)
            XCTAssertEqual(store.todo(task.id), task)
            XCTAssertEqual(store.snapshot.projects.first, project)
            store.undo()
            XCTAssertEqual(store.snapshot, before)
            XCTAssertFalse(store.canUndo)
            XCTAssertEqual(try SnapshotFile(url: url).load(), before)
        }
    }
}
