import XCTest
@testable import ShishiCore

final class RepeatTests: XCTestCase {
    func testAdjacentUUIDCannotSuppressNextOccurrence() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let adjacent = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let task = Todo(id: id, title: "重复", schedule: .dated, startDate: start, repeatRule: RepeatRule(unit: .week))
        let independent = Todo(id: adjacent, title: "独立任务")
        var value = Snapshot(todos: [task, independent])
        XCTAssertTrue(Domain.complete(id, in: &value, now: start))
        XCTAssertEqual(value.todos.count, 3)
        XCTAssertNotEqual(value.todos[2].id, id)
        XCTAssertNotEqual(value.todos[2].id, adjacent)
        XCTAssertEqual(value.todos[1], independent)
        XCTAssertNil(value.todos[0].repeatRule)
        XCTAssertEqual(value.todos[2].repeatRule, task.repeatRule)
        try Domain.validate(value)
    }
    func testInvalidRepeatAndDateLeaveWholeSnapshotUnchanged() {
        let task = Todo(title: "无效间隔", repeatRule: RepeatRule(unit: .month, interval: 0))
        var value = Snapshot(todos: [task])
        let original = value
        XCTAssertFalse(Domain.complete(task.id, in: &value))
        XCTAssertEqual(value, original)
        let dated = Todo(title: "无效日期", schedule: .dated, startDate: Date(timeIntervalSinceReferenceDate: .infinity), repeatRule: RepeatRule(unit: .day))
        value = Snapshot(todos: [dated])
        XCTAssertFalse(Domain.complete(dated.id, in: &value))
        XCTAssertEqual(value.todos, [dated])
        XCTAssertFalse(Domain.complete(dated.id, in: &value, now: Date(timeIntervalSinceReferenceDate: .infinity)))
        XCTAssertEqual(value.todos, [dated])
    }
    func testFixedRepeatSkipsOverdueCyclesAndKeepsDeadlineOffset() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let deadline = calendar.date(byAdding: .day, value: 3, to: start)!
        let now = calendar.date(byAdding: .day, value: 20, to: start)!
        let task = Todo(title: "按计划", schedule: .dated, startDate: start, deadline: deadline, repeatRule: RepeatRule(unit: .day, interval: 2))
        var value = Snapshot(todos: [task])
        XCTAssertTrue(Domain.complete(task.id, in: &value, now: now, calendar: calendar))
        // 逾期完成跳过已经过去的周期，下一实例必须落在今天之后，否则新实例会继续停在今天列表里。
        XCTAssertEqual(value.todos[1].startDate, calendar.date(byAdding: .day, value: 22, to: start))
        XCTAssertEqual(value.todos[1].deadline, calendar.date(byAdding: .day, value: 25, to: start))
        XCTAssertEqual(value.todos[0].deadline, deadline)
        XCTAssertTrue(Domain.complete(value.todos[1].id, in: &value, now: now, calendar: calendar))
        XCTAssertEqual(value.todos[2].startDate, calendar.date(byAdding: .day, value: 24, to: start))
    }

    /// 逾期数年的每日重复：完成一次就应排到明天，而不是继续生成过去的实例。
    func testDailyRepeatOverdueByYearsLandsAfterToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2023, month: 7, day: 28))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 10))!
        let task = Todo(title: "code review", schedule: .dated, startDate: start, repeatRule: RepeatRule(unit: .day))
        var value = Snapshot(todos: [task])
        XCTAssertTrue(Domain.complete(task.id, in: &value, now: now, calendar: calendar))
        XCTAssertEqual(value.todos[1].startDate, calendar.date(from: DateComponents(year: 2026, month: 9, day: 17)))
        XCTAssertEqual(value.todos[0].status, .completed)
        XCTAssertNil(value.todos[0].repeatRule)
    }

    /// 完成后重复以完成时刻为锚点，不受逾期追赶影响。
    func testAfterCompletionRepeatAnchorsOnCompletionMoment() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 10))!
        let task = Todo(title: "完成后重复", schedule: .dated, startDate: start, repeatRule: RepeatRule(unit: .week, interval: 2, afterCompletion: true))
        var value = Snapshot(todos: [task])
        XCTAssertTrue(Domain.complete(task.id, in: &value, now: now, calendar: calendar))
        XCTAssertEqual(value.todos[1].startDate, calendar.date(byAdding: .weekOfYear, value: 2, to: now))
    }

    /// 导入的按月规则保留“每月第几天”，追赶逾期周期时仍然对齐到那一天。
    func testImportedMonthlyRuleKeepsSourceDayWhileCatchingUp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2025, month: 1, day: 15))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 8))!
        let source = SourceInfo(provider: "Things3", identifier: "x", metadata: ["repeatDay": "15"])
        let task = Todo(title: "按月", schedule: .dated, startDate: start, repeatRule: RepeatRule(unit: .month), source: source)
        var value = Snapshot(todos: [task])
        XCTAssertTrue(Domain.complete(task.id, in: &value, now: now, calendar: calendar))
        XCTAssertEqual(value.todos[1].startDate, calendar.date(from: DateComponents(year: 2026, month: 10, day: 15)))
    }
    func testValidationAreaAuthorityAndHeadingOwnership() throws {
        let a = Area(title: "A"), b = Area(title: "B")
        let heading = Heading(title: "分组")
        let first = Project(title: "项目一", areaID: a.id, headings: [heading])
        let second = Project(title: "项目二", areaID: b.id)
        let legacy = Todo(title: "仅引用项目", projectID: first.id)
        try Domain.validate(Snapshot(todos: [legacy], projects: [first, second], areas: [a, b]))
        let conflict = Todo(title: "冲突", projectID: first.id, areaID: b.id)
        XCTAssertThrowsError(try Domain.validate(Snapshot(todos: [conflict], projects: [first, second], areas: [a, b])))
        let wrongHeading = Todo(title: "分组越界", projectID: second.id, headingID: heading.id)
        XCTAssertThrowsError(try Domain.validate(Snapshot(todos: [wrongHeading], projects: [first, second], areas: [a, b])))
        // 即使读取未经校验的数据，区域筛选也以项目为准，不同时出现在两个区域。
        let value = Snapshot(todos: [conflict], projects: [first], areas: [a, b])
        XCTAssertEqual(Domain.items(in: value, for: .area(a.id)).map(\.id), [conflict.id])
        XCTAssertTrue(Domain.items(in: value, for: .area(b.id)).isEmpty)
    }
}
