import AppKit
import XCTest
@testable import Shishi
@testable import ShishiCore

final class RepeatSettingsTests: XCTestCase {
    private func gregorian() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testSummaryTextCoversFixedAndAfterCompletionRules() {
        XCTAssertEqual(RepeatText.summary(RepeatRule(unit: .day)), "每天")
        XCTAssertEqual(RepeatText.summary(RepeatRule(unit: .week)), "每周")
        XCTAssertEqual(RepeatText.summary(RepeatRule(unit: .month)), "每月")
        XCTAssertEqual(RepeatText.summary(RepeatRule(unit: .year)), "每年")
        XCTAssertEqual(RepeatText.summary(RepeatRule(unit: .day, interval: 3)), "每 3 天")
        XCTAssertEqual(RepeatText.summary(RepeatRule(unit: .month, interval: 2)), "每 2 个月")
        XCTAssertEqual(RepeatText.summary(RepeatRule(unit: .day, afterCompletion: true)), "上一个待办事项完成后 1 天")
        XCTAssertEqual(RepeatText.sentence(RepeatRule(unit: .week, interval: 2, afterCompletion: true)), "重复 上一个待办事项完成后 2 周")
    }

    func testSettingsReadTaskAndWriteBackDatesRelativeToStart() throws {
        let calendar = gregorian()
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let reminder = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 8, minute: 30))!
        let deadline = calendar.date(byAdding: .day, value: 4, to: start)!
        let todo = Todo(title: "重复", schedule: .dated, startDate: start, deadline: deadline,
                        repeatRule: RepeatRule(unit: .week, interval: 2), reminderDate: reminder)
        let settings = TaskRepeatSettings.from(todo, calendar: calendar)
        XCTAssertEqual(settings.rule, RepeatRule(unit: .week, interval: 2))
        XCTAssertEqual(settings.reminder?.hour, 8)
        XCTAssertEqual(settings.reminder?.minute, 30)
        XCTAssertEqual(settings.deadlineOffsetDays, 4)
        let applied = settings.applied(to: todo, now: start, calendar: calendar)
        XCTAssertEqual(applied.reminderDate, reminder)
        XCTAssertEqual(applied.deadline, deadline)
        XCTAssertEqual(applied.startDate, start)
    }

    /// 没有开始日期的任务设成重复时必须落到今天，否则下一实例没有锚点。
    func testRepeatWithoutStartDateFallsBackToToday() {
        let calendar = gregorian()
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 15))!
        let todo = Todo(title: "随时任务", schedule: .anytime)
        let settings = TaskRepeatSettings(rule: RepeatRule(unit: .day), reminder: DateComponents(hour: 7, minute: 15), deadlineOffsetDays: 2)
        let applied = settings.applied(to: todo, now: now, calendar: calendar)
        XCTAssertEqual(applied.schedule, .dated)
        XCTAssertEqual(applied.startDate, calendar.startOfDay(for: now))
        XCTAssertEqual(applied.reminderDate, calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 7, minute: 15)))
        XCTAssertEqual(applied.deadline, calendar.date(from: DateComponents(year: 2026, month: 9, day: 18)))
    }

    /// 取消重复只清规则，用户单独设过的截止日期和提醒保持不动。
    func testClearingRepeatKeepsOtherDates() {
        let calendar = gregorian()
        let start = calendar.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let deadline = calendar.date(byAdding: .day, value: 3, to: start)!
        let todo = Todo(title: "任务", schedule: .dated, startDate: start, deadline: deadline, repeatRule: RepeatRule(unit: .day))
        let applied = TaskRepeatSettings().applied(to: todo, now: start, calendar: calendar)
        XCTAssertNil(applied.repeatRule)
        XCTAssertEqual(applied.deadline, deadline)
        XCTAssertEqual(applied.startDate, start)
    }

    func testPopoverClearsRuleWhenModeIsNone() async throws {
        try await MainActor.run {
            let controller = TaskRepeatPopover(settings: TaskRepeatSettings(rule: RepeatRule(unit: .day)))
            var saved: [TaskRepeatSettings] = []
            controller.onSave = { saved.append($0) }
            _ = controller.view
            let mode = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first)
            XCTAssertEqual(mode.itemTitles, ["不重复", "完成后", "每天", "每周", "每月", "每年"])
            XCTAssertEqual(mode.indexOfSelectedItem, TaskRepeatMode.daily.rawValue)
            mode.selectItem(at: TaskRepeatMode.none.rawValue)
            XCTAssertTrue(mode.sendAction(mode.action, to: mode.target))
            try button("好", in: controller.view).performClick(nil)
            XCTAssertEqual(saved.count, 1)
            XCTAssertNil(saved[0].rule)
        }
    }

    /// 间隔非法时面板保持打开并提示，合法值才提交。
    func testPopoverRejectsInvalidIntervalAndEmitsFixedRule() async throws {
        try await MainActor.run {
            let controller = TaskRepeatPopover(settings: TaskRepeatSettings())
            var saved: [TaskRepeatSettings] = []
            controller.onSave = { saved.append($0) }
            _ = controller.view
            let mode = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first)
            let units = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }.last)
            mode.selectItem(at: TaskRepeatMode.weekly.rawValue)
            XCTAssertTrue(mode.sendAction(mode.action, to: mode.target))
            XCTAssertFalse(units.isEnabled, "固定周期锁定单位，避免与顶部选择矛盾")
            let interval = try field(labeled: "重复间隔", in: controller.view)
            interval.stringValue = "0"
            try button("好", in: controller.view).performClick(nil)
            XCTAssertTrue(saved.isEmpty, "无效间隔不应提交")
            interval.stringValue = "3"
            try button("好", in: controller.view).performClick(nil)
            XCTAssertEqual(saved.last?.rule, RepeatRule(unit: .week, interval: 3))
        }
    }

    func testPopoverCarriesReminderAndDeadlineWithRepeat() async throws {
        try await MainActor.run {
            let initial = TaskRepeatSettings(rule: RepeatRule(unit: .day, afterCompletion: true),
                                             reminder: DateComponents(hour: 9, minute: 5), deadlineOffsetDays: 2)
            let controller = TaskRepeatPopover(settings: initial)
            var saved: [TaskRepeatSettings] = []
            controller.onSave = { saved.append($0) }
            _ = controller.view
            let popups = descendants(controller.view).compactMap { $0 as? NSPopUpButton }
            XCTAssertEqual(popups.first?.indexOfSelectedItem, TaskRepeatMode.afterCompletion.rawValue)
            // “完成后”允许自由选单位，固定周期则锁定单位下拉。
            XCTAssertTrue(try XCTUnwrap(popups.last).isEnabled)
            let reminder = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSDatePicker }.first)
            XCTAssertTrue(reminder.isEnabled)
            try button("好", in: controller.view).performClick(nil)
            let result = try XCTUnwrap(saved.last)
            XCTAssertEqual(result.rule, RepeatRule(unit: .day, afterCompletion: true))
            XCTAssertEqual(result.reminder?.hour, 9)
            XCTAssertEqual(result.reminder?.minute, 5)
            XCTAssertEqual(result.deadlineOffsetDays, 2)
        }
    }

    func testCancelKeepsTaskUntouched() async throws {
        try await MainActor.run {
            let controller = TaskRepeatPopover(settings: TaskRepeatSettings(rule: RepeatRule(unit: .month)))
            var saved = 0
            var canceled = 0
            controller.onSave = { _ in saved += 1 }
            controller.onCancel = { canceled += 1 }
            _ = controller.view
            try button("取消", in: controller.view).performClick(nil)
            XCTAssertEqual(saved, 0)
            XCTAssertEqual(canceled, 1)
        }
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }
    @MainActor private func field(labeled label: String, in view: NSView) throws -> NSTextField {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == label })
    }
}
