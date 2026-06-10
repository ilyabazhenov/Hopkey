import XCTest
@testable import HopkeyCore

final class QuickTicketInputTests: XCTestCase {

    private let proj = JiraProject(baseURL: "https://jira.example.com/browse/", prefixes: ["PROJ"])
    private let team = JiraProject(baseURL: "https://team.example.com/browse/", prefixes: ["TEAM"])

    // MARK: - makeMatch (хелпер сборки URL)

    func testMakeMatchBuildsURL() {
        let m = TicketParser.makeMatch(id: "PROJ-7", baseURL: "https://jira.example.com/browse/")
        XCTAssertEqual(m?.id, "PROJ-7")
        XCTAssertEqual(m?.url.absoluteString, "https://jira.example.com/browse/PROJ-7")
    }

    func testMakeMatchAddsMissingSlashAndUppercases() {
        let m = TicketParser.makeMatch(id: "proj-7", baseURL: "https://jira.example.com/browse")
        XCTAssertEqual(m?.id, "PROJ-7")
        XCTAssertEqual(m?.url.absoluteString, "https://jira.example.com/browse/PROJ-7")
    }

    func testMakeMatchRejectsEmptyID() {
        XCTAssertNil(TicketParser.makeMatch(id: "   ", baseURL: "https://jira.example.com/browse/"))
    }

    // MARK: - resolve(_:projects:)

    func testFullKeyResolves() {
        guard case let .resolved(match) = QuickTicketInput.resolve("PROJ-123", projects: [proj]) else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(match.id, "PROJ-123")
        XCTAssertEqual(match.url.absoluteString, "https://jira.example.com/browse/PROJ-123")
    }

    func testFullKeyWithUnknownPrefixIsInvalid() {
        XCTAssertEqual(QuickTicketInput.resolve("NOPE-1", projects: [proj]), .invalid)
    }

    func testNumberWithSingleProjectAndPrefixResolves() {
        guard case let .resolved(match) = QuickTicketInput.resolve("123", projects: [proj]) else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(match.id, "PROJ-123")
    }

    func testNumberWithMultipleProjectsNeedsProject() {
        XCTAssertEqual(QuickTicketInput.resolve("123", projects: [proj, team]),
                       .needsProject(number: "123"))
    }

    func testNumberWithMultiplePrefixesInOneProjectNeedsProject() {
        let multi = JiraProject(baseURL: "https://j.example.com/browse/", prefixes: ["A", "B"])
        XCTAssertEqual(QuickTicketInput.resolve("123", projects: [multi]),
                       .needsProject(number: "123"))
    }

    func testEmptyInput() {
        XCTAssertEqual(QuickTicketInput.resolve("   ", projects: [proj]), .empty)
    }

    func testGarbageIsInvalid() {
        XCTAssertEqual(QuickTicketInput.resolve("hello", projects: [proj]), .invalid)
    }

    func testNumberWithoutProjectsIsInvalid() {
        XCTAssertEqual(QuickTicketInput.resolve("123", projects: []), .invalid)
    }

    func testInvalidProjectsAreIgnored() {
        let blank = JiraProject(baseURL: "", prefixes: [])
        // Остаётся ровно один валидный проект → номер собирается без выбора.
        guard case let .resolved(match) = QuickTicketInput.resolve("9", projects: [blank, proj]) else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(match.id, "PROJ-9")
    }

    // MARK: - resolve(number:project:prefix:)

    func testResolveByNumberAndPickedPrefix() {
        guard case let .resolved(match) = QuickTicketInput.resolve(number: "42", project: team, prefix: "team") else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(match.id, "TEAM-42")
        XCTAssertEqual(match.url.absoluteString, "https://team.example.com/browse/TEAM-42")
    }

    func testResolveByNumberRejectsNonDigits() {
        XCTAssertEqual(QuickTicketInput.resolve(number: "4x", project: team, prefix: "TEAM"), .invalid)
    }

    // MARK: - pickerPairs

    func testPickerPairsFlattensPrefixes() {
        let multi = JiraProject(baseURL: "https://j.example.com/browse/", prefixes: ["A", "B"])
        let pairs = QuickTicketInput.pickerPairs(in: [multi, proj])
        XCTAssertEqual(pairs.map(\.prefix), ["A", "B", "PROJ"])
    }
}
