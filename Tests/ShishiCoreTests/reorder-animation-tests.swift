import AppKit
import XCTest
@testable import Shishi

final class ReorderAnimationTests: XCTestCase {
    private func apply(_ moves: [RowReorderPlan.Move], to source: [String]) -> [String] {
        var rows = source
        for move in moves { rows.insert(rows.remove(at: move.source), at: move.destination) }
        return rows
    }

    @MainActor func testPreviewRendersBlueBackground() throws {
        let image = HeadingDragPreview.image(title: "资料整理", size: NSSize(width: 720, height: 38), textSize: 14)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.blueComponent, color.redComponent)
        if let path = ProcessInfo.processInfo.environment["SHISHI_DRAG_CAPTURE_PATH"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    func testSmallGroupAcrossLargeListNeedsOnlyTwoNativeMoves() throws {
        let source = (0..<6000).map(String.init)
        let destination = Array(source.dropFirst(2)) + Array(source.prefix(2))
        let plan = try XCTUnwrap(RowReorderPlan(from: source, to: destination))
        XCTAssertEqual(plan.moves.count, 2)
        XCTAssertEqual(apply(plan.moves, to: source), destination)
        let reverse = try XCTUnwrap(RowReorderPlan(from: destination, to: source))
        XCTAssertEqual(reverse.moves.count, 2)
        XCTAssertEqual(apply(reverse.moves, to: destination), source)
    }

    func testAllContiguousGroupMovesKeepOrderAndUnchangedPrefixAndSuffix() throws {
        let source = (0..<12).map(String.init)
        for start in 0..<source.count {
            for end in (start + 1)...source.count {
                let group = Array(source[start..<end])
                var remainder = source; remainder.removeSubrange(start..<end)
                for insertion in 0...remainder.count {
                    var target = remainder; target.insert(contentsOf: group, at: insertion)
                    let plan = try XCTUnwrap(RowReorderPlan(from: source, to: target))
                    XCTAssertEqual(apply(plan.moves, to: source), target)
                    XCTAssertLessThanOrEqual(plan.moves.count, group.count)
                }
            }
        }
    }

    func testInvalidIdentityOrComplexPermutationFallsBackToReload() {
        XCTAssertNil(RowReorderPlan(from: ["a", "a"], to: ["a", "a"]))
        XCTAssertNil(RowReorderPlan(from: ["a", "b"], to: ["a", "c"]))
        XCTAssertNil(RowReorderPlan(from: ["a", "b", "c", "d"], to: ["d", "b", "a", "c"]))
    }
}
