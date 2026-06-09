import XCTest
@testable import HopkeyCore

final class TicketActionTests: XCTestCase {

    private func match(_ id: String, _ url: String) -> TicketMatch {
        TicketMatch(id: id, url: URL(string: url)!)
    }

    func testClipboardStringEmpty() {
        XCTAssertEqual(TicketAction.clipboardString(for: []), "")
    }

    func testClipboardStringSingle() {
        let matches = [match("PROJ-1", "https://jira.example.com/browse/PROJ-1")]
        XCTAssertEqual(TicketAction.clipboardString(for: matches),
                       "https://jira.example.com/browse/PROJ-1")
    }

    func testClipboardStringMultipleOnePerLine() {
        let matches = [
            match("PROJ-1", "https://jira.example.com/browse/PROJ-1"),
            match("PAY-2", "https://jira.example.com/browse/PAY-2"),
        ]
        XCTAssertEqual(TicketAction.clipboardString(for: matches),
                       "https://jira.example.com/browse/PROJ-1\nhttps://jira.example.com/browse/PAY-2")
    }
}
