import AppKit
import XCTest
@testable import Shishi

final class CardPopoverTests: XCTestCase {
    func testScheduleShortcutsAndCalendarOnlyEmitUserChoices() async throws {
        try await MainActor.run {
            let initial = Date(timeIntervalSince1970: 1_800_000_000)
            let controller = CardDatePopover(date: initial, isDeadline: false)
            var choices: [CardDateChoice] = []
            controller.onChoice = { choices.append($0) }
            let controls = descendants(controller.view)
            XCTAssertTrue(choices.isEmpty)
            XCTAssertEqual(controller.preferredContentSize.width, 280, accuracy: 0.1)
            XCTAssertGreaterThan(controller.preferredContentSize.height, 100)
            for title in ["今天", "今晚", "明天", "随时", "某天", "清除安排"] {
                try button(title, in: controller.view).performClick(nil)
            }
            XCTAssertEqual(choices, [.today, .evening, .tomorrow, .anytime, .someday, .clear])
            let picker = try XCTUnwrap(controls.compactMap { $0 as? NSDatePicker }.first)
            XCTAssertEqual(picker.datePickerStyle, .clockAndCalendar)
            XCTAssertEqual(picker.dateValue, initial)
            let selected = initial.addingTimeInterval(86_400)
            picker.dateValue = selected
            XCTAssertEqual(choices.count, 6)
            XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
            XCTAssertEqual(choices.last, .date(selected))
        }
    }

    func testDeadlineHasNoScheduleShortcutsAndClearIsExplicit() async throws {
        try await MainActor.run {
            let controller = CardDatePopover(date: nil, isDeadline: true)
            var choices: [CardDateChoice] = []
            controller.onChoice = { choices.append($0) }
            let buttons = descendants(controller.view).compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.map(\.title), ["清除截止"])
            XCTAssertTrue(choices.isEmpty)
            let picker = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSDatePicker }.first)
            let date = Date(timeIntervalSince1970: 1_900_000_000)
            picker.dateValue = date
            XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
            buttons[0].performClick(nil)
            XCTAssertEqual(choices, [.date(date), .clear])
        }
    }

    func testTagsStayDraftUntilDoneAndNormalizeCommaInput() async throws {
        try await MainActor.run {
            let controller = CardTagsPopover(tags: [" 保留 ", "移除", "保留", ""], suggestions: ["建议", "保留", "建议"])
            var changes: [[String]] = []
            controller.onChange = { changes.append($0) }
            _ = controller.view
            let remove = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }
                .first { $0.title == "移除" && $0.tag == 1 })
            remove.performClick(nil)
            try button("建议", in: controller.view).performClick(nil)
            XCTAssertTrue(changes.isEmpty)
            let input = try inputField(in: controller.view)
            input.stringValue = "新标签, 保留，另一个, ,新标签"
            try button("完成", in: controller.view).performClick(nil)
            XCTAssertEqual(changes, [["保留", "建议", "新标签", "另一个"]])
            try button("完成", in: controller.view).performClick(nil)
            XCTAssertEqual(changes.count, 1)
            XCTAssertEqual(controller.preferredContentSize.width, 280, accuracy: 0.1)
        }
    }

    func testReturnCommitsAndUncheckedSuggestionRemovesTag() async throws {
        try await MainActor.run {
            let controller = CardTagsPopover(tags: ["建议"], suggestions: ["建议"])
            var changes: [[String]] = []
            controller.onChange = { changes.append($0) }
            let suggestion = try button("建议", in: controller.view)
            XCTAssertEqual(suggestion.state, .on)
            suggestion.performClick(nil)
            let input = try inputField(in: controller.view)
            input.stringValue = " 新标签,第二个 "
            XCTAssertTrue(controller.control(input, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(changes, [["新标签", "第二个"]])
        }
    }

    func testCancelAndEscapeNeverCommit() async throws {
        try await MainActor.run {
            for escape in [false, true] {
                let controller = CardTagsPopover(tags: ["原标签"], suggestions: ["建议"])
                var changes: [[String]] = []
                controller.onChange = { changes.append($0) }
                try button("建议", in: controller.view).performClick(nil)
                let input = try inputField(in: controller.view)
                input.stringValue = "未提交"
                if escape {
                    XCTAssertTrue(controller.control(input, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
                } else {
                    try button("取消", in: controller.view).performClick(nil)
                }
                try button("完成", in: controller.view).performClick(nil)
                XCTAssertTrue(changes.isEmpty)
            }
        }
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor
    private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    @MainActor
    private func inputField(in view: NSView) throws -> NSTextField {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
    }
}
