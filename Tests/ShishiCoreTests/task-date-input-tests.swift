import Foundation
import XCTest
import ShishiCore
@testable import Shishi

final class TaskDateInputTests: XCTestCase {
    private func model() -> TaskDateInput {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 12))!
        return TaskDateInput(calendar: calendar, now: now)
    }

    func testChineseShortcutsAndWeekdays() throws {
        let input = model()
        XCTAssertEqual(input.parse(" 今天 "), .dated(input.today, evening: false))
        XCTAssertEqual(input.parse("今晚"), .dated(input.today, evening: true))
        XCTAssertEqual(input.parse("某天"), .someday)
        XCTAssertEqual(input.parse("周三"), input.parse("今天"))
        XCTAssertEqual(input.parse("明天"), input.parse("2026-09-17"))
        XCTAssertEqual(input.parse("周一"), input.parse("2026-09-21"))
        XCTAssertEqual(input.parse("周天"), input.parse("周日"))
    }

    func testStrictDatesAndYearRollover() {
        let input = model()
        XCTAssertEqual(input.parse("9月17日"), input.parse("2026-09-17"))
        XCTAssertEqual(input.parse("1月2日"), input.parse("2027-01-02"))
        XCTAssertEqual(input.parse("2月29日"), input.parse("2028-02-29"))
        for invalid in ["", "abc", "周八", "2026-02-29", "2026-09-15", "2026-13-01", "2026-09-31", "13月1日", "2月30日", "2026-9-17"] {
            XCTAssertNil(input.parse(invalid), invalid)
        }
    }

    func testFourWeeksAreSundayFirstAndAdjacentPagesAreContinuous() throws {
        let input = model()
        let first = input.page(0); let second = input.page(1)
        XCTAssertEqual(first.count, 28); XCTAssertEqual(second.count, 28)
        XCTAssertEqual(input.calendar.component(.weekday, from: try XCTUnwrap(first.first)), 1)
        XCTAssertEqual(input.calendar.component(.weekday, from: try XCTUnwrap(first.last)), 7)
        XCTAssertEqual(input.calendar.date(byAdding: .day, value: 1, to: try XCTUnwrap(first.last)), second.first)
        XCTAssertEqual(first.filter { $0 < input.today }.count, 3)
        XCTAssertTrue(input.page(-1).isEmpty)
    }

    func testReminderRejectsInvalidAndPastTimes() throws {
        let input = model()
        XCTAssertNotNil(input.reminder(dateText: "今天", timeText: "12:01"))
        XCTAssertNotNil(input.reminder(dateText: "明天", timeText: "09:00"))
        for time in ["12:00", "09:00", "24:00", "12:60", "9:0", "abc"] {
            XCTAssertNil(input.reminder(dateText: "今天", timeText: time), time)
        }
        XCTAssertNil(input.reminder(dateText: "某天", timeText: "13:00"))
        XCTAssertNil(input.reminder(dateText: "2026-02-30", timeText: "13:00"))
    }

    func testScheduleCopyPreservesOtherFieldsAndReminder() throws {
        let input = model()
        var todo = Todo(title: "测试", notes: "保留", tags: ["标签"])
        todo.reminderDate = input.reminder(dateText: "明天", timeText: "09:00")
        let evening = input.applying(.dated(input.today, evening: true), to: todo)
        XCTAssertEqual(evening.id, todo.id); XCTAssertEqual(evening.notes, todo.notes)
        XCTAssertEqual(evening.tags, todo.tags); XCTAssertEqual(evening.reminderDate, todo.reminderDate)
        XCTAssertEqual(evening.schedule, .dated); XCTAssertTrue(evening.evening)
        XCTAssertNil(todo.startDate)
        let someday = input.applying(.someday, to: evening)
        XCTAssertEqual(someday.schedule, .someday); XCTAssertNil(someday.startDate); XCTAssertFalse(someday.evening)
        XCTAssertEqual(someday.reminderDate, todo.reminderDate)
    }
}
