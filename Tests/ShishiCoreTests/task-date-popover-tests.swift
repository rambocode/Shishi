import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class TaskDatePopoverTests: XCTestCase {
    @MainActor private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    func testSaveFailureRetainsPanelAndCanRetryWhileCancelDoesNotCommit() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let original = Todo(title: "任务", notes: "不丢失")
            let pane = TaskDatePopover(todo: original)
            let today = try XCTUnwrap(views(pane.view).compactMap { $0 as? NSButton }.first { $0.title == "今天" })
            var attempts: [Todo] = []
            pane.onApply = { attempts.append($0); return attempts.count > 1 }
            today.performClick(nil)
            XCTAssertEqual(attempts.count, 1)
            XCTAssertEqual(attempts[0].schedule, .dated)
            XCTAssertEqual(attempts[0].notes, original.notes)
            XCTAssertTrue(views(pane.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("保存失败") })
            today.performClick(nil); XCTAssertEqual(attempts.count, 2)
            today.performClick(nil); XCTAssertEqual(attempts.count, 2)
            let canceled = TaskDatePopover(todo: original); _ = canceled.view
            var canceledCalls = 0
            canceled.onApply = { _ in XCTFail("取消不得保存"); return true }
            canceled.onCancel = { canceledCalls += 1 }
            canceled.cancelDraft(); canceled.cancelDraft()
            XCTAssertEqual(canceledCalls, 1)
            XCTAssertNil(original.startDate)
        }
    }
    func testReminderExpansionCancellationDoesNotSaveAndInvalidTimeKeepsInput() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let pane = TaskDatePopover(todo: Todo(title: "任务"))
            var applied = 0; pane.onApply = { _ in applied += 1; return true }
            let add = try XCTUnwrap(views(pane.view).compactMap { $0 as? NSButton }.first { $0.title == "添加提醒" })
            add.performClick(nil)
            let time = try XCTUnwrap(views(pane.view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "提醒时间" })
            time.stringValue = "25:99"
            let save = try XCTUnwrap(views(pane.view).compactMap { $0 as? NSButton }.first { $0.title == "保存时间" })
            save.performClick(nil)
            XCTAssertEqual(applied, 0); XCTAssertEqual(time.stringValue, "25:99")
            let cancel = try XCTUnwrap(views(pane.view).compactMap { $0 as? NSButton }.first { $0.title == "取消" })
            cancel.performClick(nil); XCTAssertEqual(applied, 0)
            pane.cancelDraft(); XCTAssertEqual(applied, 0)
        }
    }
}
