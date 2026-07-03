import XCTest
@testable import HopkeyCore

final class ClipboardHistoryTests: XCTestCase {

    func testRecordAddsToFront() {
        let h = ClipboardHistory()
        h.record("a")
        h.record("b")
        XCTAssertEqual(h.entries, ["b", "a"])
    }

    func testDuplicateMovesToFrontWithoutGrowing() {
        let h = ClipboardHistory()
        h.record("a"); h.record("b"); h.record("a")
        XCTAssertEqual(h.entries, ["a", "b"])
    }

    func testCapacityEnforced() {
        let h = ClipboardHistory(capacity: 3)
        ["1", "2", "3", "4"].forEach(h.record)
        XCTAssertEqual(h.entries, ["4", "3", "2"])
    }

    func testEmptyOrWhitespaceIgnored() {
        let h = ClipboardHistory()
        h.record("")
        h.record("   \n")
        XCTAssertTrue(h.entries.isEmpty)
    }

    func testClear() {
        let h = ClipboardHistory()
        h.record("a"); h.clear()
        XCTAssertTrue(h.entries.isEmpty)
    }
}
