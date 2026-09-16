import AppKit
import XCTest
@testable import Shishi

final class FocusAppearanceTests: XCTestCase {
    func testAllControlRingsAreSuppressedWithoutDisablingEditing() async {
        await MainActor.run {
            _ = NSApplication.shared
            let root = NSView()
            let search = NSSearchField(), title = NSTextField(), button = NSButton()
            let table = NSTableView(), popup = NSPopUpButton()
            let tableAcceptedFocus = table.acceptsFirstResponder
            for view in [search, title, button, table, popup] as [NSView] { root.addSubview(view) }
            FocusAppearance.removeRings(in: root)
            for view in root.subviews {
                XCTAssertEqual(view.focusRingType, .none)
                if let cell = (view as? NSControl)?.cell { XCTAssertEqual(cell.focusRingType, .none) }
            }
            XCTAssertTrue(search.isEditable); XCTAssertTrue(title.isEditable)
            XCTAssertTrue(button.isEnabled); XCTAssertEqual(table.acceptsFirstResponder, tableAcceptedFocus)
        }
    }
    func testNewFieldEditorControlLosesRingButKeepsFocusAndSelection() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let policy = FocusAppearance()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close(); withExtendedLifetime(policy) {} }
            let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
            field.stringValue = "A B"; window.contentView?.addSubview(field)
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.setSelectedRange(NSRange(location: 1, length: 1))
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            XCTAssertEqual(field.focusRingType, .none)
            XCTAssertEqual(field.cell?.focusRingType, NSFocusRingType.none)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 1))
            XCTAssertEqual(field.stringValue, "A B")
        }
    }
}
