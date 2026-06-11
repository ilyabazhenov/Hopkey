import XCTest
@testable import HopkeyCore

final class LinkTemplateTests: XCTestCase {

    private func jira() -> LinkTemplate {
        LinkTemplate(name: "Jira", pattern: "PROJ-(\\d+)",
                     url: "https://jira.example.com/browse/PROJ-$1",
                     wholeWord: true, uppercase: true)
    }

    func testCodableRoundTrip() throws {
        let template = jira()
        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(LinkTemplate.self, from: data)
        XCTAssertEqual(decoded, template)
    }

    // MARK: - isValid

    func testIsValidTrue() {
        XCTAssertTrue(jira().isValid)
    }

    func testIsValidFalseWithEmptyPattern() {
        XCTAssertFalse(LinkTemplate(name: "x", pattern: "  ", url: "https://x/$1").isValid)
    }

    func testIsValidFalseWithBrokenRegex() {
        // Незакрытая группа — regex не компилируется.
        XCTAssertFalse(LinkTemplate(name: "x", pattern: "PROJ-(\\d+", url: "https://x/$1").isValid)
    }

    func testIsValidFalseWithEmptyURL() {
        XCTAssertFalse(LinkTemplate(name: "x", pattern: "PROJ-(\\d+)", url: "   ").isValid)
    }

    func testIsValidFalseWithoutPlaceholder() {
        // URL без $0…$9 — некуда подставлять совпадение.
        XCTAssertFalse(LinkTemplate(name: "x", pattern: "PROJ-(\\d+)", url: "https://x/static").isValid)
    }

    // MARK: - isFillableByNumber

    func testFillableWhenOnlyDollarOne() {
        XCTAssertTrue(jira().isFillableByNumber)
    }

    func testNotFillableWhenWholeMatchPlaceholder() {
        let cve = LinkTemplate(name: "CVE", pattern: "CVE-\\d{4}-\\d+",
                               url: "https://nvd.nist.gov/vuln/detail/$0")
        XCTAssertFalse(cve.isFillableByNumber)
    }

    // MARK: - buildURL (подстановка групп + encoding)

    func testBuildURLSubstitutesGroups() {
        let m = jira().fillMatch(number: "123")
        XCTAssertEqual(m?.url.absoluteString, "https://jira.example.com/browse/PROJ-123")
        XCTAssertEqual(m?.id, "PROJ-123")
    }

    func testBuildURLPercentEncodesSpacesAndCyrillic() {
        // Группа со «странным» значением percent-кодируется; литералы шаблона — нет.
        let t = LinkTemplate(name: "wiki", pattern: "(.+)", url: "https://wiki/search?q=$1",
                             wholeWord: false, uppercase: false)
        let ns = "ИЛ 7" as NSString
        let regex = t.compiledRegex()!
        let result = regex.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length))!
        let match = t.match(from: result, in: ns)
        XCTAssertEqual(match?.url.absoluteString, "https://wiki/search?q=%D0%98%D0%9B%207")
    }

    func testBuildURLDropsInvalidLiteral() {
        // Пробел в литеральной части адреса делает URL невалидным → nil.
        let t = LinkTemplate(name: "bad", pattern: "(\\d+)", url: "https://bad host/$1")
        XCTAssertNil(t.fillMatch(number: "9"))
    }

    // MARK: - matchesWhole (предвыбор шаблона в окне ввода)

    func testMatchesWholeTrueForFullKey() {
        XCTAssertTrue(jira().matchesWhole("PROJ-123"))
        // Регистр не важен и пробелы по краям обрезаются.
        XCTAssertTrue(jira().matchesWhole("  proj-7\n"))
    }

    func testMatchesWholeFalseForBareNumberOrPartial() {
        XCTAssertFalse(jira().matchesWhole("123"))
        // Лишний текст вокруг — это не «целиком ключ».
        XCTAssertFalse(jira().matchesWhole("ping PROJ-1 please"))
        XCTAssertFalse(jira().matchesWhole(""))
    }

    func testMatchesWholeFalseForOtherTemplateKey() {
        XCTAssertFalse(jira().matchesWhole("OTHER-5"))
    }

    // MARK: - presets

    func testPresetsAreValid() {
        for preset in LinkTemplate.presets {
            XCTAssertTrue(preset.isValid, "пресет \(preset.name) должен быть валиден")
        }
    }
}
