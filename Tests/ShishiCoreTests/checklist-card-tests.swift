import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class ChecklistCardTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor private func fields(_ view: NSView) -> [NSTextField] {
        descendants(view).compactMap { $0 as? NSTextField }
    }
    @MainActor private func command(_ selector: Selector, field: NSTextField, view: InlineChecklistView) -> Bool {
        let editor = NSTextView()
        editor.string = field.stringValue
        return view.control(field, textView: editor, doCommandBy: selector)
    }
    func testAddReturnDeleteAndEmptyExitWithoutWindow() async throws {
        try await MainActor.run {
            let view = InlineChecklistView(items: [])
            var exits = 0
            view.onExit = { exits += 1 }
            XCTAssertFalse(view.hasRows)
            view.addItemAndFocus(); view.addItemAndFocus()
            XCTAssertEqual(fields(view).count, 1)
            XCTAssertTrue(view.items.isEmpty)
            let first = try XCTUnwrap(fields(view).first)
            first.stringValue = "第一项"
            XCTAssertTrue(command(#selector(NSResponder.insertNewline(_:)), field: first, view: view))
            XCTAssertEqual(fields(view).count, 2)
            let blank = try XCTUnwrap(fields(view).last)
            XCTAssertTrue(command(#selector(NSResponder.deleteBackward(_:)), field: blank, view: view))
            XCTAssertEqual(view.items.map(\.title), ["第一项"])
            view.addItemAndFocus()
            XCTAssertTrue(command(#selector(NSResponder.insertNewline(_:)), field: try XCTUnwrap(fields(view).last), view: view))
            XCTAssertEqual(exits, 1)
            XCTAssertEqual(fields(view).count, 1)
        }
    }
    func testCheckboxRemovalAndInMemorySaveReloadPreserveIdentity() async throws {
        try await MainActor.run {
            let original = ChecklistItem(title: "  原文本  ", completed: false)
            let view = InlineChecklistView(items: [original])
            var changes = 0
            view.onChange = { changes += 1 }
            let checkbox = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == "勾选检查列表项" })
            checkbox.performClick(nil)
            view.addItemAndFocus()
            XCTAssertTrue(view.commitPendingInput())
            let data = try JSONEncoder().encode(view.items)
            let reloaded = InlineChecklistView(items: try JSONDecoder().decode([ChecklistItem].self, from: data))
            XCTAssertEqual(reloaded.items.first?.id, original.id)
            XCTAssertEqual(reloaded.items.first?.title, original.title)
            XCTAssertEqual(reloaded.items.first?.completed, true)
            XCTAssertEqual(fields(reloaded).count, 1)
            let field = try XCTUnwrap(fields(reloaded).first)
            reloaded.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
            XCTAssertEqual(reloaded.selectedItemID, original.id)
            XCTAssertTrue(reloaded.removeSelectedItem())
            XCTAssertFalse(reloaded.hasRows)
            XCTAssertFalse(reloaded.removeSelectedItem())
            XCTAssertGreaterThan(changes, 0)
            XCTAssertFalse(original.completed)
        }
    }
    func testMultilineSplittingScrollHeightAndStableControls() async throws {
        try await MainActor.run {
            let original = ChecklistItem(title: "初始", completed: true)
            let view = InlineChecklistView(items: [original])
            let field = try XCTUnwrap(fields(view).first)
            field.stringValue = "一\r\n二\n\n三"
            view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            XCTAssertEqual(view.items.map(\.title), ["一", "二", "三"])
            XCTAssertEqual(view.items.first?.id, original.id)
            XCTAssertTrue(view.items[0].completed)
            XCTAssertTrue(fields(view).first === field)
            _ = view.items; _ = view.items
            XCTAssertTrue(fields(view).first === field)
            for index in 0..<12 {
                view.addItemAndFocus()
                fields(view).last?.stringValue = "项\(index)"
            }
            view.frame = NSRect(x: 0, y: 0, width: 300, height: view.preferredHeight)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.preferredHeight, 220)
            let scroll = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first)
            XCTAssertEqual(scroll.documentView?.frame.height, 420)
            XCTAssertTrue(scroll.hasVerticalScroller)
        }
    }
    func testMarkedReturnDoesNotCreateRowAndContextMenuMovesRows() async throws {
        try await MainActor.run {
            let first = ChecklistItem(title: "一"), second = ChecklistItem(title: "二")
            let view = InlineChecklistView(items: [first, second])
            let field = try XCTUnwrap(fields(view).first)
            let editor = NSTextView()
            editor.string = field.stringValue
            editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 1))
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertFalse(view.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(fields(view).count, 2)
            let entry = try XCTUnwrap(field.menu?.items.first { $0.title == "下移" })
            if let action = entry.action { NSApp.sendAction(action, to: entry.target, from: entry) }
            XCTAssertEqual(view.items.map(\.id), [second.id, first.id])
        }
    }
    func testSelectionSurvivesCommitAndExplicitClearNotifies() async throws {
        try await MainActor.run {
            let first = ChecklistItem(title: "一"), second = ChecklistItem(title: "二")
            let view = InlineChecklistView(items: [first, second])
            var selections = 0
            view.onSelectionChange = { selections += 1 }
            let field = try XCTUnwrap(fields(view).last)
            view.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
            XCTAssertEqual(view.selectedItemID, second.id)
            XCTAssertTrue(view.commitPendingInput())
            XCTAssertEqual(view.selectedItemID, second.id)
            XCTAssertEqual(selections, 1)
            XCTAssertTrue(view.removeSelectedItem())
            XCTAssertEqual(view.items.map(\.id), [first.id])
            XCTAssertNil(view.selectedItemID)
            view.clearSelection()
            XCTAssertNil(view.selectedItemID)
            XCTAssertEqual(selections, 2)
            XCTAssertFalse(view.removeSelectedItem())
            XCTAssertFalse(view.canMoveSelectedItem(by: 1))
            view.clearSelection()
            XCTAssertEqual(selections, 2)
        }
    }
    func testSelectedMovesUseInsertionPreserveControlsAndRejectBounds() async throws {
        try await MainActor.run {
            let items = [ChecklistItem(title: "一", completed: true), ChecklistItem(title: "二"), ChecklistItem(title: "三")]
            let view = InlineChecklistView(items: items)
            let field = try XCTUnwrap(fields(view).first)
            view.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
            XCTAssertFalse(view.canMoveSelectedItem(by: -1))
            XCTAssertFalse(view.moveSelectedItem(by: Int.max))
            XCTAssertFalse(view.moveSelectedItem(by: 0))
            XCTAssertTrue(view.canMoveSelectedItem(by: 2))
            XCTAssertTrue(view.moveSelectedItem(by: 2))
            XCTAssertEqual(view.items.map(\.id), [items[1].id, items[2].id, items[0].id])
            XCTAssertEqual(view.selectedItemID, items[0].id)
            XCTAssertTrue(view.items.last?.completed == true)
            XCTAssertTrue(fields(view).contains { $0 === field })
            XCTAssertFalse(view.moveSelectedItem(by: 1))
            XCTAssertTrue(view.moveSelectedItem(by: -2))
            XCTAssertEqual(view.items, items)
        }
    }
    func testHandleDropRejectsCrossParentAndStaleIDsPreservesSavedState() async throws {
        try await MainActor.run {
            let items = [ChecklistItem(title: "一", completed: true), ChecklistItem(title: "二"), ChecklistItem(title: "三")]
            let view = InlineChecklistView(items: items)
            let other = InlineChecklistView(items: items)
            let payload = ChecklistDragPayload(sourceID: view.sourceID, itemID: items[0].id)
            let sourceID = view.sourceID
            var changes = 0
            view.onChange = { changes += 1 }
            XCTAssertTrue(view.canAcceptDrop(payload))
            XCTAssertFalse(other.canAcceptDrop(payload))
            XCTAssertFalse(other.acceptDrop(payload, at: 3))
            XCTAssertFalse(view.acceptDrop(ChecklistDragPayload(sourceID: sourceID, itemID: UUID()), at: 0))
            XCTAssertFalse(view.acceptDrop(payload, at: 4))
            XCTAssertTrue(view.acceptDrop(payload, at: 3))
            XCTAssertEqual(view.sourceID, sourceID)
            XCTAssertEqual(view.items.map(\.id), [items[1].id, items[2].id, items[0].id])
            XCTAssertEqual(view.selectedItemID, items[0].id)
            XCTAssertTrue(view.acceptDrop(payload, at: 3))
            XCTAssertEqual(changes, 1)
            let saved = try JSONDecoder().decode([ChecklistItem].self, from: JSONEncoder().encode(view.items))
            XCTAssertEqual(saved.last, items[0])
            XCTAssertEqual(other.items, items)
            XCTAssertTrue(view.removeSelectedItem())
            XCTAssertFalse(view.canAcceptDrop(payload))
            let handles = descendants(view).compactMap { $0 as? ChecklistDragHandle }
            XCTAssertEqual(handles.count, 2)
            XCTAssertTrue(handles.allSatisfy { $0.payload.sourceID == sourceID })
            XCTAssertFalse(descendants(view).compactMap { $0 as? NSButton }.contains { $0.title == "×" })
            XCTAssertTrue(fields(view).allSatisfy { field in field.menu?.items.contains { $0.title == "移除" } == false })
        }
    }
}
