import XCTest
@testable import HopkeyCore

final class SnippetQuickSelectTests: XCTestCase {

    // MARK: index(forDigit:count:)

    func testDigitMapsToZeroBasedIndex() {
        XCTAssertEqual(SnippetQuickSelect.index(forDigit: 1, count: 5), 0)
        XCTAssertEqual(SnippetQuickSelect.index(forDigit: 3, count: 5), 2)
        XCTAssertEqual(SnippetQuickSelect.index(forDigit: 5, count: 5), 4)
    }

    func testDigitBeyondCountIsNil() {
        XCTAssertNil(SnippetQuickSelect.index(forDigit: 4, count: 3))
        XCTAssertNil(SnippetQuickSelect.index(forDigit: 1, count: 0))  // пустой список
    }

    func testDigitOutOfRangeIsNil() {
        XCTAssertNil(SnippetQuickSelect.index(forDigit: 0, count: 5))
        XCTAssertNil(SnippetQuickSelect.index(forDigit: -1, count: 5))
        XCTAssertNil(SnippetQuickSelect.index(forDigit: 10, count: 20))  // > maxDigits
    }

    func testNinthDigitIsLastQuickSlot() {
        XCTAssertEqual(SnippetQuickSelect.index(forDigit: 9, count: 9), 8)
        XCTAssertEqual(SnippetQuickSelect.index(forDigit: 9, count: 100), 8)
        XCTAssertNil(SnippetQuickSelect.index(forDigit: 9, count: 8))
    }

    // MARK: label(forRow:)

    func testRowLabelForFirstNine() {
        XCTAssertEqual(SnippetQuickSelect.label(forRow: 0), "1")
        XCTAssertEqual(SnippetQuickSelect.label(forRow: 8), "9")
    }

    func testRowLabelEmptyBeyondNine() {
        XCTAssertEqual(SnippetQuickSelect.label(forRow: 9), "")
        XCTAssertEqual(SnippetQuickSelect.label(forRow: 42), "")
    }
}
