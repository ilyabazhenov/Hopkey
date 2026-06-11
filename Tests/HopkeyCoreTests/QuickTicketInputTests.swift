import XCTest
@testable import HopkeyCore

final class QuickTicketInputTests: XCTestCase {

    private let proj = LinkTemplate(name: "PROJ", pattern: "PROJ-(\\d+)",
                                    url: "https://jira.example.com/browse/PROJ-$1",
                                    wholeWord: true, uppercase: true)
    private let team = LinkTemplate(name: "TEAM", pattern: "TEAM-(\\d+)",
                                    url: "https://team.example.com/browse/TEAM-$1",
                                    wholeWord: true, uppercase: true)
    private let github = LinkTemplate(name: "GitHub", pattern: "#(\\d+)",
                                      url: "https://github.com/o/r/issues/$1",
                                      wholeWord: true, uppercase: false)

    // MARK: - resolve(_:templates:)

    func testFullKeyResolves() {
        guard case let .resolved(match) = QuickTicketInput.resolve("PROJ-123", templates: [proj]) else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(match.id, "PROJ-123")
        XCTAssertEqual(match.url.absoluteString, "https://jira.example.com/browse/PROJ-123")
    }

    func testFullKeyWithUnknownPrefixIsInvalid() {
        XCTAssertEqual(QuickTicketInput.resolve("NOPE-1", templates: [proj]), .invalid)
    }

    func testFullTextResolvesNonPrefixTemplate() {
        // Полный ввод `#5` распознаётся GitHub-шаблоном через exactMatch.
        guard case let .resolved(match) = QuickTicketInput.resolve("#5", templates: [github]) else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(match.id, "#5")
        XCTAssertEqual(match.url.absoluteString, "https://github.com/o/r/issues/5")
    }

    func testNumberWithSingleFillableTemplateResolves() {
        guard case let .resolved(match) = QuickTicketInput.resolve("123", templates: [proj]) else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(match.id, "PROJ-123")
        XCTAssertEqual(match.url.absoluteString, "https://jira.example.com/browse/PROJ-123")
    }

    func testNumberWithMultipleFillableTemplatesNeedsTemplate() {
        XCTAssertEqual(QuickTicketInput.resolve("123", templates: [proj, team]),
                       .needsTemplate(number: "123"))
    }

    func testEmptyInput() {
        XCTAssertEqual(QuickTicketInput.resolve("   ", templates: [proj]), .empty)
    }

    func testGarbageIsInvalid() {
        XCTAssertEqual(QuickTicketInput.resolve("hello", templates: [proj]), .invalid)
    }

    func testNumberWithoutTemplatesIsInvalid() {
        XCTAssertEqual(QuickTicketInput.resolve("123", templates: []), .invalid)
    }

    func testNumberWithOnlyNonFillableTemplateIsInvalid() {
        // CVE использует $0 — не заполнить одним числом.
        let cve = LinkTemplate(name: "CVE", pattern: "CVE-\\d{4}-\\d+",
                               url: "https://nvd.nist.gov/vuln/detail/$0")
        XCTAssertEqual(QuickTicketInput.resolve("123", templates: [cve]), .invalid)
    }

    func testInvalidTemplatesAreIgnored() {
        let blank = LinkTemplate(name: "", pattern: "", url: "")
        // Остаётся ровно один валидный заполнимый шаблон → номер собирается без выбора.
        guard case let .resolved(match) = QuickTicketInput.resolve("9", templates: [blank, proj]) else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(match.id, "PROJ-9")
    }

    // MARK: - resolve(number:template:)

    func testResolveByNumberAndTemplate() {
        guard case let .resolved(match) = QuickTicketInput.resolve(number: "42", template: team) else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(match.id, "TEAM-42")
        XCTAssertEqual(match.url.absoluteString, "https://team.example.com/browse/TEAM-42")
    }

    func testResolveByNumberRejectsNonDigits() {
        XCTAssertEqual(QuickTicketInput.resolve(number: "4x", template: team), .invalid)
    }

    func testResolveByNumberIDFromLastPathComponent() {
        // У GitHub-шаблона id для ручного ввода — последний компонент пути URL (номер).
        guard case let .resolved(match) = QuickTicketInput.resolve(number: "5", template: github) else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(match.id, "5")
        XCTAssertEqual(match.url.absoluteString, "https://github.com/o/r/issues/5")
    }

    // MARK: - fillableTemplates

    func testFillableTemplatesFiltersByDollarOne() {
        let cve = LinkTemplate(name: "CVE", pattern: "CVE-\\d{4}-\\d+",
                               url: "https://nvd.nist.gov/vuln/detail/$0")
        let fillable = QuickTicketInput.fillableTemplates(in: [proj, cve, github])
        XCTAssertEqual(fillable.map(\.name), ["PROJ", "GitHub"])
    }
}
