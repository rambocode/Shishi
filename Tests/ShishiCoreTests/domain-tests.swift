import XCTest
@testable import ShishiCore

final class DomainTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }
    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
    func testFiltersSeparateDeadlineAndStart() {
        let now = date(2026, 3, 8)
        let overdue = Todo(title: "截止已过", schedule: .anytime, deadline: date(2026, 3, 7))
        let future = Todo(title: "未来开始", schedule: .dated, startDate: date(2026, 3, 9))
        let current = Todo(title: "今天", schedule: .dated, startDate: now)
        let completed = Todo(title: "完成", status: .completed, completedAt: now)
        let deleted = Todo(title: "回收", deletedAt: now)
        let value = Snapshot(todos: [overdue, future, current, completed, deleted])
        XCTAssertEqual(Set(Domain.items(in: value, for: .today, now: now, calendar: calendar).map(\.id)), Set([overdue.id, current.id]))
        XCTAssertEqual(Domain.items(in: value, for: .upcoming, now: now, calendar: calendar).map(\.id), [future.id])
        XCTAssertEqual(Domain.items(in: value, for: .logbook).map(\.id), [completed.id])
        XCTAssertEqual(Domain.items(in: value, for: .trash).map(\.id), [deleted.id])
        XCTAssertEqual(Domain.items(in: value, for: .search("截止")).map(\.id), [overdue.id])
    }
    func testAreaIncludesProjectAndTagsNormalize() throws {
        let area = Area(title: "生活")
        let project = Project(title: "计划", areaID: area.id)
        let task = Domain.normalized(Todo(title: " 标题 \n", schedule: .anytime, projectID: project.id, tags: [" A ", "A", " "]))
        let value = Snapshot(todos: [task], projects: [project], areas: [area])
        try Domain.validate(value)
        XCTAssertEqual(task.title, "标题")
        XCTAssertEqual(task.tags, ["A"])
        XCTAssertEqual(Domain.items(in: value, for: .area(area.id)).count, 1)
        XCTAssertEqual(Domain.items(in: value, for: .tag("A")).count, 1)
    }
    func testRepeatMonthBoundaryAndIdempotency() {
        let start = date(2024, 1, 31)
        let task = Todo(title: "月末", schedule: .dated, startDate: start, deadline: date(2024, 2, 2), checklist: [ChecklistItem(title: "一项", completed: true)], repeatRule: RepeatRule(unit: .month))
        var value = Snapshot(todos: [task])
        Domain.complete(task.id, in: &value, now: date(2024, 2, 10), calendar: calendar)
        XCTAssertEqual(value.todos.count, 2)
        let next = value.todos[1]
        XCTAssertEqual(calendar.component(.day, from: next.startDate!), 29)
        XCTAssertEqual(calendar.component(.day, from: next.deadline!), 2)
        XCTAssertEqual(calendar.component(.month, from: next.deadline!), 3)
        XCTAssertFalse(next.checklist[0].completed)
        XCTAssertNotEqual(next.checklist[0].id, task.checklist[0].id)
        Domain.complete(task.id, in: &value, calendar: calendar)
        XCTAssertEqual(value.todos.count, 2)
        value.todos[0].status = .open
        Domain.complete(task.id, in: &value, now: date(2024, 3, 10), calendar: calendar)
        XCTAssertEqual(value.todos.count, 2)
        Domain.complete(next.id, in: &value, now: date(2024, 3, 10), calendar: calendar)
        XCTAssertEqual(value.todos.count, 3)
        value.todos.removeAll { $0.id != task.id }
        value.todos[0].status = .open
        Domain.complete(task.id, in: &value, now: date(2024, 4, 10), calendar: calendar)
        XCTAssertEqual(value.todos.count, 1, "永久删除后继后不能由旧实例重复生成")
    }
    func testCompletionIntervalAcrossDaylightSaving() {
        let task = Todo(title: "每日", schedule: .dated, startDate: date(2026, 3, 1), repeatRule: RepeatRule(unit: .day, afterCompletion: true))
        var value = Snapshot(todos: [task])
        Domain.complete(task.id, in: &value, now: date(2026, 3, 7), calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: value.todos[1].startDate!), 12)
        XCTAssertEqual(calendar.component(.day, from: value.todos[1].startDate!), 8)
    }
    func testValidationRejectsVersionsIDsReferencesAndInvalidRules() {
        XCTAssertThrowsError(try Domain.validate(Snapshot(version: 2)))
        let task = Todo(title: "任务")
        XCTAssertThrowsError(try Domain.validate(Snapshot(todos: [task, task])))
        XCTAssertThrowsError(try Domain.validate(Snapshot(todos: [Todo(title: "任务", projectID: UUID())])))
        XCTAssertThrowsError(try Domain.validate(Snapshot(todos: [Todo(title: "任务", headingID: UUID())])))
        XCTAssertThrowsError(try Domain.validate(Snapshot(todos: [Todo(title: "任务", repeatRule: RepeatRule(unit: .day, interval: 0))])))
        XCTAssertThrowsError(try Domain.validate(Snapshot(todos: [Todo(title: " ")])))
        XCTAssertThrowsError(try Domain.validate(Snapshot(todos: [Todo(title: "任务", schedule: .dated)])))
        XCTAssertThrowsError(try Domain.validate(Snapshot(todos: [Todo(title: "任务", deadline: Date(timeIntervalSinceReferenceDate: .infinity))])))
    }
    func testPersistenceRoundTripAndCorruptionProtection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SnapshotFile(url: folder.appendingPathComponent("data.json"))
        let value = Snapshot(todos: [Todo(title: "离线", notes: "中文备注", deadline: date(2026, 9, 16))])
        try file.write(value)
        XCTAssertEqual(try file.load(), value)
        let backup = try XCTUnwrap(file.backup())
        XCTAssertEqual(try Data(contentsOf: backup), try Data(contentsOf: file.url))
        let broken = Data("{broken".utf8)
        try broken.write(to: file.url)
        XCTAssertThrowsError(try file.load())
        XCTAssertThrowsError(try file.write(Snapshot(version: 99)))
        XCTAssertEqual(try Data(contentsOf: file.url), broken)
    }
}
