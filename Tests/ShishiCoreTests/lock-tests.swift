import XCTest
@testable import Shishi

final class LockTests: XCTestCase {
    func testLockRejectsConcurrentWriterAndReleasesOnClose() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shishi-lock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        var first: LibraryLock? = try LibraryLock(dataURL: url)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try LibraryLock(dataURL: url))
        first = nil
        let next = try LibraryLock(dataURL: url)
        try withExtendedLifetime(next) { XCTAssertThrowsError(try LibraryLock(dataURL: url)) }
    }
}
