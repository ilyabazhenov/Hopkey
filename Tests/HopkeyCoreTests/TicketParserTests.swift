import XCTest
@testable import HopkeyCore

final class TicketParserTests: XCTestCase {

    // Базовый Jira-шаблон: PROJ-<число> → /browse/PROJ-<число>, верхний регистр, границы слова.
    private func jira(_ prefix: String = "PROJ",
                      base: String = "https://jira.example.com/browse/") -> LinkTemplate {
        LinkTemplate(name: prefix, pattern: "\(prefix)-(\\d+)", url: "\(base)\(prefix)-$1",
                     wholeWord: true, uppercase: true)
    }

    private func ids(_ text: String, _ templates: [LinkTemplate]) -> [String] {
        TicketParser.matches(in: text, templates: templates).map(\.id)
    }

    func testSimpleMatch() {
        XCTAssertEqual(ids("ping PROJ-12345 please", [jira()]), ["PROJ-12345"])
    }

    func testCaseInsensitiveAndNormalized() {
        XCTAssertEqual(ids("proj-7", [jira()]), ["PROJ-7"])
    }

    func testURLConstruction() {
        let m = TicketParser.matches(in: "PROJ-36075", templates: [jira()])
        XCTAssertEqual(m.first?.url.absoluteString, "https://jira.example.com/browse/PROJ-36075")
    }

    func testNoTicket() {
        XCTAssertTrue(ids("no ticket here, just text 123", [jira()]).isEmpty)
    }

    func testMultipleAndDedup() {
        XCTAssertEqual(ids("see PROJ-1 and PROJ-2 and again PROJ-1", [jira()]), ["PROJ-1", "PROJ-2"])
    }

    // Префилл окна ввода: выделенная masked-ссылка из нативного Telegram приходит как
    // «ключ (URL)» — ключ встречается дважды, должен схлопнуться в один матч.
    func testMaskedLinkTextWithURL() {
        let s = "PROJ-41102 (https://jira.example.com/browse/PROJ-41102)"
        XCTAssertEqual(ids(s, [jira()]), ["PROJ-41102"])
    }

    // Префилл: выделен голый URL задачи — ключ всё равно извлекается.
    func testBareBrowseURL() {
        XCTAssertEqual(ids("https://jira.example.com/browse/PROJ-41102", [jira()]), ["PROJ-41102"])
    }

    func testWholeWordRejectsGluedPrefix() {
        XCTAssertTrue(ids("XPROJ-1", [jira()]).isEmpty)
        XCTAssertTrue(ids("PROJ-1X", [jira()]).isEmpty)
    }

    func testWholeWordOffMatchesInsideWord() {
        // Без границ слова шаблон ловит и приклеенные совпадения.
        let t = LinkTemplate(name: "id", pattern: "id(\\d+)", url: "https://x/$1", wholeWord: false)
        XCTAssertEqual(ids("xid42", [t]), ["id42"])
    }

    func testUppercaseFalseKeepsCase() {
        // GitHub-подобный шаблон: регистр не трогаем, в URL идёт только номер.
        let gh = LinkTemplate(name: "gh", pattern: "#(\\d+)", url: "https://github.com/o/r/issues/$1",
                              wholeWord: true, uppercase: false)
        let m = TicketParser.matches(in: "see #123", templates: [gh])
        XCTAssertEqual(m.first?.id, "#123")
        XCTAssertEqual(m.first?.url.absoluteString, "https://github.com/o/r/issues/123")
    }

    func testDedupIsCaseInsensitive() {
        XCTAssertEqual(ids("PROJ-1 then proj-1", [jira()]), ["PROJ-1"])
    }

    func testMatchesAcrossNewlines() {
        XCTAssertEqual(ids("PROJ-1\nsome text\nPROJ-2", [jira()]), ["PROJ-1", "PROJ-2"])
    }

    func testInvalidURLDropsMatch() {
        // Пробел в литеральной части URL делает адрес невалидным → совпадение отбрасывается.
        let t = jira(base: "https://bad host/browse/")
        XCTAssertTrue(TicketParser.matches(in: "PROJ-9", templates: [t]).isEmpty)
    }

    func testBrokenRegexIsSkipped() {
        let broken = LinkTemplate(name: "x", pattern: "PROJ-(\\d+", url: "https://x/$1")
        XCTAssertTrue(TicketParser.matches(in: "PROJ-1", templates: [broken]).isEmpty)
    }

    func testDisabledTemplateIsSkipped() {
        var t = jira()
        t.enabled = false
        XCTAssertTrue(TicketParser.matches(in: "PROJ-1", templates: [t]).isEmpty)
    }

    // MARK: - Несколько шаблонов

    func testMultipleTemplatesRouteByPattern() {
        let templates = [jira("PROJ", base: "https://a.example.com/browse/"),
                         jira("ABC", base: "https://b.example.com/browse/")]
        let m = TicketParser.matches(in: "PROJ-1 ABC-2", templates: templates)
        XCTAssertEqual(m.map(\.id), ["PROJ-1", "ABC-2"])
        XCTAssertEqual(m.map { $0.url.absoluteString },
                       ["https://a.example.com/browse/PROJ-1",
                        "https://b.example.com/browse/ABC-2"])
    }

    func testFirstTemplateWinsOnDuplicateID() {
        let templates = [jira("PROJ", base: "https://a.example.com/browse/"),
                         jira("PROJ", base: "https://b.example.com/browse/")]
        let m = TicketParser.matches(in: "PROJ-1", templates: templates)
        XCTAssertEqual(m.map(\.id), ["PROJ-1"])
        XCTAssertEqual(m.first?.url.absoluteString, "https://a.example.com/browse/PROJ-1")
    }

    func testNoTemplatesYieldsNothing() {
        XCTAssertTrue(TicketParser.matches(in: "PROJ-1", templates: []).isEmpty)
    }

    // MARK: - Whole-match ($0) и несколько групп

    func testWholeMatchPlaceholderBuildsURL() {
        // CVE-пресет: URL на $0 (всё совпадение), без захваченных групп.
        let cve = LinkTemplate(name: "CVE", pattern: "CVE-\\d{4}-\\d+",
                               url: "https://nvd.nist.gov/vuln/detail/$0",
                               wholeWord: true, uppercase: true)
        let m = TicketParser.matches(in: "see cve-2021-44228 here", templates: [cve])
        XCTAssertEqual(m.first?.id, "CVE-2021-44228")
        XCTAssertEqual(m.first?.url.absoluteString,
                       "https://nvd.nist.gov/vuln/detail/CVE-2021-44228")
    }

    func testMultipleGroupsSubstitutedIntoURL() {
        // Два плейсхолдера: $1 — репозиторий, $2 — номер.
        let t = LinkTemplate(name: "gh", pattern: "(\\w+)#(\\d+)",
                             url: "https://github.com/org/$1/issues/$2",
                             wholeWord: true, uppercase: false)
        let m = TicketParser.matches(in: "repo#42", templates: [t])
        XCTAssertEqual(m.first?.id, "repo#42")
        XCTAssertEqual(m.first?.url.absoluteString,
                       "https://github.com/org/repo/issues/42")
    }

    // MARK: - Точное совпадение (автонаблюдение за буфером)

    func testExactMatchOnlyKey() {
        let m = TicketParser.exactMatch(in: "PROJ-12345", templates: [jira()])
        XCTAssertEqual(m?.id, "PROJ-12345")
        XCTAssertEqual(m?.url.absoluteString, "https://jira.example.com/browse/PROJ-12345")
    }

    func testExactMatchTrimsWhitespace() {
        XCTAssertEqual(TicketParser.exactMatch(in: "  PROJ-7\n", templates: [jira()])?.id, "PROJ-7")
    }

    func testExactMatchCaseInsensitive() {
        XCTAssertEqual(TicketParser.exactMatch(in: "proj-7", templates: [jira()])?.id, "PROJ-7")
    }

    func testExactMatchRejectsURL() {
        // Главный кейс: скопированная ссылка не должна срабатывать автоматически.
        let url = "https://jira.example.com/browse/PROJ-36075"
        XCTAssertNil(TicketParser.exactMatch(in: url, templates: [jira()]))
    }

    func testExactMatchRejectsSurroundingText() {
        XCTAssertNil(TicketParser.exactMatch(in: "ping PROJ-1 please", templates: [jira()]))
        XCTAssertNil(TicketParser.exactMatch(in: "PROJ-1 PROJ-2", templates: [jira()]))
    }

    func testExactMatchEmptyYieldsNil() {
        XCTAssertNil(TicketParser.exactMatch(in: "   ", templates: [jira()]))
    }
}
