import XCTest
@testable import HopkeyCore

final class JiraConfigTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        // Изолированное хранилище на каждый тест, чтобы не трогать .standard.
        suiteName = "JiraConfigTests-\(name)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeConfig() -> JiraConfig {
        JiraConfig(defaults: defaults)
    }

    func testDefaults() {
        let config = makeConfig()
        XCTAssertEqual(config.baseURL, "")
        XCTAssertEqual(config.prefixes, [])
        XCTAssertTrue(config.autoOpen)
        XCTAssertFalse(config.hotKeyEnabled)
        // По умолчанию ⌃⌥J: keyCode 38, модификаторы controlKey | optionKey = 6144.
        XCTAssertEqual(config.hotKeyKeyCode, 38)
        XCTAssertEqual(config.hotKeyModifiers, 6144)
    }

    func testBaseURLRoundTrip() {
        let config = makeConfig()
        config.baseURL = "https://jira.example.com/browse/"
        XCTAssertEqual(config.baseURL, "https://jira.example.com/browse/")
        // Значение должно переживать пересоздание объекта (читается из defaults).
        XCTAssertEqual(makeConfig().baseURL, "https://jira.example.com/browse/")
    }

    func testPrefixesRoundTrip() {
        let config = makeConfig()
        config.prefixes = ["PROJ", "PAY"]
        XCTAssertEqual(config.prefixes, ["PROJ", "PAY"])
        XCTAssertEqual(makeConfig().prefixes, ["PROJ", "PAY"])
    }

    func testAutoOpenRoundTrip() {
        let config = makeConfig()
        config.autoOpen = true
        XCTAssertTrue(config.autoOpen)
        XCTAssertTrue(makeConfig().autoOpen)
    }

    func testHotKeyEnabledRoundTrip() {
        let config = makeConfig()
        config.hotKeyEnabled = true
        XCTAssertTrue(config.hotKeyEnabled)
        XCTAssertTrue(makeConfig().hotKeyEnabled)
    }

    func testHotKeyKeyCodeRoundTrip() {
        let config = makeConfig()
        config.hotKeyKeyCode = 40 // K
        XCTAssertEqual(config.hotKeyKeyCode, 40)
        XCTAssertEqual(makeConfig().hotKeyKeyCode, 40)
    }

    func testHotKeyModifiersRoundTrip() {
        let config = makeConfig()
        config.hotKeyModifiers = 0x0100 | 0x0200 // cmdKey | shiftKey
        XCTAssertEqual(config.hotKeyModifiers, 0x0300)
        XCTAssertEqual(makeConfig().hotKeyModifiers, 0x0300)
    }

    func testIsConfiguredFalseWhenEmpty() {
        XCTAssertFalse(makeConfig().isConfigured)
    }

    func testIsConfiguredFalseWithoutPrefixes() {
        let config = makeConfig()
        config.baseURL = "https://jira.example.com/browse/"
        XCTAssertFalse(config.isConfigured)
    }

    func testIsConfiguredFalseWithoutBaseURL() {
        let config = makeConfig()
        config.prefixes = ["PROJ"]
        XCTAssertFalse(config.isConfigured)
    }

    func testIsConfiguredFalseWhenBaseURLIsWhitespace() {
        let config = makeConfig()
        config.baseURL = "   "
        config.prefixes = ["PROJ"]
        XCTAssertFalse(config.isConfigured)
    }

    func testIsConfiguredTrueWhenBothSet() {
        let config = makeConfig()
        config.baseURL = "https://jira.example.com/browse/"
        config.prefixes = ["PROJ"]
        XCTAssertTrue(config.isConfigured)
    }
}
