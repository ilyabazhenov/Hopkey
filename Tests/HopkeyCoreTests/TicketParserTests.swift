import XCTest
@testable import HopkeyCore

final class TicketParserTests: XCTestCase {

    let prefixes = ["PROJ"]
    let base = "https://jira.example.com/browse/"

    private func ids(_ text: String, prefixes: [String]? = nil) -> [String] {
        TicketParser.matches(in: text, prefixes: prefixes ?? self.prefixes, baseURL: base).map(\.id)
    }

    func testSimpleMatch() {
        XCTAssertEqual(ids("ping PROJ-12345 please"), ["PROJ-12345"])
    }

    func testCaseInsensitiveAndNormalized() {
        XCTAssertEqual(ids("proj-7"), ["PROJ-7"])
    }

    func testURLConstruction() {
        let m = TicketParser.matches(in: "PROJ-36075", prefixes: prefixes, baseURL: base)
        XCTAssertEqual(m.first?.url.absoluteString,
                       "https://jira.example.com/browse/PROJ-36075")
    }

    func testNoTicket() {
        XCTAssertTrue(ids("no ticket here, just text 123").isEmpty)
    }

    func testMultipleAndDedup() {
        let text = "see PROJ-1 and PROJ-2 and again PROJ-1"
        XCTAssertEqual(ids(text), ["PROJ-1", "PROJ-2"])
    }

    func testBoundariesRejectGluedPrefix() {
        // Не должно ловиться внутри другого слова.
        XCTAssertTrue(ids("XPROJ-1").isEmpty)
        XCTAssertTrue(ids("PROJ-1X").isEmpty)
    }

    func testBaseURLWithoutTrailingSlash() {
        let m = TicketParser.matches(in: "PROJ-9", prefixes: prefixes,
                                     baseURL: "https://jira.example/browse")
        XCTAssertEqual(m.first?.url.absoluteString, "https://jira.example/browse/PROJ-9")
    }

    func testMultiplePrefixes() {
        let text = "PROJ-1 PAY-22 NOPE-3"
        XCTAssertEqual(ids(text, prefixes: ["PROJ", "PAY"]), ["PROJ-1", "PAY-22"])
    }

    func testEmptyPrefixesYieldsNothing() {
        XCTAssertTrue(ids("PROJ-1", prefixes: []).isEmpty)
    }

    func testEmptyTextYieldsNothing() {
        XCTAssertTrue(ids("").isEmpty)
    }

    func testWhitespaceOnlyPrefixesYieldNothing() {
        XCTAssertTrue(ids("PROJ-1", prefixes: ["  ", ""]).isEmpty)
    }

    func testPrefixesAreTrimmed() {
        XCTAssertEqual(ids("PROJ-1", prefixes: ["  PROJ  "]), ["PROJ-1"])
    }

    func testDedupIsCaseInsensitive() {
        // proj-1 и PROJ-1 — один и тот же тикет после нормализации.
        XCTAssertEqual(ids("PROJ-1 then proj-1"), ["PROJ-1"])
    }

    func testMatchesAcrossNewlines() {
        XCTAssertEqual(ids("PROJ-1\nsome text\nPROJ-2"), ["PROJ-1", "PROJ-2"])
    }

    func testInvalidBaseURLDropsMatch() {
        // Пробел в base делает итоговую строку невалидным URL → совпадение отбрасывается.
        let m = TicketParser.matches(in: "PROJ-9", prefixes: prefixes,
                                     baseURL: "https://bad host/browse")
        XCTAssertTrue(m.isEmpty)
    }
}
