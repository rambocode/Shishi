import AppKit
import XCTest
@testable import Shishi

final class BoundedNotesTests: XCTestCase {
    func testZeroWidthDefersDocumentMeasurementUntilRealWidthArrives() async throws {
        try await MainActor.run {
            let view = BoundedNotesView()
            let text = String(repeating: "尚未分配宽度的长备注\n", count: 250)
            view.stringValue = text
            view.layoutSubtreeIfNeeded()
            let document = try XCTUnwrap(view.documentView as? NSTextView)
            XCTAssertEqual(document.frame.height, 0)
            XCTAssertLessThanOrEqual(view.intrinsicContentSize.height, 160)
            XCTAssertEqual(view.stringValue, text)
            view.setFrameSize(NSSize(width: 320, height: 800))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.frame.height, 160)
            XCTAssertGreaterThan(document.frame.height, 160)
            let measuredSize = document.frame.size
            for _ in 0..<10 { view.layout() }
            XCTAssertEqual(document.frame.size, measuredSize)
            view.setFrameSize(NSSize(width: 320, height: 800))
            XCTAssertEqual(view.frame.height, 160)
        }
    }

    func testLongNotesKeepFullDocumentAndCanScrollToEnd() async throws {
        try await MainActor.run {
            let view = BoundedNotesView(frame: NSRect(x: 0, y: 0, width: 320, height: 18))
            let text = (1...250).map { "第\($0)行完整备注" }.joined(separator: "\n")
            view.stringValue = text
            view.layoutSubtreeIfNeeded()
            let document = try XCTUnwrap(view.documentView as? NSTextView)
            XCTAssertEqual(view.frame.height, 160)
            XCTAssertEqual(view.intrinsicContentSize.height, 160)
            XCTAssertGreaterThan(document.frame.height, 160)
            XCTAssertEqual(document.string, text)
            XCTAssertFalse(document.isEditable)
            XCTAssertTrue(document.isSelectable)
            XCTAssertTrue(view.hasVerticalScroller)
            XCTAssertEqual(view.scrollerStyle, .legacy)
            document.scrollRangeToVisible(NSRange(location: (text as NSString).length - 1, length: 1))
            XCTAssertGreaterThan(view.contentView.bounds.minY, 0)
            XCTAssertGreaterThanOrEqual(view.contentView.bounds.maxY, document.frame.height - 2)
        }
    }

    func testReplacingLongNotesWithShortTextShrinksAndRemovesScroller() async {
        await MainActor.run {
            let view = BoundedNotesView(frame: NSRect(x: 0, y: 0, width: 320, height: 18))
            view.stringValue = Array(repeating: "长备注", count: 220).joined(separator: "\n")
            view.stringValue = "短备注"
            view.layoutSubtreeIfNeeded()
            XCTAssertLessThan(view.frame.height, 30)
            XCTAssertGreaterThan(view.frame.height, 10)
            XCTAssertFalse(view.hasVerticalScroller)
            XCTAssertEqual(view.stringValue, "短备注")
        }
    }

    func testChineseWrappingAndResizeRemainBounded() async throws {
        try await MainActor.run {
            let view = BoundedNotesView(frame: NSRect(x: 0, y: 0, width: 600, height: 18))
            view.font = .systemFont(ofSize: 13)
            view.textColor = .labelColor
            let text = String(repeating: "中文备注需要随宽度自动换行并保留全部内容。", count: 40)
            view.stringValue = text
            let document = try XCTUnwrap(view.documentView as? NSTextView)
            let wideHeight = document.frame.height
            view.setFrameSize(NSSize(width: 120, height: 800))
            view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(document.frame.height, wideHeight)
            XCTAssertLessThanOrEqual(view.frame.height, 160)
            XCTAssertLessThanOrEqual(document.frame.width, view.contentSize.width)
            XCTAssertTrue(view.hasVerticalScroller)
            XCTAssertFalse(view.hasHorizontalScroller)
            XCTAssertEqual(view.stringValue, text)
            view.maximumHeight = 90
            XCTAssertLessThanOrEqual(view.frame.height, 90)
            XCTAssertEqual(view.intrinsicContentSize.height, 90)
        }
    }
}
