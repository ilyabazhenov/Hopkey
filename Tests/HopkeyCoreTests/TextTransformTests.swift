import XCTest
@testable import HopkeyCore

final class TextTransformTests: XCTestCase {

    private func apply(_ t: TextTransform, _ input: String) -> String? { t.apply(to: input) }

    // MARK: Регистр

    func testCaseBasics() {
        XCTAssertEqual(apply(.upper, "Hello"), "HELLO")
        XCTAssertEqual(apply(.lower, "Hello"), "hello")
        XCTAssertEqual(apply(.title, "hello world"), "Hello World")
    }

    func testCamel() {
        XCTAssertEqual(apply(.camel, "hello world"), "helloWorld")
        XCTAssertEqual(apply(.camel, "hello_world"), "helloWorld")
        XCTAssertEqual(apply(.camel, "HelloWorld"), "helloWorld")
        XCTAssertEqual(apply(.camel, "foo-bar baz"), "fooBarBaz")
    }

    func testSnakeKebabConstant() {
        XCTAssertEqual(apply(.snake, "helloWorld"), "hello_world")
        XCTAssertEqual(apply(.snake, "Hello World"), "hello_world")
        XCTAssertEqual(apply(.kebab, "Hello World"), "hello-world")
        XCTAssertEqual(apply(.constant, "hello world"), "HELLO_WORLD")
    }

    func testSlug() {
        XCTAssertEqual(apply(.slug, "Hello, World!"), "hello-world")
        XCTAssertEqual(apply(.slug, "  Мой заголовок  "), "мой-заголовок")
    }

    // MARK: Чистка

    func testTrimAndCollapse() {
        XCTAssertEqual(apply(.trim, "  hi \n"), "hi")
        XCTAssertEqual(apply(.collapseSpaces, "a   b\tc"), "a b c")
        XCTAssertEqual(apply(.collapseSpaces, "a  b\n c  d"), "a b\n c d")
    }

    func testRemoveEmptyAndJoinLines() {
        XCTAssertEqual(apply(.removeEmptyLines, "a\n\n b\n \nc"), "a\n b\nc")
        XCTAssertEqual(apply(.joinLines, "a\n b \nc"), "a b c")
    }

    // MARK: Кодирование

    func testJSON() {
        XCTAssertEqual(apply(.jsonMinify, "{ \"a\" : 1 }"), "{\"a\":1}")
        XCTAssertNil(apply(.jsonPretty, "{ not json"))
        // pretty содержит переносы и отступы.
        let pretty = apply(.jsonPretty, "{\"a\":1}")
        XCTAssertEqual(pretty?.contains("\n"), true)
    }

    func testURL() {
        XCTAssertEqual(apply(.urlEncode, "a b&c"), "a%20b%26c")
        XCTAssertEqual(apply(.urlDecode, "a%20b%26c"), "a b&c")
    }

    func testBase64Roundtrip() {
        let encoded = apply(.base64Encode, "héllo")
        XCTAssertEqual(encoded, "aMOpbGxv")
        XCTAssertEqual(apply(.base64Decode, encoded ?? ""), "héllo")
        XCTAssertNil(apply(.base64Decode, "!!!not base64!!!"))
    }

    func testJWTDecode() {
        // Классический пример с jwt.io (HS256): header.payload.signature.
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
            + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ"
            + ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let decoded = apply(.jwtDecode, token)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.contains("HS256"), true)     // из header
        XCTAssertEqual(decoded?.contains("John Doe"), true)  // из payload
        XCTAssertEqual(decoded?.contains("1234567890"), true)
        XCTAssertEqual(decoded?.contains("// signature"), true)
        // Обычный текст и мусор — не JWT.
        XCTAssertNil(apply(.jwtDecode, "hello world"))
        XCTAssertNil(apply(.jwtDecode, "not.a.jwt"))
    }

    // MARK: Строки

    func testLineOps() {
        XCTAssertEqual(apply(.sortLines, "b\na\nc"), "a\nb\nc")
        XCTAssertEqual(apply(.sortLinesDesc, "a\nb\nc"), "c\nb\na")
        XCTAssertEqual(apply(.dedupeLines, "a\nb\na\nc\nb"), "a\nb\nc")
        XCTAssertEqual(apply(.reverseLines, "a\nb\nc"), "c\nb\na")
    }

    // MARK: Категории и поиск

    func testCategories() {
        XCTAssertEqual(TextTransform.upper.category, .caseType)
        XCTAssertEqual(TextTransform.trim.category, .cleanup)
        XCTAssertEqual(TextTransform.jwtDecode.category, .encoding)
        XCTAssertEqual(TextTransform.sortLines.category, .lines)
        XCTAssertEqual(TextTransform.appendComma.category, .punctuation)
        // Каждый способ отнесён к какой-то категории (switch исчерпывающий — просто прогон).
        for t in TextTransform.allCases { _ = t.category }
    }

    func testMatches() {
        // Пустой запрос совпадает со всем.
        XCTAssertTrue(TextTransform.upper.matches(query: "  ", localizedTitle: "ВЕРХНИЙ РЕГИСТР"))
        // По rawValue — английский термин ловится и при русском названии.
        XCTAssertTrue(TextTransform.jwtDecode.matches(query: "jwt", localizedTitle: "JWT-раскодировать"))
        XCTAssertTrue(TextTransform.base64Decode.matches(query: "base64", localizedTitle: "Base64-раскодировать"))
        XCTAssertTrue(TextTransform.jsonPretty.matches(query: "JSON", localizedTitle: "JSON: форматировать"))
        // По локализованному названию.
        XCTAssertTrue(TextTransform.upper.matches(query: "регистр", localizedTitle: "ВЕРХНИЙ РЕГИСТР"))
        // Не совпадает.
        XCTAssertFalse(TextTransform.upper.matches(query: "jwt", localizedTitle: "ВЕРХНИЙ РЕГИСТР"))
    }

    // MARK: Разбор слов

    func testAppendToLines() {
        // Символ добавляется в конец каждой непустой строки.
        XCTAssertEqual(apply(.appendPeriod, "one\ntwo"), "one.\ntwo.")
        XCTAssertEqual(apply(.appendComma, "one\ntwo"), "one,\ntwo,")
        XCTAssertEqual(apply(.appendSemicolon, "a\nb"), "a;\nb;")
        // Пустые строки не трогаем, уже стоящий символ не дублируем, хвостовые пробелы срезаем.
        XCTAssertEqual(apply(.appendPeriod, "one\n\ntwo."), "one.\n\ntwo.")
        XCTAssertEqual(apply(.appendPeriod, "one  "), "one.")
    }

    func testWordSplitting() {
        XCTAssertEqual(TextTransform.words("helloWorld"), ["hello", "World"])
        XCTAssertEqual(TextTransform.words("hello_world foo"), ["hello", "world", "foo"])
        XCTAssertEqual(TextTransform.words("a1b2"), ["a1b2"])
    }

    /// Преобразования регистра/чистки/строк не должны возвращать nil на обычном тексте
    /// (nil допустим только у JSON/Base64/URL-decode на неподходящем входе).
    func testTextOpsNeverNilOnPlainText() {
        let alwaysApplicable: [TextTransform] = [
            .upper, .lower, .title, .camel, .snake, .kebab, .constant, .slug,
            .trim, .collapseSpaces, .removeEmptyLines, .joinLines,
            .urlEncode, .base64Encode, .sortLines, .sortLinesDesc, .dedupeLines, .reverseLines,
            .appendPeriod, .appendComma, .appendSemicolon,
        ]
        for t in alwaysApplicable {
            XCTAssertNotNil(t.apply(to: "hello world"), "\(t) вернул nil")
        }
    }
}
